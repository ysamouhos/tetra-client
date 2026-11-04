//! The running terminal: one async task that owns the WebSocket, the call
//! engine, SDS bookkeeping and the ACELP codecs. The app talks to it through
//! [`ClientHandle`] (commands in) and an event channel (events out).

use crate::calls::{CallConfig, CallEngine, CallEvent, Output};
use crate::codec::{VoiceDecoder, VoiceEncoder};
use crate::protocol::{self as p, CallPayload, Message};
use crate::sds::{self, IncomingSds, LipReason, LipReport, Location};
use crate::transport::{self, Endpoint, Ws};
use futures_util::{SinkExt, StreamExt};
use std::collections::HashMap;
use std::time::{Duration, Instant};
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::Message as WsMsg;
use uuid::Uuid;

const REREGISTER_EVERY: Duration = Duration::from_secs(300);
const TICK: Duration = Duration::from_millis(250);
const SDS_HEADER_TTL: Duration = Duration::from_secs(10);

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
    decoders: HashMap<Uuid, VoiceDecoder>,
    sds_headers: HashMap<Uuid, (u32, u32, Instant)>,
    next_mr: u8,
    /// (destination, message reference) → app message id.
    pending_reports: HashMap<(u32, u8), u32>,
    /// Brew SDS uuid → app message id (for network-level FRAME_SDS_REPORT).
    pending_net: HashMap<Uuid, u32>,
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
            decoders: HashMap::new(),
            sds_headers: HashMap::new(),
            next_mr: rand::random(),
            pending_reports: HashMap::new(),
            pending_net: HashMap::new(),
        }
    }

    fn emit(&self, e: ClientEvent) {
        let _ = self.events.send(e);
    }

    fn apply(&mut self, outputs: Vec<Output>) {
        for o in outputs {
            match o {
                Output::Send(w) => self.out.push(w),
                Output::Event(e) => {
                    match &e {
                        CallEvent::TxEnded { .. } => self.encoder = None,
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

    fn registration(&self) -> Vec<Vec<u8>> {
        let mut v = vec![p::build_subscriber(p::SUB_REGISTER, self.cfg.issi, &[])];
        if !self.cfg.groups.is_empty() {
            v.push(p::build_subscriber(p::SUB_AFFILIATE, self.cfg.issi, &self.cfg.groups));
        }
        v
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
                if !removed.is_empty() {
                    self.out.push(p::build_subscriber(p::SUB_DEAFFILIATE, self.cfg.issi, &removed));
                }
                if !added.is_empty() {
                    self.out.push(p::build_subscriber(p::SUB_AFFILIATE, self.cfg.issi, &added));
                }
                self.cfg.groups = groups.clone();
                self.engine.set_groups(groups, selected);
            }
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
                self.out.extend(frames);
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
            Ok(ws) => ws,
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
                _ = rereg.tick() => s.out.push(p::build_subscriber(p::SUB_REREGISTER, s.cfg.issi, &[])),
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
        s.emit(ClientEvent::Disconnected { reason });
    }
}
