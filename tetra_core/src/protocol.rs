//! Brew (TETRA Homebrew Protocol) wire format, client side.
//!
//! Layouts follow the TetraPack Brew specification and are kept byte-for-byte
//! compatible with `ysamouhos/brew-server` (`src/protocol.rs`): little-endian,
//! packed, a 2-byte class/type prefix, a 16-byte call UUID on call-control and
//! frame messages, and the protocol-version-1 SS-TPI `mnemonic[34]` tail on
//! `CALL_GROUP_TX` and `CALL_SETUP_REQUEST` only.

use uuid::Uuid;

pub const BREW_PROTOCOL_VERSION: u8 = 1;

pub const CLASS_SUBSCRIBER: u8 = 0xf0;
pub const CLASS_CALL_CONTROL: u8 = 0xf1;
pub const CLASS_FRAME: u8 = 0xf2;
pub const CLASS_ERROR: u8 = 0xf3;
pub const CLASS_SERVICE: u8 = 0xf4;

pub const SUB_DEREGISTER: u8 = 0;
pub const SUB_REGISTER: u8 = 1;
pub const SUB_REREGISTER: u8 = 2;
pub const SUB_AFFILIATE: u8 = 8;
pub const SUB_DEAFFILIATE: u8 = 9;

pub const CALL_GROUP_TX: u8 = 2;
pub const CALL_GROUP_IDLE: u8 = 3;
pub const CALL_SETUP_REQUEST: u8 = 4;
pub const CALL_SETUP_ACCEPT: u8 = 5;
pub const CALL_SETUP_REJECT: u8 = 6;
pub const CALL_ALERT: u8 = 7;
pub const CALL_CONNECT_REQUEST: u8 = 8;
pub const CALL_CONNECT_CONFIRM: u8 = 9;
pub const CALL_RELEASE: u8 = 10;
pub const CALL_SHORT_TRANSFER: u8 = 11;
pub const CALL_SIMPLEX_GRANTED: u8 = 12;
pub const CALL_SIMPLEX_IDLE: u8 = 13;

pub const FRAME_TRAFFIC_CHANNEL: u8 = 0;
pub const FRAME_SDS_TRANSFER: u8 = 1;
pub const FRAME_SDS_REPORT: u8 = 2;
pub const FRAME_DTMF: u8 = 3;

pub const ERROR_MALFORMED: u8 = 0;
pub const ERROR_RESTRICTED: u8 = 1;

pub const SERVICE_QUERY_SUBSCRIBERS: u8 = 1;
pub const SERVICE_SUBSCRIBER_PROFILES: u8 = 2;

/// Disconnect causes, ETSI EN 300 392-2 clause 14.8.18 (subset used here).
pub mod cause {
    pub const NOT_DEFINED: u8 = 0;
    pub const USER_REQUESTED: u8 = 1;
    pub const CALLED_PARTY_BUSY: u8 = 2;
    pub const CALLED_PARTY_NOT_REACHABLE: u8 = 3;
    pub const CALLED_PARTY_REJECTED: u8 = 5;
    pub const PRE_EMPTIVE_USE: u8 = 9;
    pub const SWMI_REQUESTED: u8 = 14;
    pub const EXPIRY_OF_TIMER: u8 = 13;
}

/// Payload sizes (see brew-server for the derivations).
pub const CIRCULAR_CALL_BASE_LEN: usize = 4 + 4 + 32 + 11;
pub const GROUP_TX_BASE_LEN: usize = 4 + 4 + 1 + 1 + 2;
pub const MNEMONIC_FIELD_LEN: usize = 34;
const HEADER_LEN: usize = 18; // class, type, uuid

/// ACELP: 137 coded bits per 30 ms subframe, 240 PCM samples @ 8 kHz.
pub const ACELP_CODED_FRAME_BITS: usize = 137;
pub const ACELP_CODED_FRAME_BYTES: usize = 18;
pub const ACELP_PCM_SAMPLES: usize = 240;
/// One Brew traffic frame = STE header byte + two subframes (60 ms).
pub const STE_VOICE_PAYLOAD_BYTES: usize = 36;

#[derive(Debug, thiserror::Error, PartialEq)]
pub enum ParseError {
    #[error("Brew message too short ({0} bytes)")]
    TooShort(usize),
    #[error("unknown Brew class 0x{0:02x}")]
    UnknownClass(u8),
    #[error("invalid UTF-8 in service message")]
    InvalidUtf8,
}

/// Individual (circuit-mode) call parameters, `struct BrewCircularCall`.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct CircularCall {
    pub source: u32,
    pub destination: u32,
    pub number: String,
    /// Call priority, 0..=15 (14.8.? "Call priority"; 15 = emergency).
    pub priority: u8,
    /// Basic service (14.79). 0 = TETRA encoded speech.
    pub service: u8,
    /// Circuit mode type (14.52). 0 = TCH/S speech.
    pub mode: u8,
    /// 1 = duplex, 0 = simplex.
    pub duplex: u8,
    /// Hook method (14.62). 1 = hook signalling (called party must answer),
    /// 0 = direct call (no answer gesture).
    pub method: u8,
    /// Communication type (14.54). 0 = point-to-point.
    pub communication: u8,
    pub grant: u8,
    pub permission: u8,
    pub timeout: u8,
    pub ownership: u8,
    pub queued: u8,
    pub mnemonic: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct GroupTransmission {
    pub source: u32,
    pub destination: u32,
    pub priority: u8,
    pub access: u8,
    pub service: u16,
    pub mnemonic: Option<String>,
}

#[derive(Debug, Clone, PartialEq)]
pub enum CallPayload {
    Group(GroupTransmission),
    Circular(CircularCall),
    Cause(u8),
    Grant { grant: u8, permission: u8 },
    ShortTransfer { source: u32, destination: u32, number: String },
    Empty,
    Raw(Vec<u8>),
}

#[derive(Debug, Clone, PartialEq)]
pub enum Message {
    Subscriber { kind: u8, issi: u32, time: u64, fraction: u32, groups: Vec<u32> },
    CallControl { state: u8, id: Uuid, payload: CallPayload },
    Frame { kind: u8, id: Uuid, length_bits: u16, data: Vec<u8> },
    Error { kind: u8, data: Vec<u8> },
    Service { kind: u8, json: String },
}

fn u16le(d: &[u8], o: usize) -> u16 {
    u16::from_le_bytes([d[o], d[o + 1]])
}
fn u32le(d: &[u8], o: usize) -> u32 {
    u32::from_le_bytes(d[o..o + 4].try_into().unwrap())
}
fn u64le(d: &[u8], o: usize) -> u64 {
    u64::from_le_bytes(d[o..o + 8].try_into().unwrap())
}
fn ascii_field(d: &[u8]) -> String {
    let end = d.iter().position(|&b| b == 0).unwrap_or(d.len());
    String::from_utf8_lossy(&d[..end]).into_owned()
}

/// Decode an SS-TPI mnemonic (EN 300 392-9 table 17): scheme, length in
/// bits, characters. Schemes 0 (8-bit) and 1 (7-bit packed) as the server does.
pub fn decode_mnemonic(field: &[u8]) -> Option<String> {
    if field.len() < 2 || field[1] == 0 {
        return None;
    }
    let len_bits = field[1] as usize;
    let text = &field[2..];
    let s: String = match field[0] & 0x7f {
        0x01 => {
            let mut out = String::new();
            for i in 0..len_bits / 7 {
                let bit = i * 7;
                let (b, off) = (bit / 8, bit % 8);
                if b >= text.len() {
                    break;
                }
                let mut v = (text[b] >> off) as u16;
                if off > 1 && b + 1 < text.len() {
                    v |= (text[b + 1] as u16) << (8 - off);
                }
                out.push(((v & 0x7f) as u8) as char);
            }
            out
        }
        _ => text.iter().take((len_bits / 8).min(text.len())).map(|&b| b as char).collect(),
    };
    let s = s.trim_end_matches(['\0', ' ']).to_string();
    (!s.is_empty()).then_some(s)
}

/// Encode a talker name as an 8-bit (scheme 0) mnemonic field of exactly 34
/// bytes. Up to 32 Latin-1 characters; others are replaced with '?'.
pub fn encode_mnemonic(name: &str) -> [u8; MNEMONIC_FIELD_LEN] {
    let mut out = [0u8; MNEMONIC_FIELD_LEN];
    let chars: Vec<u8> = name
        .chars()
        .take(MNEMONIC_FIELD_LEN - 2)
        .map(|c| if (c as u32) < 256 { c as u8 } else { b'?' })
        .collect();
    out[0] = 0x00;
    out[1] = (chars.len() * 8) as u8;
    out[2..2 + chars.len()].copy_from_slice(&chars);
    out
}

pub fn parse(d: &[u8]) -> Result<Message, ParseError> {
    if d.len() < 2 {
        return Err(ParseError::TooShort(d.len()));
    }
    match d[0] {
        CLASS_SUBSCRIBER => {
            if d.len() < 18 {
                return Err(ParseError::TooShort(d.len()));
            }
            let groups = d[18..].chunks_exact(4).map(|c| u32::from_le_bytes(c.try_into().unwrap())).collect();
            Ok(Message::Subscriber { kind: d[1], issi: u32le(d, 2), time: u64le(d, 6), fraction: u32le(d, 14), groups })
        }
        CLASS_CALL_CONTROL => parse_call(d),
        CLASS_FRAME => {
            if d.len() < 20 {
                return Err(ParseError::TooShort(d.len()));
            }
            Ok(Message::Frame {
                kind: d[1],
                id: Uuid::from_bytes(d[2..18].try_into().unwrap()),
                length_bits: u16le(d, 18),
                data: d[20..].to_vec(),
            })
        }
        CLASS_ERROR => Ok(Message::Error { kind: d[1], data: d[2..].to_vec() }),
        CLASS_SERVICE => {
            let raw = &d[2..];
            let end = raw.iter().position(|&b| b == 0).unwrap_or(raw.len());
            let json = std::str::from_utf8(&raw[..end]).map_err(|_| ParseError::InvalidUtf8)?.to_owned();
            Ok(Message::Service { kind: d[1], json })
        }
        c => Err(ParseError::UnknownClass(c)),
    }
}

fn parse_circular(p: &[u8], with_mnemonic: bool) -> CircularCall {
    let mnemonic = if with_mnemonic {
        p.get(CIRCULAR_CALL_BASE_LEN..CIRCULAR_CALL_BASE_LEN + MNEMONIC_FIELD_LEN).and_then(decode_mnemonic)
    } else {
        None
    };
    CircularCall {
        source: u32le(p, 0),
        destination: u32le(p, 4),
        number: ascii_field(&p[8..40]),
        priority: p[40],
        service: p[41],
        mode: p[42],
        duplex: p[43],
        method: p[44],
        communication: p[45],
        grant: p[46],
        permission: p[47],
        timeout: p[48],
        ownership: p[49],
        queued: p[50],
        mnemonic,
    }
}

fn parse_call(d: &[u8]) -> Result<Message, ParseError> {
    if d.len() < HEADER_LEN {
        return Err(ParseError::TooShort(d.len()));
    }
    let id = Uuid::from_bytes(d[2..18].try_into().unwrap());
    let p = &d[HEADER_LEN..];
    let short = || ParseError::TooShort(d.len());
    let payload = match d[1] {
        CALL_GROUP_TX => {
            if p.len() < GROUP_TX_BASE_LEN {
                return Err(short());
            }
            let mnemonic = p.get(GROUP_TX_BASE_LEN..).filter(|t| !t.is_empty()).and_then(|t| {
                decode_mnemonic(&t[..t.len().min(MNEMONIC_FIELD_LEN)])
            });
            CallPayload::Group(GroupTransmission {
                source: u32le(p, 0),
                destination: u32le(p, 4),
                priority: p[8],
                access: p[9],
                service: u16le(p, 10),
                mnemonic,
            })
        }
        CALL_SETUP_REQUEST | CALL_CONNECT_REQUEST => {
            if p.len() < CIRCULAR_CALL_BASE_LEN {
                return Err(short());
            }
            CallPayload::Circular(parse_circular(p, d[1] == CALL_SETUP_REQUEST))
        }
        CALL_GROUP_IDLE | CALL_SETUP_REJECT | CALL_RELEASE => {
            CallPayload::Cause(*p.first().ok_or_else(short)?)
        }
        CALL_SETUP_ACCEPT | CALL_ALERT => CallPayload::Empty,
        CALL_CONNECT_CONFIRM | CALL_SIMPLEX_GRANTED | CALL_SIMPLEX_IDLE => {
            // Be lenient on receive: a missing grant pair reads as 0/0.
            CallPayload::Grant { grant: *p.first().unwrap_or(&0), permission: *p.get(1).unwrap_or(&0) }
        }
        CALL_SHORT_TRANSFER => {
            if p.len() < 8 {
                return Err(short());
            }
            let number = p.get(8..40).map(ascii_field).unwrap_or_default();
            CallPayload::ShortTransfer { source: u32le(p, 0), destination: u32le(p, 4), number }
        }
        _ => CallPayload::Raw(p.to_vec()),
    };
    Ok(Message::CallControl { state: d[1], id, payload })
}

// ───────────────────────────── builders ─────────────────────────────

fn header(class: u8, kind: u8, id: &Uuid, cap: usize) -> Vec<u8> {
    let mut v = Vec::with_capacity(HEADER_LEN + cap);
    v.push(class);
    v.push(kind);
    v.extend_from_slice(id.as_bytes());
    v
}

/// `CLASS_SUBSCRIBER` message with the current wall-clock time.
pub fn build_subscriber(kind: u8, issi: u32, groups: &[u32]) -> Vec<u8> {
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default();
    let mut v = Vec::with_capacity(18 + groups.len() * 4);
    v.push(CLASS_SUBSCRIBER);
    v.push(kind);
    v.extend_from_slice(&issi.to_le_bytes());
    v.extend_from_slice(&now.as_secs().to_le_bytes());
    v.extend_from_slice(&now.subsec_nanos().to_le_bytes());
    for g in groups {
        v.extend_from_slice(&g.to_le_bytes());
    }
    v
}

pub fn build_cause(state: u8, id: &Uuid, cause: u8) -> Vec<u8> {
    let mut v = header(CLASS_CALL_CONTROL, state, id, 1);
    v.push(cause);
    v
}

pub fn build_empty(state: u8, id: &Uuid) -> Vec<u8> {
    header(CLASS_CALL_CONTROL, state, id, 0)
}

/// `CONNECT_CONFIRM`, `SIMPLEX_GRANTED`, `SIMPLEX_IDLE`: 2-byte grant pair.
pub fn build_grant(state: u8, id: &Uuid, grant: u8, permission: u8) -> Vec<u8> {
    let mut v = header(CLASS_CALL_CONTROL, state, id, 2);
    v.push(grant);
    v.push(permission);
    v
}

pub fn build_group_tx(id: &Uuid, g: &GroupTransmission) -> Vec<u8> {
    let mut v = header(CLASS_CALL_CONTROL, CALL_GROUP_TX, id, GROUP_TX_BASE_LEN + MNEMONIC_FIELD_LEN);
    v.extend_from_slice(&g.source.to_le_bytes());
    v.extend_from_slice(&g.destination.to_le_bytes());
    v.push(g.priority);
    v.push(g.access);
    v.extend_from_slice(&g.service.to_le_bytes());
    if let Some(name) = &g.mnemonic {
        v.extend_from_slice(&encode_mnemonic(name));
    }
    v
}

/// `SETUP_REQUEST` (with v1 mnemonic when `c.mnemonic` is set) or
/// `CONNECT_REQUEST` (always cut at the mnemonic offset).
pub fn build_circular(state: u8, id: &Uuid, c: &CircularCall) -> Vec<u8> {
    let mut v = header(CLASS_CALL_CONTROL, state, id, CIRCULAR_CALL_BASE_LEN + MNEMONIC_FIELD_LEN);
    v.extend_from_slice(&c.source.to_le_bytes());
    v.extend_from_slice(&c.destination.to_le_bytes());
    let mut num = [0u8; 32];
    let nb = c.number.as_bytes();
    num[..nb.len().min(31)].copy_from_slice(&nb[..nb.len().min(31)]);
    v.extend_from_slice(&num);
    v.extend_from_slice(&[
        c.priority, c.service, c.mode, c.duplex, c.method, c.communication, c.grant, c.permission, c.timeout,
        c.ownership, c.queued,
    ]);
    if state == CALL_SETUP_REQUEST
        && let Some(name) = &c.mnemonic {
            v.extend_from_slice(&encode_mnemonic(name));
        }
    v
}

/// SDS header: 58 bytes, as Basestation/FlowStation/brew-server send it.
pub fn build_short_transfer(id: &Uuid, source: u32, destination: u32) -> Vec<u8> {
    let mut v = header(CLASS_CALL_CONTROL, CALL_SHORT_TRANSFER, id, 40);
    v.extend_from_slice(&source.to_le_bytes());
    v.extend_from_slice(&destination.to_le_bytes());
    v.extend_from_slice(&[0u8; 32]);
    v
}

pub fn build_frame(kind: u8, id: &Uuid, length_bits: u16, data: &[u8]) -> Vec<u8> {
    let mut v = header(CLASS_FRAME, kind, id, 2 + data.len());
    v.extend_from_slice(&length_bits.to_le_bytes());
    v.extend_from_slice(data);
    v
}

pub fn build_service(kind: u8, json: &str) -> Vec<u8> {
    let mut v = vec![CLASS_SERVICE, kind];
    v.extend_from_slice(json.as_bytes());
    v.push(0);
    v
}

// ─────────────────────── STE voice payload ───────────────────────

fn get_bit(b: &[u8], i: usize) -> u8 {
    (b[i / 8] >> (7 - i % 8)) & 1
}
fn set_bit(b: &mut [u8], i: usize) {
    b[i / 8] |= 1 << (7 - i % 8);
}

/// Two codec-native 18-byte subframes → 36-byte STE payload (header 0x00,
/// 274 bits back-to-back MSB-first, 6 pad bits at the end).
pub fn pack_ste(sub1: &[u8; ACELP_CODED_FRAME_BYTES], sub2: &[u8; ACELP_CODED_FRAME_BYTES]) -> [u8; STE_VOICE_PAYLOAD_BYTES] {
    let mut out = [0u8; STE_VOICE_PAYLOAD_BYTES];
    let body = &mut out[1..];
    for i in 0..ACELP_CODED_FRAME_BITS {
        if get_bit(sub1, i) != 0 {
            set_bit(body, i);
        }
        if get_bit(sub2, i) != 0 {
            set_bit(body, ACELP_CODED_FRAME_BITS + i);
        }
    }
    out
}

/// Inverse of [`pack_ste`]. Returns `None` for a payload shorter than 36 bytes.
pub fn unpack_ste(payload: &[u8]) -> Option<([u8; ACELP_CODED_FRAME_BYTES], [u8; ACELP_CODED_FRAME_BYTES])> {
    if payload.len() < STE_VOICE_PAYLOAD_BYTES {
        return None;
    }
    let body = &payload[1..STE_VOICE_PAYLOAD_BYTES];
    let (mut a, mut b) = ([0u8; ACELP_CODED_FRAME_BYTES], [0u8; ACELP_CODED_FRAME_BYTES]);
    for i in 0..ACELP_CODED_FRAME_BITS {
        if get_bit(body, i) != 0 {
            set_bit(&mut a, i);
        }
        if get_bit(body, ACELP_CODED_FRAME_BITS + i) != 0 {
            set_bit(&mut b, i);
        }
    }
    Some((a, b))
}

pub fn build_traffic_frame(id: &Uuid, sub1: &[u8; ACELP_CODED_FRAME_BYTES], sub2: &[u8; ACELP_CODED_FRAME_BYTES]) -> Vec<u8> {
    build_frame(FRAME_TRAFFIC_CHANNEL, id, (STE_VOICE_PAYLOAD_BYTES * 8) as u16, &pack_ste(sub1, sub2))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn group_tx_round_trip_with_mnemonic() {
        let id = Uuid::new_v4();
        let g = GroupTransmission { source: 2040001, destination: 91, priority: 15, access: 0, service: 0, mnemonic: Some("SV1ABC".into()) };
        let w = build_group_tx(&id, &g);
        assert_eq!(w.len(), 18 + GROUP_TX_BASE_LEN + MNEMONIC_FIELD_LEN);
        assert_eq!(parse(&w).unwrap(), Message::CallControl { state: CALL_GROUP_TX, id, payload: CallPayload::Group(g) });
    }

    #[test]
    fn setup_request_layout_matches_server() {
        let id = Uuid::new_v4();
        let c = CircularCall { source: 1001, destination: 4013, priority: 3, duplex: 1, method: 1, mnemonic: Some("ME".into()), ..Default::default() };
        let w = build_circular(CALL_SETUP_REQUEST, &id, &c);
        assert_eq!(w.len(), 18 + CIRCULAR_CALL_BASE_LEN + MNEMONIC_FIELD_LEN);
        let t = 18 + 4 + 4 + 32;
        assert_eq!(&w[t..t + 5], &[3, 0, 0, 1, 1]); // priority service mode duplex method
        let Message::CallControl { payload: CallPayload::Circular(p), .. } = parse(&w).unwrap() else { panic!() };
        assert_eq!(p, c);
        // CONNECT_REQUEST never carries the mnemonic.
        assert_eq!(build_circular(CALL_CONNECT_REQUEST, &id, &c).len(), 18 + CIRCULAR_CALL_BASE_LEN);
    }

    #[test]
    fn fixed_sizes_match_server() {
        let id = Uuid::new_v4();
        assert_eq!(build_short_transfer(&id, 1, 2).len(), 58);
        assert_eq!(build_grant(CALL_CONNECT_CONFIRM, &id, 0, 0).len(), 20);
        assert_eq!(build_cause(CALL_RELEASE, &id, 1).len(), 19);
        assert_eq!(build_subscriber(SUB_AFFILIATE, 7, &[91, 92]).len(), 26);
    }

    #[test]
    fn subscriber_round_trip() {
        let w = build_subscriber(SUB_AFFILIATE, 2040001, &[91, 9999]);
        let Message::Subscriber { kind, issi, groups, .. } = parse(&w).unwrap() else { panic!() };
        assert_eq!((kind, issi, groups), (SUB_AFFILIATE, 2040001, vec![91, 9999]));
    }

    #[test]
    fn ste_round_trip_and_padding() {
        let mut a = [0u8; 18];
        let mut b = [0u8; 18];
        for i in 0..17 {
            a[i] = (i as u8).wrapping_mul(37) ^ 0x5a;
            b[i] = (i as u8).wrapping_mul(91) ^ 0xa5;
        }
        a[17] &= 0x80; // only bit 136 is real in the last byte
        b[17] &= 0x80;
        let p = pack_ste(&a, &b);
        assert_eq!(p[0], 0x00);
        assert_eq!(p[35] & 0x3f, 0, "6 trailing pad bits are zero");
        assert_eq!(unpack_ste(&p).unwrap(), (a, b));
    }

    #[test]
    fn mnemonic_round_trip() {
        assert_eq!(decode_mnemonic(&encode_mnemonic("Dispatch 1")).as_deref(), Some("Dispatch 1"));
    }
}
