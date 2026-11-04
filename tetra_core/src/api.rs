//! Flat API surface for flutter_rust_bridge (v2). Only plain data types cross
//! the boundary; Dart drives the event loop by awaiting `next_event()`.
//!
//! Dart usage:
//! ```dart
//! final c = await TetraClient.connect(config: cfg);
//! while (true) { final e = await c.nextEvent(); if (e == null) break; ... }
//! ```

use crate::calls::{CallEvent, Direction, Floor, PrivateState};
use crate::client::{self, ClientConfig, ClientEvent, ClientHandle, Command, MessageStatus};
use crate::sds::{LipReason, Location};
use crate::transport::Endpoint;
use std::sync::{Arc, OnceLock};
use tokio::sync::{mpsc, Mutex};

fn runtime() -> &'static tokio::runtime::Runtime {
    static RT: OnceLock<tokio::runtime::Runtime> = OnceLock::new();
    RT.get_or_init(|| tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().expect("tokio runtime"))
}

#[derive(Debug, Clone)]
pub struct TerminalConfig {
    pub server_url: String,
    pub username: String,
    pub password: String,
    pub issi: u32,
    pub name: Option<String>,
    pub groups: Vec<u32>,
    pub selected_group: Option<u32>,
    pub default_priority: u8,
    pub allow_preemption: bool,
    pub insecure_tls: bool,
}

#[derive(Debug, Clone)]
pub struct PrivateCallInfo {
    pub id: String,
    pub peer: u32,
    pub peer_name: Option<String>,
    /// Set for calls to/from outside the TETRA network (phone/PBX via SIP).
    pub number: Option<String>,
    pub incoming: bool,
    /// setup | proceeding | alerting | ringing | connecting | connected
    pub state: String,
    pub duplex: bool,
    pub hook: bool,
    pub priority: u8,
    /// idle | me | peer
    pub floor: String,
}

#[derive(Debug, Clone)]
pub struct LocationInfo {
    pub latitude: f64,
    pub longitude: f64,
    pub accuracy_m: Option<f64>,
    pub speed_kmh: Option<f64>,
    pub heading_deg: Option<f64>,
}

#[derive(Debug, Clone)]
pub enum AppEvent {
    Connecting,
    Connected,
    Disconnected { reason: String },
    GroupTxStarted { gssi: u32, talker: u32, talker_name: Option<String>, priority: u8, emergency: bool, call_id: String },
    GroupTxEnded { gssi: u32, call_id: String, cause: u8 },
    TxGranted { call_id: String },
    TxDenied { reason: String },
    TxEnded { call_id: String, preempted: bool },
    PrivateCall { call: PrivateCallInfo },
    PrivateCallEnded { call_id: String, peer: u32, cause: u8 },
    AudioFocus { call_id: Option<String> },
    /// 480 samples of 8 kHz mono PCM (60 ms) to play.
    Audio { call_id: String, pcm: Vec<i16> },
    TextReceived { from: u32, to: u32, text: String, immediate: bool },
    /// sent | network_accepted | delivered | failed
    MessageStatus { local_id: u32, status: String, detail: Option<String> },
    LocationReceived { from: u32, location: LocationInfo, reason: Option<u8> },
    SubscriberProfiles { json: String },
    ServerError { kind: u8 },
}

fn private_info(c: &crate::calls::PrivateCall) -> PrivateCallInfo {
    PrivateCallInfo {
        id: c.id.to_string(),
        peer: c.peer,
        peer_name: c.peer_name.clone(),
        number: c.number.clone(),
        incoming: c.direction == Direction::Incoming,
        state: match c.state {
            PrivateState::Setup => "setup",
            PrivateState::Proceeding => "proceeding",
            PrivateState::Alerting => "alerting",
            PrivateState::Ringing => "ringing",
            PrivateState::Connecting => "connecting",
            PrivateState::Connected => "connected",
        }
        .into(),
        duplex: c.duplex,
        hook: c.hook,
        priority: c.priority,
        floor: match c.floor {
            Floor::Idle => "idle",
            Floor::Me => "me",
            Floor::Peer => "peer",
        }
        .into(),
    }
}

fn convert(e: ClientEvent) -> AppEvent {
    match e {
        ClientEvent::Connecting => AppEvent::Connecting,
        ClientEvent::Connected => AppEvent::Connected,
        ClientEvent::Disconnected { reason } => AppEvent::Disconnected { reason },
        ClientEvent::Audio { call, pcm } => AppEvent::Audio { call_id: call.to_string(), pcm },
        ClientEvent::TextReceived { from, to, text, immediate } => AppEvent::TextReceived { from, to, text, immediate },
        ClientEvent::MessageStatus { local_id, status } => {
            let (s, d) = match status {
                MessageStatus::Sent => ("sent", None),
                MessageStatus::NetworkAccepted => ("network_accepted", None),
                MessageStatus::Delivered { status } => ("delivered", Some(format!("0x{status:02x}"))),
                MessageStatus::Failed { reason } => ("failed", Some(reason)),
            };
            AppEvent::MessageStatus { local_id, status: s.into(), detail: d }
        }
        ClientEvent::LocationReceived { from, report } => AppEvent::LocationReceived {
            from,
            location: LocationInfo {
                latitude: report.location.latitude,
                longitude: report.location.longitude,
                accuracy_m: report.location.accuracy_m,
                speed_kmh: report.location.speed_kmh,
                heading_deg: report.location.heading_deg,
            },
            reason: report.reason,
        },
        ClientEvent::SubscriberProfiles { json } => AppEvent::SubscriberProfiles { json },
        ClientEvent::ServerError { kind } => AppEvent::ServerError { kind },
        ClientEvent::Call(c) => match c {
            CallEvent::GroupTxStarted { gssi, talker, talker_name, priority, id } => AppEvent::GroupTxStarted {
                gssi,
                talker,
                talker_name,
                priority,
                emergency: priority >= crate::calls::PRIORITY_EMERGENCY,
                call_id: id.to_string(),
            },
            CallEvent::GroupTxEnded { gssi, id, cause } => AppEvent::GroupTxEnded { gssi, call_id: id.to_string(), cause },
            CallEvent::TxGranted { id } => AppEvent::TxGranted { call_id: id.to_string() },
            CallEvent::TxDenied { reason } => AppEvent::TxDenied { reason },
            CallEvent::TxEnded { id, preempted } => AppEvent::TxEnded { call_id: id.to_string(), preempted },
            CallEvent::PrivateUpdated(pc) => AppEvent::PrivateCall { call: private_info(&pc) },
            CallEvent::PrivateEnded { id, peer, cause } => AppEvent::PrivateCallEnded { call_id: id.to_string(), peer, cause },
            CallEvent::Focus(f) => AppEvent::AudioFocus { call_id: f.map(|u| u.to_string()) },
        },
    }
}

/// Opaque handle held by Dart.
pub struct TetraClient {
    handle: ClientHandle,
    events: Arc<Mutex<mpsc::UnboundedReceiver<ClientEvent>>>,
}

impl TetraClient {
    pub fn connect(config: TerminalConfig) -> TetraClient {
        let cfg = ClientConfig {
            endpoint: Endpoint {
                url: config.server_url,
                username: config.username,
                password: config.password,
                user_agent: format!("TetraBrewTerminal/{}", env!("CARGO_PKG_VERSION")),
                insecure_tls: config.insecure_tls,
            },
            issi: config.issi,
            name: config.name,
            groups: config.groups,
            selected_group: config.selected_group,
            default_priority: config.default_priority.min(15),
            allow_preemption: config.allow_preemption,
        };
        let (handle, events) = runtime().block_on(async { client::spawn(cfg) });
        TetraClient { handle, events: Arc::new(Mutex::new(events)) }
    }

    /// Next event, or `None` once the client has shut down.
    pub async fn next_event(&self) -> Option<AppEvent> {
        let events = self.events.clone();
        runtime().spawn(async move { events.lock().await.recv().await }).await.ok().flatten().map(convert)
    }

    pub fn ptt(&self, pressed: bool, group: Option<u32>, emergency: bool) {
        self.handle.send(Command::Ptt { pressed, group, emergency });
    }
    pub fn dial(&self, issi: u32, duplex: bool, hook: bool, priority: Option<u8>) {
        self.handle.send(Command::Dial { issi, duplex, hook, priority });
    }
    /// Call a phone/PBX number through the server's SIP gateway (always full duplex).
    pub fn dial_external(&self, number: String, priority: Option<u8>) {
        self.handle.send(Command::DialExternal { number, priority });
    }
    pub fn answer(&self) {
        self.handle.send(Command::Answer);
    }
    pub fn hangup(&self) {
        self.handle.send(Command::Hangup);
    }
    pub fn select_group(&self, gssi: u32) {
        self.handle.send(Command::SelectGroup(gssi));
    }
    pub fn set_groups(&self, groups: Vec<u32>, selected: Option<u32>) {
        self.handle.send(Command::SetGroups { groups, selected });
    }
    pub fn send_text(&self, local_id: u32, to: u32, text: String, immediate: bool, request_report: bool) {
        self.handle.send(Command::SendText { local_id, to, text, immediate, request_report });
    }
    /// `reason`: 0 power on, 2 emergency, 3 PTT, 20 user, 129 periodic (interval), 130 distance.
    pub fn send_location(&self, to: u32, location: LocationInfo, reason: u8) {
        let reason = match reason {
            0 => LipReason::PowerOn,
            1 => LipReason::PowerOff,
            2 => LipReason::Emergency,
            3 => LipReason::Ptt,
            4 => LipReason::Status,
            32 => LipReason::ImmediateRequestResponse,
            129 => LipReason::MaxIntervalExceeded,
            130 => LipReason::MaxDistanceTravelled,
            _ => LipReason::UserInitiated,
        };
        let location = Location {
            latitude: location.latitude,
            longitude: location.longitude,
            accuracy_m: location.accuracy_m,
            speed_kmh: location.speed_kmh,
            heading_deg: location.heading_deg,
        };
        self.handle.send(Command::SendLocation { to, location, reason });
    }
    pub fn query_subscribers(&self, issis: Vec<u32>) {
        self.handle.send(Command::QuerySubscribers(issis));
    }
    pub fn send_dtmf(&self, digit: String) {
        if let Some(c) = digit.bytes().next() {
            self.handle.send(Command::Dtmf(c));
        }
    }
    /// Microphone audio: 8 kHz mono PCM, any chunk size.
    pub fn push_mic_pcm(&self, pcm: Vec<i16>) {
        self.handle.send(Command::MicPcm(pcm));
    }
    pub fn shutdown(&self) {
        self.handle.send(Command::Shutdown);
    }
}
