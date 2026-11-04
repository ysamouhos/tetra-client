//! Call control engine: group calls (half duplex, PTT), private calls
//! (simplex or full duplex, hook or direct), call priority and pre-emption.
//!
//! Pure state machine: feed it user commands, received Brew messages and
//! clock ticks; it returns wire messages to send and events for the UI/audio
//! layer. No I/O, so every flow is unit-tested below.
//!
//! Priority (ETSI EN 300 392-2 clause 14.8.? "Call priority", 4 bits):
//! 0 = not defined, 1..=11 normal levels, 12..=14 pre-emptive, 15 = emergency
//! (pre-emptive, highest). Higher number wins, which is also brew-server's
//! default `higher_priority_number_wins`.

use crate::protocol::{self as p, cause, CallPayload, CircularCall, GroupTransmission, Message};
use std::collections::BTreeMap;
use std::time::{Duration, Instant};
use uuid::Uuid;

pub const PRIORITY_PREEMPTIVE_MIN: u8 = 12;
pub const PRIORITY_EMERGENCY: u8 = 15;

const SETUP_TIMEOUT: Duration = Duration::from_secs(30);
const RING_TIMEOUT: Duration = Duration::from_secs(60);
/// A group transmission with no traffic for this long is considered over even
/// if the GROUP_IDLE was lost.
const RX_STALE: Duration = Duration::from_secs(6);

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Outgoing,
    Incoming,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PrivateState {
    /// Outgoing: SETUP_REQUEST sent.
    Setup,
    /// Outgoing: callee accepted the setup.
    Proceeding,
    /// Outgoing: callee is ringing (play ringback).
    Alerting,
    /// Incoming: ringing here, waiting for the user to answer.
    Ringing,
    /// Incoming: answered, CONNECT_REQUEST sent, waiting for CONNECT_CONFIRM.
    Connecting,
    Connected,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Floor {
    Idle,
    Me,
    Peer,
}

#[derive(Debug, Clone, PartialEq)]
pub struct PrivateCall {
    pub id: Uuid,
    pub peer: u32,
    pub peer_name: Option<String>,
    /// External (non-TETRA) number: the SIP/PSTN side of a gateway call.
    pub number: Option<String>,
    pub direction: Direction,
    pub state: PrivateState,
    pub duplex: bool,
    pub hook: bool,
    pub priority: u8,
    /// Simplex only; duplex calls are always full duplex once connected.
    pub floor: Floor,
    since: Instant,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GroupActivity {
    pub id: Uuid,
    pub gssi: u32,
    pub talker: u32,
    pub talker_name: Option<String>,
    pub priority: u8,
    last_seen: Instant,
}

impl GroupActivity {
    pub fn is_emergency(&self) -> bool {
        self.priority >= PRIORITY_EMERGENCY
    }
}

#[derive(Debug, Clone, PartialEq)]
pub enum CallEvent {
    GroupTxStarted { gssi: u32, talker: u32, talker_name: Option<String>, priority: u8, id: Uuid },
    GroupTxEnded { gssi: u32, id: Uuid, cause: u8 },
    /// Our own PTT result.
    TxGranted { id: Uuid },
    TxDenied { reason: String },
    TxEnded { id: Uuid, preempted: bool },
    PrivateUpdated(PrivateCall),
    PrivateEnded { id: Uuid, peer: u32, cause: u8 },
    /// Which call's audio the speaker should play now (None = silence).
    Focus(Option<Uuid>),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Output {
    Send(Vec<u8>),
    Event(CallEvent),
}

#[derive(Debug, Clone)]
pub struct CallConfig {
    pub issi: u32,
    pub name: Option<String>,
    pub default_priority: u8,
    /// Let pre-emptive (12..=15) calls tear down lower-priority calls here.
    pub allow_preemption: bool,
}

#[derive(Debug, Clone, PartialEq)]
enum Tx {
    Group { id: Uuid, gssi: u32 },
    Private { id: Uuid },
}

pub struct CallEngine {
    cfg: CallConfig,
    selected_group: Option<u32>,
    groups: Vec<u32>,
    activity: BTreeMap<u32, GroupActivity>,
    private: Option<PrivateCall>,
    tx: Option<Tx>,
    focus: Option<Uuid>,
}

impl CallEngine {
    pub fn new(cfg: CallConfig) -> Self {
        Self { cfg, selected_group: None, groups: Vec::new(), activity: BTreeMap::new(), private: None, tx: None, focus: None }
    }

    pub fn issi(&self) -> u32 {
        self.cfg.issi
    }
    pub fn set_groups(&mut self, groups: Vec<u32>, selected: Option<u32>) {
        self.groups = groups;
        self.selected_group = selected.or(self.groups.first().copied());
    }
    pub fn select_group(&mut self, gssi: u32) -> Vec<Output> {
        self.selected_group = Some(gssi);
        let mut out = Vec::new();
        self.refocus(&mut out);
        out
    }
    pub fn selected_group(&self) -> Option<u32> {
        self.selected_group
    }
    pub fn private_call(&self) -> Option<&PrivateCall> {
        self.private.as_ref()
    }
    pub fn group_activity(&self) -> impl Iterator<Item = &GroupActivity> {
        self.activity.values()
    }
    /// Call id our microphone audio must be sent on, if we hold a floor.
    pub fn tx_call(&self) -> Option<Uuid> {
        match (&self.tx, &self.private) {
            (Some(Tx::Group { id, .. }) | Some(Tx::Private { id }), _) => Some(*id),
            (None, Some(pc)) if pc.state == PrivateState::Connected && pc.duplex => Some(pc.id),
            _ => None,
        }
    }
    pub fn focus(&self) -> Option<Uuid> {
        self.focus
    }

    fn busy_priority(&self) -> Option<u8> {
        let private = self.private.as_ref().map(|c| c.priority);
        let tx = match &self.tx {
            Some(Tx::Group { gssi, .. }) => self.activity.get(gssi).map(|a| a.priority),
            _ => None,
        };
        private.into_iter().chain(tx).max()
    }

    fn can_preempt(&self, incoming: u8, current: u8) -> bool {
        self.cfg.allow_preemption && incoming >= PRIORITY_PREEMPTIVE_MIN && incoming > current
    }

    // ───────────────────────── user commands ─────────────────────────

    /// PTT pressed. In a simplex private call it requests that call's floor,
    /// otherwise it starts a transmission on `gssi` (or the selected group).
    pub fn ptt_press(&mut self, gssi: Option<u32>, emergency: bool) -> Vec<Output> {
        let mut out = Vec::new();
        if self.tx.is_some() {
            return out;
        }
        if let Some(pc) = &mut self.private {
            if pc.state != PrivateState::Connected {
                out.push(Output::Event(CallEvent::TxDenied { reason: "private call not connected".into() }));
                return out;
            }
            if pc.duplex {
                return out; // full duplex: microphone is always live
            }
            if pc.floor == Floor::Peer {
                out.push(Output::Event(CallEvent::TxDenied { reason: "other party is talking".into() }));
                return out;
            }
            pc.floor = Floor::Me;
            let id = pc.id;
            out.push(Output::Send(p::build_grant(p::CALL_SIMPLEX_GRANTED, &id, 0, 0)));
            self.tx = Some(Tx::Private { id });
            out.push(Output::Event(CallEvent::TxGranted { id }));
            out.push(Output::Event(CallEvent::PrivateUpdated(self.private.clone().unwrap())));
            return out;
        }
        let Some(gssi) = gssi.or(self.selected_group) else {
            out.push(Output::Event(CallEvent::TxDenied { reason: "no talkgroup selected".into() }));
            return out;
        };
        let priority = if emergency { PRIORITY_EMERGENCY } else { self.cfg.default_priority };
        if let Some(a) = self.activity.get(&gssi)
            && a.talker != self.cfg.issi && priority <= a.priority {
                out.push(Output::Event(CallEvent::TxDenied { reason: format!("{} is talking", a.talker) }));
                return out;
            }
        let id = Uuid::new_v4();
        let g = GroupTransmission { source: self.cfg.issi, destination: gssi, priority, access: 0, service: 0, mnemonic: self.cfg.name.clone() };
        out.push(Output::Send(p::build_group_tx(&id, &g)));
        self.activity.insert(
            gssi,
            GroupActivity { id, gssi, talker: self.cfg.issi, talker_name: self.cfg.name.clone(), priority, last_seen: Instant::now() },
        );
        self.tx = Some(Tx::Group { id, gssi });
        out.push(Output::Event(CallEvent::TxGranted { id }));
        self.refocus(&mut out);
        out
    }

    pub fn ptt_release(&mut self) -> Vec<Output> {
        let mut out = Vec::new();
        match self.tx.take() {
            Some(Tx::Group { id, gssi }) => {
                out.push(Output::Send(p::build_cause(p::CALL_GROUP_IDLE, &id, cause::NOT_DEFINED)));
                if self.activity.get(&gssi).is_some_and(|a| a.id == id) {
                    self.activity.remove(&gssi);
                }
                out.push(Output::Event(CallEvent::TxEnded { id, preempted: false }));
            }
            Some(Tx::Private { id }) => {
                out.push(Output::Send(p::build_grant(p::CALL_SIMPLEX_IDLE, &id, 0, 0)));
                if let Some(pc) = &mut self.private {
                    pc.floor = Floor::Idle;
                    out.push(Output::Event(CallEvent::PrivateUpdated(pc.clone())));
                }
                out.push(Output::Event(CallEvent::TxEnded { id, preempted: false }));
            }
            None => {}
        }
        self.refocus(&mut out);
        out
    }

    /// Start a private call. `hook` = the callee must answer (phone-style);
    /// otherwise a direct call that connects straight away.
    pub fn dial(&mut self, peer: u32, duplex: bool, hook: bool, priority: Option<u8>) -> Vec<Output> {
        self.dial_target(peer, None, duplex, hook, priority)
    }

    /// Call a number outside the TETRA network (phone/PBX via the server's SIP
    /// gateway). Per brew-server: `destination` = 0 and the digits travel in the
    /// ASCII `number` field, which the server matches against its voice routes.
    /// Gateway calls are always full duplex with hook signalling.
    pub fn dial_external(&mut self, number: &str, priority: Option<u8>) -> Vec<Output> {
        let digits: String = number.chars().filter(|c| c.is_ascii_digit() || matches!(c, '*' | '#' | '+')).take(31).collect();
        if digits.is_empty() {
            return vec![Output::Event(CallEvent::TxDenied { reason: "no number to dial".into() })];
        }
        self.dial_target(0, Some(digits), true, true, priority)
    }

    fn dial_target(&mut self, peer: u32, number: Option<String>, duplex: bool, hook: bool, priority: Option<u8>) -> Vec<Output> {
        let mut out = Vec::new();
        let priority = priority.unwrap_or(self.cfg.default_priority);
        if self.private.is_some() {
            out.push(Output::Event(CallEvent::TxDenied { reason: "already in a private call".into() }));
            return out;
        }
        if self.tx.is_some() {
            out.extend(self.ptt_release());
        }
        let id = Uuid::new_v4();
        let c = CircularCall {
            source: self.cfg.issi,
            destination: peer,
            priority,
            duplex: duplex as u8,
            method: hook as u8,
            number: number.clone().unwrap_or_default(),
            mnemonic: self.cfg.name.clone(),
            ..Default::default()
        };
        out.push(Output::Send(p::build_circular(p::CALL_SETUP_REQUEST, &id, &c)));
        let pc = PrivateCall {
            id,
            peer,
            peer_name: None,
            number,
            direction: Direction::Outgoing,
            state: PrivateState::Setup,
            duplex,
            hook,
            priority,
            floor: Floor::Idle,
            since: Instant::now(),
        };
        out.push(Output::Event(CallEvent::PrivateUpdated(pc.clone())));
        self.private = Some(pc);
        self.refocus(&mut out);
        out
    }

    pub fn answer(&mut self) -> Vec<Output> {
        let mut out = Vec::new();
        let issi = self.cfg.issi;
        let Some(pc) = self.private.as_mut().filter(|c| c.state == PrivateState::Ringing) else { return out };
        out.push(Output::Send(connect_request(pc, issi)));
        pc.state = PrivateState::Connecting;
        pc.since = Instant::now();
        out.push(Output::Event(CallEvent::PrivateUpdated(pc.clone())));
        out
    }

    /// Hang up / reject the private call.
    pub fn hangup(&mut self) -> Vec<Output> {
        let mut out = Vec::new();
        if let Some(pc) = &self.private {
            let wire = if pc.state == PrivateState::Ringing {
                p::build_cause(p::CALL_SETUP_REJECT, &pc.id, cause::CALLED_PARTY_REJECTED)
            } else {
                p::build_cause(p::CALL_RELEASE, &pc.id, cause::USER_REQUESTED)
            };
            out.push(Output::Send(wire));
            self.end_private(cause::USER_REQUESTED, &mut out);
        }
        out
    }

    fn end_private(&mut self, c: u8, out: &mut Vec<Output>) {
        if let Some(pc) = self.private.take() {
            if matches!(self.tx, Some(Tx::Private { id }) if id == pc.id) {
                self.tx = None;
                out.push(Output::Event(CallEvent::TxEnded { id: pc.id, preempted: c == cause::PRE_EMPTIVE_USE }));
            }
            out.push(Output::Event(CallEvent::PrivateEnded { id: pc.id, peer: pc.peer, cause: c }));
        }
        self.refocus(out);
    }

    /// Release whatever lower-priority activity stands in the way of an
    /// incoming pre-emptive call.
    fn preempt_local(&mut self, out: &mut Vec<Output>) {
        if let Some(pc) = &self.private {
            out.push(Output::Send(p::build_cause(p::CALL_RELEASE, &pc.id, cause::PRE_EMPTIVE_USE)));
            self.end_private(cause::PRE_EMPTIVE_USE, out);
        }
        if let Some(Tx::Group { id, gssi }) = self.tx.take() {
            out.push(Output::Send(p::build_cause(p::CALL_GROUP_IDLE, &id, cause::PRE_EMPTIVE_USE)));
            self.activity.remove(&gssi);
            out.push(Output::Event(CallEvent::TxEnded { id, preempted: true }));
        }
    }

    // ───────────────────────── network input ─────────────────────────

    pub fn on_message(&mut self, msg: &Message) -> Vec<Output> {
        let mut out = Vec::new();
        match msg {
            Message::CallControl { state, id, payload } => self.on_call_control(*state, *id, payload, &mut out),
            Message::Frame { kind: p::FRAME_TRAFFIC_CHANNEL, id, .. } => {
                for a in self.activity.values_mut() {
                    if a.id == *id {
                        a.last_seen = Instant::now();
                    }
                }
            }
            _ => {}
        }
        out
    }

    fn on_call_control(&mut self, state: u8, id: Uuid, payload: &CallPayload, out: &mut Vec<Output>) {
        match (state, payload) {
            (p::CALL_GROUP_TX, CallPayload::Group(g)) => self.on_group_tx(id, g, out),
            (p::CALL_GROUP_IDLE, _) => {
                let c = if let CallPayload::Cause(c) = payload { *c } else { 0 };
                if let Some(Tx::Group { id: my, gssi }) = &self.tx
                    && *my == id {
                        // The server took our floor (pre-empted by a higher-priority talker).
                        let (my, gssi) = (*my, *gssi);
                        self.tx = None;
                        if self.activity.get(&gssi).is_some_and(|a| a.id == my) {
                            self.activity.remove(&gssi);
                        }
                        out.push(Output::Event(CallEvent::TxEnded { id: my, preempted: true }));
                        self.refocus(out);
                        return;
                    }
                if let Some((&gssi, _)) = self.activity.iter().find(|(_, a)| a.id == id) {
                    self.activity.remove(&gssi);
                    out.push(Output::Event(CallEvent::GroupTxEnded { gssi, id, cause: c }));
                    self.refocus(out);
                }
            }
            (p::CALL_SETUP_REQUEST, CallPayload::Circular(c)) if c.destination == self.cfg.issi => {
                self.on_setup_request(id, c, out)
            }
            _ => self.on_private_signal(state, id, payload, out),
        }
    }

    fn on_group_tx(&mut self, id: Uuid, g: &GroupTransmission, out: &mut Vec<Output>) {
        if g.source == self.cfg.issi && matches!(&self.tx, Some(Tx::Group { id: my, .. }) if *my == id) {
            return; // echo of our own transmission
        }
        if !self.groups.contains(&g.destination) {
            return; // not affiliated here
        }
        if self.can_preempt(g.priority, self.busy_priority().unwrap_or(0)) && self.busy_priority().is_some() {
            self.preempt_local(out);
        }
        // A new talker on a group we are transmitting to has taken the floor.
        if let Some(Tx::Group { id: my, gssi }) = &self.tx
            && *gssi == g.destination && *my != id {
                let my = *my;
                self.tx = None;
                out.push(Output::Event(CallEvent::TxEnded { id: my, preempted: true }));
            }
        let a = GroupActivity {
            id,
            gssi: g.destination,
            talker: g.source,
            talker_name: g.mnemonic.clone(),
            priority: g.priority,
            last_seen: Instant::now(),
        };
        if let Some(old) = self.activity.insert(g.destination, a)
            && old.id != id {
                out.push(Output::Event(CallEvent::GroupTxEnded { gssi: old.gssi, id: old.id, cause: cause::PRE_EMPTIVE_USE }));
            }
        out.push(Output::Event(CallEvent::GroupTxStarted {
            gssi: g.destination,
            talker: g.source,
            talker_name: g.mnemonic.clone(),
            priority: g.priority,
            id,
        }));
        self.refocus(out);
    }

    fn on_setup_request(&mut self, id: Uuid, c: &CircularCall, out: &mut Vec<Output>) {
        if let Some(busy) = self.busy_priority() {
            if self.private.as_ref().is_some_and(|pc| pc.id == id) {
                return; // duplicate
            }
            if self.can_preempt(c.priority, busy) {
                self.preempt_local(out);
            } else {
                out.push(Output::Send(p::build_cause(p::CALL_SETUP_REJECT, &id, cause::CALLED_PARTY_BUSY)));
                return;
            }
        }
        let hook = c.method != 0;
        let mut pc = PrivateCall {
            id,
            peer: c.source,
            peer_name: c.mnemonic.clone(),
            number: (!c.number.trim().is_empty()).then(|| c.number.trim().to_string()),
            direction: Direction::Incoming,
            state: PrivateState::Ringing,
            duplex: c.duplex != 0,
            hook,
            priority: c.priority,
            floor: Floor::Idle,
            since: Instant::now(),
        };
        out.push(Output::Send(p::build_empty(p::CALL_SETUP_ACCEPT, &id)));
        if hook {
            out.push(Output::Send(p::build_empty(p::CALL_ALERT, &id)));
        } else {
            // Direct call: no answer gesture, connect immediately.
            out.push(Output::Send(connect_request(&pc, self.cfg.issi)));
            pc.state = PrivateState::Connecting;
        }
        out.push(Output::Event(CallEvent::PrivateUpdated(pc.clone())));
        self.private = Some(pc);
        self.refocus(out);
    }

    fn on_private_signal(&mut self, state: u8, id: Uuid, payload: &CallPayload, out: &mut Vec<Output>) {
        let Some(pc) = self.private.as_mut().filter(|c| c.id == id) else { return };
        let mut changed = true;
        match state {
            p::CALL_SETUP_ACCEPT if pc.state == PrivateState::Setup => pc.state = PrivateState::Proceeding,
            p::CALL_ALERT if matches!(pc.state, PrivateState::Setup | PrivateState::Proceeding) => {
                pc.state = PrivateState::Alerting
            }
            p::CALL_CONNECT_REQUEST if pc.direction == Direction::Outgoing => {
                out.push(Output::Send(p::build_grant(p::CALL_CONNECT_CONFIRM, &id, 0, 0)));
                pc.state = PrivateState::Connected;
            }
            p::CALL_CONNECT_CONFIRM if pc.direction == Direction::Incoming => pc.state = PrivateState::Connected,
            p::CALL_SIMPLEX_GRANTED => {
                pc.floor = Floor::Peer;
                if matches!(self.tx, Some(Tx::Private { .. })) {
                    self.tx = None;
                    out.push(Output::Event(CallEvent::TxEnded { id, preempted: true }));
                }
            }
            p::CALL_SIMPLEX_IDLE if pc.floor == Floor::Peer => pc.floor = Floor::Idle,
            p::CALL_SETUP_REJECT | p::CALL_RELEASE => {
                let c = if let CallPayload::Cause(c) = payload { *c } else { 0 };
                self.end_private(c, out);
                return;
            }
            _ => changed = false,
        }
        if changed {
            out.push(Output::Event(CallEvent::PrivateUpdated(pc.clone())));
            self.refocus(out);
        }
    }

    /// Call periodically (e.g. every 500 ms) to run timers.
    pub fn tick(&mut self, now: Instant) -> Vec<Output> {
        let mut out = Vec::new();
        if let Some(pc) = &self.private {
            let limit = match pc.state {
                PrivateState::Setup | PrivateState::Proceeding | PrivateState::Connecting => Some(SETUP_TIMEOUT),
                PrivateState::Alerting | PrivateState::Ringing => Some(RING_TIMEOUT),
                PrivateState::Connected => None,
            };
            if limit.is_some_and(|l| now.duration_since(pc.since) > l) {
                out.push(Output::Send(p::build_cause(p::CALL_RELEASE, &pc.id, cause::EXPIRY_OF_TIMER)));
                self.end_private(cause::EXPIRY_OF_TIMER, &mut out);
            }
        }
        let my_tx = self.tx_call();
        let stale: Vec<_> = self
            .activity
            .values()
            .filter(|a| Some(a.id) != my_tx && now.duration_since(a.last_seen) > RX_STALE)
            .map(|a| (a.gssi, a.id))
            .collect();
        for (gssi, id) in stale {
            self.activity.remove(&gssi);
            out.push(Output::Event(CallEvent::GroupTxEnded { gssi, id, cause: cause::EXPIRY_OF_TIMER }));
        }
        if !out.is_empty() {
            self.refocus(&mut out);
        }
        out
    }

    /// Decide whose audio is played: a connected private call, unless a
    /// group call of strictly higher priority is active; among group calls the
    /// highest priority wins, ties go to the selected talkgroup.
    fn refocus(&mut self, out: &mut Vec<Output>) {
        let my_tx = match &self.tx {
            Some(Tx::Group { id, .. }) => Some(*id),
            _ => None,
        };
        let best_group = self
            .activity
            .values()
            .filter(|a| Some(a.id) != my_tx)
            .max_by_key(|a| (a.priority, Some(a.gssi) == self.selected_group, std::cmp::Reverse(a.last_seen)));
        let private = self.private.as_ref().filter(|c| c.state == PrivateState::Connected);
        let focus = match (private, best_group) {
            (Some(pc), Some(g)) if g.priority > pc.priority => Some(g.id),
            (Some(pc), _) => Some(pc.id),
            (None, Some(g)) if my_tx.is_none() => Some(g.id),
            _ => None,
        };
        if focus != self.focus {
            self.focus = focus;
            out.push(Output::Event(CallEvent::Focus(focus)));
        }
    }
}

fn connect_request(pc: &PrivateCall, me: u32) -> Vec<u8> {
    let c = CircularCall {
        source: pc.peer,
        destination: me,
        priority: pc.priority,
        duplex: pc.duplex as u8,
        method: pc.hook as u8,
        ..Default::default()
    };
    p::build_circular(p::CALL_CONNECT_REQUEST, &pc.id, &c)
}

#[cfg(test)]
mod tests {
    use super::*;

    const ME: u32 = 2040001;
    const PEER: u32 = 2040002;
    const TG: u32 = 91;

    fn engine() -> CallEngine {
        let mut e = CallEngine::new(CallConfig { issi: ME, name: Some("SV1".into()), default_priority: 1, allow_preemption: true });
        e.set_groups(vec![TG, 92], Some(TG));
        e
    }
    fn sent(out: &[Output]) -> Vec<Message> {
        out.iter().filter_map(|o| if let Output::Send(w) = o { Some(p::parse(w).unwrap()) } else { None }).collect()
    }
    fn states(out: &[Output]) -> Vec<u8> {
        sent(out).iter().filter_map(|m| if let Message::CallControl { state, .. } = m { Some(*state) } else { None }).collect()
    }
    fn group_tx(id: Uuid, src: u32, gssi: u32, prio: u8) -> Message {
        Message::CallControl {
            state: p::CALL_GROUP_TX,
            id,
            payload: CallPayload::Group(GroupTransmission { source: src, destination: gssi, priority: prio, access: 0, service: 0, mnemonic: None }),
        }
    }
    fn cc(state: u8, id: Uuid, payload: CallPayload) -> Message {
        Message::CallControl { state, id, payload }
    }

    #[test]
    fn group_ptt_cycle() {
        let mut e = engine();
        let out = e.ptt_press(None, false);
        assert_eq!(states(&out), vec![p::CALL_GROUP_TX]);
        let id = e.tx_call().unwrap();
        let out = e.ptt_release();
        assert_eq!(states(&out), vec![p::CALL_GROUP_IDLE]);
        assert!(out.contains(&Output::Event(CallEvent::TxEnded { id, preempted: false })));
        assert_eq!(e.tx_call(), None);
    }

    #[test]
    fn ptt_denied_while_someone_talks_unless_emergency() {
        let mut e = engine();
        let other = Uuid::new_v4();
        e.on_message(&group_tx(other, PEER, TG, 1));
        assert_eq!(e.focus(), Some(other));
        assert!(matches!(e.ptt_press(None, false)[0], Output::Event(CallEvent::TxDenied { .. })));
        let out = e.ptt_press(None, true);
        let Message::CallControl { payload: CallPayload::Group(g), .. } = &sent(&out)[0] else { panic!() };
        assert_eq!(g.priority, PRIORITY_EMERGENCY);
    }

    #[test]
    fn server_preemption_of_our_floor() {
        let mut e = engine();
        e.ptt_press(None, false);
        let my = e.tx_call().unwrap();
        let out = e.on_message(&cc(p::CALL_GROUP_IDLE, my, CallPayload::Cause(cause::PRE_EMPTIVE_USE)));
        assert!(out.contains(&Output::Event(CallEvent::TxEnded { id: my, preempted: true })));
        let em = Uuid::new_v4();
        e.on_message(&group_tx(em, PEER, TG, 15));
        assert_eq!(e.focus(), Some(em));
    }

    #[test]
    fn higher_priority_group_wins_audio_focus() {
        let mut e = engine();
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        e.on_message(&group_tx(a, PEER, TG, 1));
        e.on_message(&group_tx(b, 2040009, 92, 5));
        assert_eq!(e.focus(), Some(b), "priority beats selected group");
        e.on_message(&cc(p::CALL_GROUP_IDLE, b, CallPayload::Cause(0)));
        assert_eq!(e.focus(), Some(a));
        // Not affiliated: ignored.
        e.on_message(&group_tx(Uuid::new_v4(), PEER, 555, 15));
        assert_eq!(e.focus(), Some(a));
    }

    #[test]
    fn outgoing_duplex_private_call() {
        let mut e = engine();
        let out = e.dial(PEER, true, true, None);
        assert_eq!(states(&out), vec![p::CALL_SETUP_REQUEST]);
        let id = e.private_call().unwrap().id;
        e.on_message(&cc(p::CALL_SETUP_ACCEPT, id, CallPayload::Empty));
        e.on_message(&cc(p::CALL_ALERT, id, CallPayload::Empty));
        assert_eq!(e.private_call().unwrap().state, PrivateState::Alerting);
        let out = e.on_message(&cc(p::CALL_CONNECT_REQUEST, id, CallPayload::Circular(CircularCall::default())));
        assert_eq!(states(&out), vec![p::CALL_CONNECT_CONFIRM]);
        assert_eq!(e.private_call().unwrap().state, PrivateState::Connected);
        assert_eq!(e.tx_call(), Some(id), "duplex: mic live without PTT");
        assert_eq!(e.focus(), Some(id));
        let out = e.hangup();
        assert_eq!(states(&out), vec![p::CALL_RELEASE]);
        assert!(e.private_call().is_none());
    }

    #[test]
    fn incoming_hook_call_answer_and_simplex_floor() {
        let mut e = engine();
        let id = Uuid::new_v4();
        let setup = CircularCall { source: PEER, destination: ME, priority: 1, duplex: 0, method: 1, ..Default::default() };
        let out = e.on_message(&cc(p::CALL_SETUP_REQUEST, id, CallPayload::Circular(setup)));
        assert_eq!(states(&out), vec![p::CALL_SETUP_ACCEPT, p::CALL_ALERT]);
        assert_eq!(e.private_call().unwrap().state, PrivateState::Ringing);
        assert_eq!(states(&e.answer()), vec![p::CALL_CONNECT_REQUEST]);
        e.on_message(&cc(p::CALL_CONNECT_CONFIRM, id, CallPayload::Grant { grant: 0, permission: 0 }));
        assert_eq!(e.private_call().unwrap().state, PrivateState::Connected);
        assert_eq!(e.tx_call(), None, "simplex: mic closed until PTT");
        assert_eq!(states(&e.ptt_press(None, false)), vec![p::CALL_SIMPLEX_GRANTED]);
        assert_eq!(e.tx_call(), Some(id));
        assert_eq!(states(&e.ptt_release()), vec![p::CALL_SIMPLEX_IDLE]);
        e.on_message(&cc(p::CALL_SIMPLEX_GRANTED, id, CallPayload::Grant { grant: 0, permission: 0 }));
        assert!(matches!(e.ptt_press(None, false)[0], Output::Event(CallEvent::TxDenied { .. })));
        let out = e.on_message(&cc(p::CALL_RELEASE, id, CallPayload::Cause(1)));
        assert!(out.contains(&Output::Event(CallEvent::PrivateEnded { id, peer: PEER, cause: 1 })));
    }

    #[test]
    fn external_call_uses_number_field() {
        let mut e = engine();
        let out = e.dial_external("9 210-555 1234", None);
        let Message::CallControl { state, payload: CallPayload::Circular(c), .. } = &sent(&out)[0] else { panic!() };
        assert_eq!(*state, p::CALL_SETUP_REQUEST);
        assert_eq!((c.destination, c.number.as_str(), c.duplex, c.method), (0, "92105551234", 1, 1));
        let pc = e.private_call().unwrap();
        assert_eq!(pc.number.as_deref(), Some("92105551234"));
        let id = pc.id;
        let out = e.on_message(&cc(p::CALL_CONNECT_REQUEST, id, CallPayload::Circular(CircularCall::default())));
        assert_eq!(states(&out), vec![p::CALL_CONNECT_CONFIRM]);
        assert_eq!(e.tx_call(), Some(id), "phone calls are full duplex");
        assert!(matches!(e.dial_external("abc", None)[0], Output::Event(CallEvent::TxDenied { .. })));
    }

    #[test]
    fn direct_call_connects_without_answer() {
        let mut e = engine();
        let id = Uuid::new_v4();
        let setup = CircularCall { source: PEER, destination: ME, duplex: 0, method: 0, ..Default::default() };
        let out = e.on_message(&cc(p::CALL_SETUP_REQUEST, id, CallPayload::Circular(setup)));
        assert_eq!(states(&out), vec![p::CALL_SETUP_ACCEPT, p::CALL_CONNECT_REQUEST]);
    }

    #[test]
    fn busy_rejects_normal_but_preempts_for_emergency() {
        let mut e = engine();
        e.dial(PEER, true, true, None);
        let first = e.private_call().unwrap().id;
        let id2 = Uuid::new_v4();
        let normal = CircularCall { source: 2040003, destination: ME, priority: 5, method: 1, ..Default::default() };
        let out = e.on_message(&cc(p::CALL_SETUP_REQUEST, id2, CallPayload::Circular(normal)));
        assert_eq!(states(&out), vec![p::CALL_SETUP_REJECT]);
        assert_eq!(e.private_call().unwrap().id, first);
        let id3 = Uuid::new_v4();
        let emerg = CircularCall { source: 2040003, destination: ME, priority: 15, method: 1, ..Default::default() };
        let out = e.on_message(&cc(p::CALL_SETUP_REQUEST, id3, CallPayload::Circular(emerg)));
        assert_eq!(states(&out), vec![p::CALL_RELEASE, p::CALL_SETUP_ACCEPT, p::CALL_ALERT]);
        assert_eq!(e.private_call().unwrap().id, id3);
    }

    #[test]
    fn timers_expire_unanswered_and_stale() {
        let mut e = engine();
        e.dial(PEER, true, true, None);
        let rx = Uuid::new_v4();
        e.on_message(&group_tx(rx, PEER, 92, 1));
        let later = Instant::now() + Duration::from_secs(31);
        let out = e.tick(later);
        assert_eq!(states(&out), vec![p::CALL_RELEASE]);
        assert!(e.private_call().is_none());
        assert_eq!(e.group_activity().count(), 0);
    }
}
