//! The running terminal: one async task that owns the WebSocket, the call
//! engine, SDS bookkeeping and the ACELP codecs. The app talks to it through
//! [`ClientHandle`] (commands in) and an event channel (events out).

use crate::calls::{CallConfig, CallEngine, CallEvent, Output};
use crate::codec::{VoiceDecoder, VoiceEncoder};
use crate::protocol::{self as p, CallPayload, Message};
use crate::sds::{self, IncomingSds, LipReason, LipReport, Location};
use crate::transport::{self, Endpoint, Ws};
use futures_util::{SinkExt, StreamExt};
use std::collections::{HashMap, VecDeque};
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message as WsMsg;
use uuid::Uuid;

const REREGISTER_EVERY: Duration = Duration::from_secs(300);
const TICK: Duration = Duration::from_millis(250);
/// Brew traffic frames carry 60 ms of speech; a base station expects them at that
/// cadence, not in the bursts a phone's audio callback produces.
const VOICE_PACE: Duration = Duration::from_millis(60);
/// Cap on queued, not-yet-sent voice frames (~1.5 s) so latency stays bounded.
const MAX_TX_QUEUE: usize = 25;
const SDS_HEADER_TTL: Duration = Duration::from_secs(10);

/// A network by its MNI (MCC 10 bits, MNC 14 bits).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct Mni {
    pub mcc: u16,
    pub mnc: u16,
}

#[derive(Debug, Clone)]
pub struct ClientConfig {
    pub endpoint: Endpoint,
    pub issi: u32,
    /// Talker name sent as the SS-TPI mnemonic (Brew v1).
    pub name: Option<String>,
    pub groups: Vec<u32>,
    pub selected_group: Option<u32>,
    pub default_priority: u8,
    pub allow_preemption: bool,
    /// Multi Network (`mni`, only when the server offers it): this terminal's
    /// home network; `None` = the server's own network.
    pub home_network: Option<Mni>,
    /// Groups that belong to another network than the home network (GSSI →
    /// network). Every other group is in the home network.
    pub group_networks: HashMap<u32, Mni>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum MessageStatus {
    Sent,
    /// Network accepted it (Brew `FRAME_SDS_REPORT` 0).
    NetworkAccepted,
    /// SDS-TL report from the destination terminal.
    Delivered { status: u8 },
    Failed { reason: String },
}

#[derive(Debug, Clone, PartialEq)]
pub enum ClientEvent {
    Connecting,
    Connected,
    Disconnected { reason: String },
    Call(CallEvent),
    /// 60 ms of decoded 8 kHz PCM for the call currently in focus.
    Audio { call: Uuid, pcm: Vec<i16> },
    TextReceived { from: u32, to: u32, text: String, immediate: bool },
    MessageStatus { local_id: u32, status: MessageStatus },
    LocationReceived { from: u32, report: LipReport },
    SubscriberProfiles { json: String },
    ServerError { kind: u8 },
    /// Extensions the server offered on this connection.
    Extensions { offered: Vec<String> },
    /// `SERVICE_NETWORKS` (Multi Network): this server's network and the
    /// linked ones, as JSON.
    Networks { json: String },
    /// `SERVICE_GROUP_ACCESS`: who may use which group, lists reduced to our ISSI.
    GroupAccess { json: String },
}

#[derive(Debug)]
pub enum Command {
    Ptt { pressed: bool, group: Option<u32>, emergency: bool },
    Dial { issi: u32, duplex: bool, hook: bool, priority: Option<u8> },
    /// Phone / PBX number via the server's SIP gateway.
    DialExternal { number: String, priority: Option<u8> },
    Answer,
    Hangup,
    SelectGroup(u32),
    SetGroups { groups: Vec<u32>, selected: Option<u32> },
    /// Networks of groups outside the home network (see [`ClientConfig::group_networks`]).
    SetGroupNetworks(HashMap<u32, Mni>),
    SendText { local_id: u32, to: u32, text: String, immediate: bool, request_report: bool },
    SendLocation { to: u32, location: Location, reason: LipReason },
    QuerySubscribers(Vec<u32>),
    Dtmf(u8),
    /// Microphone PCM (8 kHz mono). Ignored unless a floor is held.
    MicPcm(Vec<i16>),
    Shutdown,
}

#[derive(Clone)]
pub struct ClientHandle {
    tx: mpsc::UnboundedSender<Command>,
}

impl ClientHandle {
    pub fn send(&self, c: Command) -> bool {
        self.tx.send(c).is_ok()
    }
}

/// Spawns the client on the current tokio runtime.
pub fn spawn(cfg: ClientConfig) -> (ClientHandle, mpsc::UnboundedReceiver<ClientEvent>) {
    let (ctx, crx) = mpsc::unbounded_channel();
    let (etx, erx) = mpsc::unbounded_channel();
    tokio::spawn(run(cfg, crx, etx));
    (ClientHandle { tx: ctx }, erx)
}

struct Session {
    cfg: ClientConfig,
    engine: CallEngine,
    events: mpsc::UnboundedSender<ClientEvent>,
    out: Vec<Vec<u8>>,
    encoder: Option<(Uuid, VoiceEncoder)>,
    tx_queue: VecDeque<Vec<u8>>,
    decoders: HashMap<Uuid, VoiceDecoder>,
    sds_headers: HashMap<Uuid, (u32, u32, Instant)>,
    next_mr: u8,
    /// (destination, message reference) → app message id.
    pending_reports: HashMap<(u32, u8), u32>,
    /// Brew SDS uuid → app message id (for network-level FRAME_SDS_REPORT).
    pending_net: HashMap<Uuid, u32>,
    /// The server offered `mni` on this connection.
    mni: bool,
    group_access: bool,
}

impl Session {
    fn new(cfg: ClientConfig, events: mpsc::UnboundedSender<ClientEvent>) -> Self {
        let mut engine = CallEngine::new(CallConfig {
            issi: cfg.issi,
            name: cfg.name.clone(),
            default_priority: cfg.default_priority,
            allow_preemption: cfg.allow_preemption,
        });
        engine.set_groups(cfg.groups.clone(), cfg.selected_group);
        Self {
            cfg,
            engine,
            events,
            out: Vec::new(),
            encoder: None,
            tx_queue: VecDeque::new(),
            decoders: HashMap::new(),
            sds_headers: HashMap::new(),
            next_mr: rand::random(),
            pending_reports: HashMap::new(),
            pending_net: HashMap::new(),
            mni: false,
            group_access: false,
        }
    }

    fn emit(&self, e: ClientEvent) {
        let _ = self.events.send(e);
    }

    fn apply(&mut self, outputs: Vec<Output>) {
        for o in outputs {
            match o {
                Output::Send(w) => {
                    if let Some(note) = self.call_network_note(&w) {
                        self.out.push(note);
                    }
                    self.out.push(w)
                }
                Output::Event(e) => {
                    match &e {
                        CallEvent::TxEnded { .. } => {
                            self.encoder = None;
                            self.tx_queue.clear();
                        }
                        CallEvent::GroupTxEnded { id, .. } | CallEvent::PrivateEnded { id, .. } => {
                            self.decoders.remove(id);
                        }
                        _ => {}
                    }
                    self.emit(ClientEvent::Call(e));
                }
            }
        }
    }

    /// After connecting: with `mni`, the home network first (0/0 = the
    /// server's own; this also takes up the offer), then `SUB_REGISTER`, the
    /// groups of other networks and `SUB_AFFILIATE`.
    fn registration(&self) -> Vec<Vec<u8>> {
        let mut v = Vec::new();
        if self.mni {
            let home = self.cfg.home_network.unwrap_or_default();
            let json = serde_json::json!({ "issi": self.cfg.issi, "mcc": home.mcc, "mnc": home.mnc });
            v.push(p::build_service(p::SERVICE_MS_NETWORK, &json.to_string()));
        }
        v.push(p::build_subscriber(p::SUB_REGISTER, self.cfg.issi, &[]));
        if self.group_access {
            v.push(p::build_service(p::SERVICE_GROUP_ACCESS, "{}"));
        }
        v.extend(self.affiliation(p::SUB_AFFILIATE, &self.cfg.groups));
        v
    }

    /// Periodic refresh, as FlowStation does for its radios: `SUB_REREGISTER`
    /// and the groups again.
    fn reregistration(&self) -> Vec<Vec<u8>> {
        let mut v = vec![p::build_subscriber(p::SUB_REREGISTER, self.cfg.issi, &[])];
        v.extend(self.affiliation(p::SUB_AFFILIATE, &self.cfg.groups));
        v
    }

    /// `SUB_AFFILIATE` / `SUB_DEAFFILIATE` for `groups`, with `mni` preceded by
    /// `SERVICE_GROUP_NETWORK` naming those that belong to another network.
    fn affiliation(&self, kind: u8, groups: &[u32]) -> Vec<Vec<u8>> {
        if groups.is_empty() {
            return Vec::new();
        }
        let mut v = Vec::new();
        if self.mni {
            let home = self.cfg.home_network.unwrap_or_default();
            let foreign: Vec<_> = groups
                .iter()
                .filter_map(|g| self.cfg.group_networks.get(g).filter(|n| **n != home && **n != Mni::default()).map(|n| (*g, *n)))
                .map(|(g, n)| serde_json::json!({ "gssi": g, "mcc": n.mcc, "mnc": n.mnc }))
                .collect();
            if !foreign.is_empty() {
                let json = serde_json::json!({ "issi": self.cfg.issi, "groups": foreign });
                v.push(p::build_service(p::SERVICE_GROUP_NETWORK, &json.to_string()));
            }
        }
        v.push(p::build_subscriber(kind, self.cfg.issi, groups));
        v
    }

    /// With `mni`: `SERVICE_CALL_NETWORK` before our own `GROUP_TX` on a group
    /// of another network.
    fn call_network_note(&self, w: &[u8]) -> Option<Vec<u8>> {
        if !self.mni || w.len() < 26 || w[0] != p::CLASS_CALL_CONTROL || w[1] != p::CALL_GROUP_TX {
            return None;
        }
        let id = Uuid::from_slice(&w[2..18]).ok()?;
        let gssi = u32::from_le_bytes(w[22..26].try_into().ok()?);
        let home = self.cfg.home_network.unwrap_or_default();
        let n = self.cfg.group_networks.get(&gssi).filter(|n| **n != home && **n != Mni::default())?;
        let json = serde_json::json!({ "uuid": id.to_string(), "group": { "gssi": gssi, "mcc": n.mcc, "mnc": n.mnc } });
        Some(p::build_service(p::SERVICE_CALL_NETWORK, &json.to_string()))
    }

    fn send_sds(&mut self, to: u32, data: Vec<u8>, bits: u16) -> Uuid {
        let id = Uuid::new_v4();
        self.out.push(p::build_short_transfer(&id, self.cfg.issi, to));
        self.out.push(p::build_frame(p::FRAME_SDS_TRANSFER, &id, bits, &data));
        id
    }

    fn command(&mut self, c: Command) -> bool {
        match c {
            Command::Ptt { pressed: true, group, emergency } => {
                let o = self.engine.ptt_press(group, emergency);
                self.apply(o)
            }
            Command::Ptt { pressed: false, .. } => {
                self.finish_voice();
                let o = self.engine.ptt_release();
                self.apply(o)
            }
            Command::Dial { issi, duplex, hook, priority } => {
                let o = self.engine.dial(issi, duplex, hook, priority);
                self.apply(o)
            }
            Command::DialExternal { number, priority } => {
                let o = self.engine.dial_external(&number, priority);
                self.apply(o)
            }
            Command::Answer => {
                let o = self.engine.answer();
                self.apply(o)
            }
            Command::Hangup => {
                let o = self.engine.hangup();
                self.apply(o)
            }
            Command::SelectGroup(g) => {
                let o = self.engine.select_group(g);
                self.apply(o)
            }
            Command::SetGroups { groups, selected } => {
                let removed: Vec<u32> = self.cfg.groups.iter().copied().filter(|g| !groups.contains(g)).collect();
                let added: Vec<u32> = groups.iter().copied().filter(|g| !self.cfg.groups.contains(g)).collect();
                let mut msgs = self.affiliation(p::SUB_DEAFFILIATE, &removed);
                msgs.extend(self.affiliation(p::SUB_AFFILIATE, &added));
                self.out.extend(msgs);
                self.cfg.groups = groups.clone();
                self.engine.set_groups(groups, selected);
            }
            Command::SetGroupNetworks(n) => self.cfg.group_networks = n,
            Command::SendText { local_id, to, text, immediate, request_report } => {
                let mr = self.next_mr;
                self.next_mr = self.next_mr.wrapping_add(1);
                let (data, bits) = sds::build_text(&text, mr, request_report, immediate);
                let id = self.send_sds(to, data, bits);
                if request_report {
                    self.pending_reports.insert((to, mr), local_id);
                }
                self.pending_net.insert(id, local_id);
                self.emit(ClientEvent::MessageStatus { local_id, status: MessageStatus::Sent });
            }
            Command::SendLocation { to, location, reason } => {
                let (data, bits) = sds::build_lip_short(&location, reason);
                self.send_sds(to, data, bits);
            }
            Command::QuerySubscribers(issis) => {
                let json = serde_json::to_string(&issis).unwrap_or_else(|_| "[]".into());
                self.out.push(p::build_service(p::SERVICE_QUERY_SUBSCRIBERS, &json));
            }
            Command::Dtmf(d) => {
                if let Some(id) = self.engine.private_call().map(|c| c.id) {
                    self.out.push(p::build_frame(p::FRAME_DTMF, &id, 8, &[d]));
                }
            }
            Command::MicPcm(pcm) => {
                let Some(id) = self.engine.tx_call() else { return true };
                if self.encoder.as_ref().map(|(i, _)| *i) != Some(id) {
                    self.encoder = Some((id, VoiceEncoder::new()));
                }
                let frames = self.encoder.as_mut().unwrap().1.push_frames(&id, &pcm);
                self.tx_queue.extend(frames);
                while self.tx_queue.len() > MAX_TX_QUEUE {
                    self.tx_queue.pop_front();
                }
            }
            Command::Shutdown => return false,
        }
        true
    }

    fn incoming(&mut self, raw: &[u8]) {
        let msg = match p::parse(raw) {
            Ok(m) => m,
            Err(e) => {
                log::warn!("dropping malformed Brew message: {e}");
                return;
            }
        };
        match &msg {
            Message::CallControl { state: p::CALL_SHORT_TRANSFER, id, payload: CallPayload::ShortTransfer { source, destination, .. } } => {
                self.sds_headers.insert(*id, (*source, *destination, Instant::now()));
            }
            Message::Frame { kind: p::FRAME_SDS_TRANSFER, id, data, .. } => self.on_sds(*id, data),
            Message::Frame { kind: p::FRAME_SDS_REPORT, id, data, .. } => {
                if let Some(local_id) = self.pending_net.remove(id) {
                    let status = match data.first() {
                        Some(0) => MessageStatus::NetworkAccepted,
                        s => MessageStatus::Failed { reason: format!("network status {s:?}") },
                    };
                    self.emit(ClientEvent::MessageStatus { local_id, status });
                }
            }
            Message::Frame { kind: p::FRAME_TRAFFIC_CHANNEL, id, data, .. } => {
                let o = self.engine.on_message(&msg);
                self.apply(o);
                if self.engine.focus() == Some(*id) && self.engine.tx_call() != Some(*id) || self.is_duplex_rx(*id) {
                    let pcm = self.decoders.entry(*id).or_default().decode(data);
                    self.emit(ClientEvent::Audio { call: *id, pcm });
                }
            }
            Message::Service { kind: p::SERVICE_SUBSCRIBER_PROFILES, json } => {
                self.emit(ClientEvent::SubscriberProfiles { json: json.clone() })
            }
            Message::Service { kind: p::SERVICE_NETWORKS, json } if self.mni => self.emit(ClientEvent::Networks { json: json.clone() }),
            Message::Service { kind: p::SERVICE_GROUP_ACCESS, json } if self.group_access => self.emit(ClientEvent::GroupAccess { json: json.clone() }),
            // The group's network before a GROUP_TX: the GROUP_TX carries that
            // network's GSSI, which is how the app knows the group.
            Message::Service { kind: p::SERVICE_CALL_NETWORK, .. } => {}
            Message::Error { kind, .. } => self.emit(ClientEvent::ServerError { kind: *kind }),
            _ => {
                let o = self.engine.on_message(&msg);
                self.apply(o);
            }
        }
    }

    /// In a connected duplex private call we both transmit and play.
    fn is_duplex_rx(&self, id: Uuid) -> bool {
        self.engine.private_call().is_some_and(|c| c.id == id && c.duplex && self.engine.focus() == Some(id))
    }

    fn on_sds(&mut self, id: Uuid, data: &[u8]) {
        let Some((from, to, _)) = self.sds_headers.remove(&id) else {
            log::warn!("SDS frame without SHORT_TRANSFER header, uuid {id}");
            return;
        };
        // Network-level delivery report back toward the originator.
        self.out.push(p::build_frame(p::FRAME_SDS_REPORT, &id, 8, &[0]));
        match sds::parse_incoming(data) {
            Some(IncomingSds::Text { pid, text, immediate, message_reference, report_requested }) => {
                if let (true, Some(mr)) = (report_requested && to == self.cfg.issi, message_reference) {
                    let (r, bits) = sds::build_report(pid, sds::status::RECEIVED, mr);
                    self.send_sds(from, r, bits);
                }
                self.emit(ClientEvent::TextReceived { from, to, text, immediate });
            }
            Some(IncomingSds::Report { delivery_status, message_reference, .. }) => {
                if let Some(local_id) = self.pending_reports.remove(&(from, message_reference)) {
                    self.emit(ClientEvent::MessageStatus { local_id, status: MessageStatus::Delivered { status: delivery_status } });
                }
            }
            Some(IncomingSds::Location(report)) => self.emit(ClientEvent::LocationReceived { from, report }),
            Some(other) => log::debug!("unhandled SDS from {from}: {other:?}"),
            None => {}
        }
    }

    /// End of our transmission: send the padded tail and everything still
    /// queued, ahead of the call-release message that follows.
    fn finish_voice(&mut self) {
        let Some(id) = self.engine.tx_call() else { return };
        if let Some((eid, enc)) = self.encoder.as_mut() {
            if *eid == id {
                for p in enc.flush() {
                    self.tx_queue.push_back(p::build_frame(p::FRAME_TRAFFIC_CHANNEL, &id, (p.len() * 8) as u16, &p));
                }
            }
        }
        self.out.extend(self.tx_queue.drain(..));
    }

    /// Releases one queued voice frame; called every [`VOICE_PACE`].
    fn pace_voice(&mut self) {
        if let Some(f) = self.tx_queue.pop_front() {
            self.out.push(f);
        }
    }

    fn tick(&mut self) {
        let o = self.engine.tick(Instant::now());
        self.apply(o);
        self.sds_headers.retain(|_, (_, _, t)| t.elapsed() < SDS_HEADER_TTL);
    }
}

async fn flush(ws: &mut Ws, s: &mut Session) -> Result<(), tokio_tungstenite::tungstenite::Error> {
    for w in s.out.drain(..) {
        ws.feed(WsMsg::Binary(w.into())).await?;
    }
    ws.flush().await
}

async fn run(cfg: ClientConfig, mut cmds: mpsc::UnboundedReceiver<Command>, events: mpsc::UnboundedSender<ClientEvent>) {
    let mut s = Session::new(cfg, events);
    let mut backoff = Duration::from_secs(1);
    loop {
        s.emit(ClientEvent::Connecting);
        let mut ws = match transport::connect(&s.cfg.endpoint).await {
            Ok((ws, offered)) => {
                s.mni = offered.iter().any(|e| e == p::EXT_MNI);
                s.group_access = offered.iter().any(|e| e == p::EXT_GROUP_ACCESS);
                s.emit(ClientEvent::Extensions { offered });
                ws
            }
            Err(e) => {
                s.emit(ClientEvent::Disconnected { reason: e.to_string() });
                if matches!(e, transport::ConnectError::Unauthorized) {
                    backoff = Duration::from_secs(60);
                }
                // Keep draining commands while waiting so Shutdown works offline.
                let deadline = tokio::time::sleep(backoff);
                tokio::pin!(deadline);
                loop {
                    tokio::select! {
                        _ = &mut deadline => break,
                        c = cmds.recv() => match c {
                            None | Some(Command::Shutdown) => return,
                            Some(Command::MicPcm(_)) => {}
                            Some(c) => { s.command(c); s.out.clear(); }
                        }
                    }
                }
                backoff = (backoff * 2).min(Duration::from_secs(30));
                continue;
            }
        };
        backoff = Duration::from_secs(1);
        s.out.extend(s.registration());
        if flush(&mut ws, &mut s).await.is_err() {
            continue;
        }
        s.emit(ClientEvent::Connected);
        let mut tick = tokio::time::interval(TICK);
        let mut pace = tokio::time::interval(VOICE_PACE);
        pace.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        let mut rereg = tokio::time::interval_at(tokio::time::Instant::now() + REREGISTER_EVERY, REREGISTER_EVERY);
        let reason = loop {
            tokio::select! {
                m = ws.next() => match m {
                    Some(Ok(WsMsg::Binary(b))) => s.incoming(&b),
                    Some(Ok(WsMsg::Close(f))) => break format!("server closed: {f:?}"),
                    Some(Ok(_)) => {}
                    Some(Err(e)) => break e.to_string(),
                    None => break "connection closed".into(),
                },
                c = cmds.recv() => match c {
                    None | Some(Command::Shutdown) => {
                        s.out.push(p::build_subscriber(p::SUB_DEREGISTER, s.cfg.issi, &[]));
                        let _ = flush(&mut ws, &mut s).await;
                        let _ = ws.close(None).await;
                        return;
                    }
                    Some(c) => { s.command(c); }
                },
                _ = tick.tick() => s.tick(),
                _ = pace.tick() => s.pace_voice(),
                _ = rereg.tick() => { let r = s.reregistration(); s.out.extend(r); }
            }
            if let Err(e) = flush(&mut ws, &mut s).await {
                break e.to_string();
            }
        };
        // Calls do not survive a reconnect: tell the UI they ended.
        let o = s.engine.hangup();
        s.apply(o);
        let o = s.engine.ptt_release();
        s.apply(o);
        s.out.clear();
        s.tx_queue.clear();
        s.emit(ClientEvent::Disconnected { reason });
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn session(mni: bool) -> Session {
        let (tx, _rx) = mpsc::unbounded_channel();
        let cfg = ClientConfig {
            endpoint: Endpoint { url: String::new(), username: String::new(), password: String::new(), user_agent: String::new(), insecure_tls: false, mode: Default::default() },
            issi: 2040001,
            name: None,
            groups: vec![91, 2324],
            selected_group: Some(91),
            default_priority: 1,
            allow_preemption: true,
            home_network: Some(Mni { mcc: 901, mnc: 1638 }),
            group_networks: HashMap::from([(2324, Mni { mcc: 901, mnc: 9999 }), (91, Mni { mcc: 901, mnc: 1638 })]),
        };
        let mut s = Session::new(cfg, tx);
        s.mni = mni;
        s
    }

    fn kinds(v: &[Vec<u8>]) -> Vec<(u8, u8)> {
        v.iter().map(|w| (w[0], w[1])).collect()
    }

    #[test]
    fn periodic_reregistration_affiliates_again() {
        let s = session(false);
        assert_eq!(kinds(&s.reregistration()), vec![(p::CLASS_SUBSCRIBER, p::SUB_REREGISTER), (p::CLASS_SUBSCRIBER, p::SUB_AFFILIATE)]);
    }

    #[test]
    fn without_the_offer_no_network_messages() {
        let s = session(false);
        assert_eq!(kinds(&s.registration()), vec![(p::CLASS_SUBSCRIBER, p::SUB_REGISTER), (p::CLASS_SUBSCRIBER, p::SUB_AFFILIATE)]);
    }

    #[test]
    fn with_group_access_offered_the_table_is_asked_for_after_register() {
        let mut s = session(false);
        s.group_access = true;
        assert_eq!(
            kinds(&s.registration()),
            vec![(p::CLASS_SUBSCRIBER, p::SUB_REGISTER), (p::CLASS_SERVICE, p::SERVICE_GROUP_ACCESS), (p::CLASS_SUBSCRIBER, p::SUB_AFFILIATE)]
        );
        assert_eq!(&s.registration()[1][2..], b"{}\0");
    }

    #[test]
    fn with_mni_only_groups_outside_the_home_network_are_named() {
        let s = session(true);
        let r = s.registration();
        assert_eq!(
            kinds(&r),
            vec![
                (p::CLASS_SERVICE, p::SERVICE_MS_NETWORK),
                (p::CLASS_SUBSCRIBER, p::SUB_REGISTER),
                (p::CLASS_SERVICE, p::SERVICE_GROUP_NETWORK),
                (p::CLASS_SUBSCRIBER, p::SUB_AFFILIATE)
            ]
        );
        let Message::Service { json, .. } = p::parse(&r[2]).unwrap() else { panic!() };
        let v: serde_json::Value = serde_json::from_str(&json).unwrap();
        assert_eq!(v["groups"], serde_json::json!([{ "gssi": 2324, "mcc": 901, "mnc": 9999 }]), "91 is in the home network");
        let Message::Service { json, .. } = p::parse(&r[0]).unwrap() else { panic!() };
        assert!(json.contains("\"mnc\":1638"));
    }
}
