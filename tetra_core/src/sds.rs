//! SDS type 4 user data: text messaging (ETSI EN 300 392-2 clause 29, SDS-TL)
//! and LIP location reports (ETSI TS 100 392-18-1).
//!
//! Everything here is the payload of a Brew `FRAME_SDS_TRANSFER`; the first
//! octet is always the protocol identifier (PID).

pub const PID_SIMPLE_TEXT: u8 = 0x02;
pub const PID_SIMPLE_IMMEDIATE_TEXT: u8 = 0x09;
pub const PID_LIP: u8 = 0x0A;
pub const PID_TEXT_TL: u8 = 0x82;
pub const PID_IMMEDIATE_TEXT_TL: u8 = 0x89;

/// SDS-TL message types (upper nibble of octet 1).
const TL_TRANSFER: u8 = 0;
const TL_REPORT: u8 = 1;
const TL_ACK: u8 = 2;

/// SDS-TL delivery status values (29.4.3.2, subset).
pub mod status {
    pub const RECEIVED: u8 = 0x00;
    pub const CONSUMED: u8 = 0x02;
    pub const DESTINATION_NOT_REACHABLE: u8 = 0x6A; // "destination not reachable, message delivery failed"
}

/// Text coding schemes (29.5.4.1, table 29.29, subset).
pub mod coding {
    pub const SEVEN_BIT: u8 = 0x00;
    pub const LATIN_1: u8 = 0x01;
    pub const LATIN_GREEK: u8 = 0x07; // ISO/IEC 8859-7
    pub const UCS2: u8 = 0x1A;
}

// ───────────────────────────── bit helpers ─────────────────────────────

#[derive(Default)]
struct BitWriter {
    buf: Vec<u8>,
    bits: usize,
}
impl BitWriter {
    fn put(&mut self, value: u64, n: usize) {
        for k in (0..n).rev() {
            if self.bits.is_multiple_of(8) {
                self.buf.push(0);
            }
            if (value >> k) & 1 == 1 {
                let i = self.bits;
                self.buf[i / 8] |= 1 << (7 - i % 8);
            }
            self.bits += 1;
        }
    }
}

struct BitReader<'a> {
    d: &'a [u8],
    pos: usize,
}
impl BitReader<'_> {
    fn take(&mut self, n: usize) -> Option<u64> {
        if self.pos + n > self.d.len() * 8 {
            return None;
        }
        let mut v = 0u64;
        for _ in 0..n {
            v = (v << 1) | ((self.d[self.pos / 8] >> (7 - self.pos % 8)) & 1) as u64;
            self.pos += 1;
        }
        Some(v)
    }
}

fn sign_extend(v: u64, n: u32) -> i64 {
    let s = 64 - n;
    ((v << s) as i64) >> s
}

// ───────────────────────────── text ─────────────────────────────

fn greek_byte(c: char) -> Option<u8> {
    let u = c as u32;
    match u {
        0..=0xA0 => Some(u as u8),
        0x2018 => Some(0xA1),
        0x2019 => Some(0xA2),
        0x20AC => Some(0xA4),
        0x20AF => Some(0xA5),
        0x037A => Some(0xAA),
        0x2015 => Some(0xAF),
        0xA3 | 0xA6..=0xA9 | 0xAB..=0xAD | 0xB0..=0xB3 | 0xB7 | 0xBB | 0xBD => Some(u as u8),
        0x0384..=0x03CE if u != 0x03A2 && u != 0x0387 && u != 0x038B && u != 0x038D => Some((u - 0x2D0) as u8),
        _ => None,
    }
}

fn greek_char(b: u8) -> char {
    match b {
        0xA1 => '\u{2018}',
        0xA2 => '\u{2019}',
        0xA4 => '\u{20AC}',
        0xA5 => '\u{20AF}',
        0xAA => '\u{037A}',
        0xAF => '\u{2015}',
        0xB4..=0xB6 | 0xB8..=0xBA | 0xBC | 0xBE..=0xFE => char::from_u32(b as u32 + 0x2D0).unwrap_or('?'),
        _ => b as char,
    }
}

/// Picks the most compact scheme that can carry `text`: Latin-1, then
/// ISO 8859-7 (Greek), then UCS-2.
pub fn encode_text(text: &str) -> (u8, Vec<u8>) {
    if text.chars().all(|c| (c as u32) < 256) {
        return (coding::LATIN_1, text.chars().map(|c| c as u8).collect());
    }
    if let Some(bytes) = text.chars().map(greek_byte).collect::<Option<Vec<u8>>>() {
        return (coding::LATIN_GREEK, bytes);
    }
    (coding::UCS2, text.encode_utf16().flat_map(|u| u.to_be_bytes()).collect())
}

pub fn decode_text(scheme: u8, data: &[u8]) -> String {
    let s: String = match scheme & 0x7f {
        coding::SEVEN_BIT => {
            // 7-bit packed, MSB-first septets (29.5.4.3).
            let mut r = BitReader { d: data, pos: 0 };
            std::iter::from_fn(|| r.take(7)).map(|v| v as u8 as char).collect()
        }
        coding::LATIN_GREEK => data.iter().map(|&b| greek_char(b)).collect(),
        coding::UCS2 => {
            let units: Vec<u16> = data.chunks_exact(2).map(|c| u16::from_be_bytes([c[0], c[1]])).collect();
            String::from_utf16_lossy(&units)
        }
        _ => data.iter().map(|&b| b as char).collect(), // Latin-1 and other 8-bit
    };
    s.trim_end_matches('\0').to_string()
}

/// Builds an SDS-TL SDS-TRANSFER text message (PID 0x82, or 0x89 for an
/// immediate/flash message). `report` requests a "received" delivery report.
/// Returns the payload and its length in bits.
pub fn build_text(text: &str, message_reference: u8, report: bool, immediate: bool) -> (Vec<u8>, u16) {
    let (scheme, body) = encode_text(text);
    let pid = if immediate { PID_IMMEDIATE_TEXT_TL } else { PID_TEXT_TL };
    // msg type(4)=0 | delivery report request(2) | short form report(1)=0 | storage(1)=0
    let flags = (TL_TRANSFER << 4) | if report { 0b01 << 2 } else { 0 };
    let mut v = vec![pid, flags, message_reference, scheme & 0x7f]; // bit 7 = timestamp used = 0
    v.extend_from_slice(&body);
    let bits = (v.len() * 8) as u16;
    (v, bits)
}

/// SDS-REPORT `[PID, 0x10, status, MR]` (32 bits), as the server builds it.
pub fn build_report(pid: u8, delivery_status: u8, message_reference: u8) -> (Vec<u8>, u16) {
    (vec![pid, TL_REPORT << 4, delivery_status, message_reference], 32)
}

// ───────────────────────────── LIP ─────────────────────────────

/// Reason for sending (TS 100 392-18-1, table 6.82, subset).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum LipReason {
    PowerOn = 0,
    PowerOff = 1,
    Emergency = 2,
    Ptt = 3,
    Status = 4,
    UserInitiated = 20,
    ImmediateRequestResponse = 32,
    MaxIntervalExceeded = 129,
    MaxDistanceTravelled = 130,
}

#[derive(Debug, Clone, PartialEq)]
pub struct Location {
    pub latitude: f64,
    pub longitude: f64,
    /// Horizontal accuracy in metres, if known.
    pub accuracy_m: Option<f64>,
    /// Speed in km/h, if known.
    pub speed_kmh: Option<f64>,
    /// Heading in degrees (0 = north), if known.
    pub heading_deg: Option<f64>,
}

#[derive(Debug, Clone, PartialEq)]
pub struct LipReport {
    pub location: Location,
    pub reason: Option<u8>,
}

fn position_error_code(acc: Option<f64>) -> u64 {
    match acc {
        None => 7,
        Some(a) if a < 2.0 => 0,
        Some(a) if a < 20.0 => 1,
        Some(a) if a < 200.0 => 2,
        Some(a) if a < 2_000.0 => 3,
        Some(a) if a < 20_000.0 => 4,
        Some(a) if a <= 200_000.0 => 5,
        Some(_) => 6,
    }
}

fn velocity_code(v: Option<f64>) -> u64 {
    match v {
        None => 127,
        Some(v) if v <= 28.0 => v.max(0.0).round() as u64,
        Some(v) => ((13.0 + (v / 16.0).ln() / 1.038f64.ln()).round() as u64).min(126),
    }
}

fn velocity_from_code(c: u64) -> Option<f64> {
    match c {
        127 => None,
        0..=28 => Some(c as f64),
        _ => Some(16.0 * 1.038f64.powi(c as i32 - 13)),
    }
}

/// LIP **short location report** (PID 0x0A). 76 bits of PDU after the PID.
pub fn build_lip_short(loc: &Location, reason: LipReason) -> (Vec<u8>, u16) {
    let mut w = BitWriter::default();
    w.put(PID_LIP as u64, 8);
    w.put(0, 2); // PDU type: short location report
    w.put(0, 2); // time elapsed: < 5 s
    let lon = (loc.longitude * (1u64 << 25) as f64 / 360.0).round() as i64;
    let lat = (loc.latitude * (1u64 << 24) as f64 / 180.0).round() as i64;
    w.put((lon as u64) & ((1 << 25) - 1), 25);
    w.put((lat as u64) & ((1 << 24) - 1), 24);
    w.put(position_error_code(loc.accuracy_m), 3);
    w.put(velocity_code(loc.speed_kmh), 7);
    let dir = loc.heading_deg.map(|h| ((h.rem_euclid(360.0) / 22.5).round() as u64) % 16).unwrap_or(0);
    w.put(dir, 4);
    w.put(0, 1); // type of additional data: reason for sending
    w.put(reason as u64, 8);
    let bits = w.bits as u16;
    (w.buf, bits)
}

pub fn parse_lip(data: &[u8]) -> Option<LipReport> {
    if data.first() != Some(&PID_LIP) {
        return None;
    }
    let mut r = BitReader { d: &data[1..], pos: 0 };
    if r.take(2)? != 0 {
        return None; // only short location reports are decoded
    }
    r.take(2)?;
    let lon = sign_extend(r.take(25)?, 25) as f64 * 360.0 / (1u64 << 25) as f64;
    let lat = sign_extend(r.take(24)?, 24) as f64 * 180.0 / (1u64 << 24) as f64;
    let err = r.take(3);
    let vel = r.take(7);
    let dir = r.take(4);
    let reason = match r.take(1) {
        Some(0) => r.take(8).map(|v| v as u8),
        _ => None,
    };
    let accuracy_m = match err {
        Some(c @ 0..=5) => Some([2.0, 20.0, 200.0, 2_000.0, 20_000.0, 200_000.0][c as usize]),
        _ => None,
    };
    let speed_kmh = vel.and_then(velocity_from_code);
    Some(LipReport {
        location: Location {
            latitude: lat,
            longitude: lon,
            accuracy_m,
            speed_kmh,
            heading_deg: if speed_kmh.unwrap_or(0.0) > 0.0 { dir.map(|d| d as f64 * 22.5) } else { None },
        },
        reason,
    })
}

// ───────────────────────────── incoming ─────────────────────────────

#[derive(Debug, Clone, PartialEq)]
pub enum IncomingSds {
    Text { pid: u8, text: String, immediate: bool, message_reference: Option<u8>, report_requested: bool },
    Report { pid: u8, delivery_status: u8, message_reference: u8 },
    Ack { pid: u8, message_reference: u8 },
    Location(LipReport),
    Other { pid: u8, data: Vec<u8> },
}

pub fn parse_incoming(data: &[u8]) -> Option<IncomingSds> {
    let pid = *data.first()?;
    Some(match pid {
        PID_SIMPLE_TEXT | PID_SIMPLE_IMMEDIATE_TEXT => IncomingSds::Text {
            pid,
            text: decode_text(*data.get(1)?, data.get(2..)?),
            immediate: pid == PID_SIMPLE_IMMEDIATE_TEXT,
            message_reference: None,
            report_requested: false,
        },
        PID_TEXT_TL | PID_IMMEDIATE_TEXT_TL => {
            let flags = *data.get(1)?;
            match flags >> 4 {
                TL_TRANSFER => {
                    let mr = *data.get(2)?;
                    // Storage/forward control present: skip validity, forward address type
                    // and address (29.4.2.4); this client only supports the common SSI form.
                    let mut i = 3;
                    if flags & 0x01 != 0 {
                        let fwd_type = data.get(i)? & 0x07;
                        i += 1 + if fwd_type == 1 { 3 } else { 0 };
                    }
                    let scheme = *data.get(i)?;
                    let body = if scheme & 0x80 != 0 { data.get(i + 4..)? } else { data.get(i + 1..)? };
                    IncomingSds::Text {
                        pid,
                        text: decode_text(scheme, body),
                        immediate: pid == PID_IMMEDIATE_TEXT_TL,
                        message_reference: Some(mr),
                        report_requested: (flags >> 2) & 0x03 != 0,
                    }
                }
                TL_REPORT => IncomingSds::Report { pid, delivery_status: *data.get(2)?, message_reference: *data.get(3)? },
                TL_ACK => IncomingSds::Ack { pid, message_reference: *data.get(3).or(data.get(2))? },
                _ => IncomingSds::Other { pid, data: data.to_vec() },
            }
        }
        PID_LIP => match parse_lip(data) {
            Some(r) => IncomingSds::Location(r),
            None => IncomingSds::Other { pid, data: data.to_vec() },
        },
        _ => IncomingSds::Other { pid, data: data.to_vec() },
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn text_matches_server_example() {
        // brew-server's sms_center test vector: [0x82, 0x04, 0x07, 0x01, "Hello"]
        let (v, bits) = build_text("Hello", 7, true, false);
        assert_eq!(v, [0x82, 0x04, 0x07, 0x01, b'H', b'e', b'l', b'l', b'o']);
        assert_eq!(bits, 72);
        assert_eq!(
            parse_incoming(&v),
            Some(IncomingSds::Text { pid: 0x82, text: "Hello".into(), immediate: false, message_reference: Some(7), report_requested: true })
        );
    }

    #[test]
    fn greek_and_unicode_text() {
        for s in ["Καλημέρα Αθήνα", "Ωραία μέρα!", "日本 ✓"] {
            let (v, _) = build_text(s, 1, false, false);
            let Some(IncomingSds::Text { text, .. }) = parse_incoming(&v) else { panic!() };
            assert_eq!(text, s);
        }
        assert_eq!(encode_text("Καλημέρα").0, coding::LATIN_GREEK);
        assert_eq!(encode_text("日本").0, coding::UCS2);
    }

    #[test]
    fn report_round_trip() {
        let (v, bits) = build_report(PID_TEXT_TL, status::RECEIVED, 42);
        assert_eq!((v.as_slice(), bits), (&[0x82, 0x10, 0x00, 42][..], 32));
        assert_eq!(parse_incoming(&v), Some(IncomingSds::Report { pid: 0x82, delivery_status: 0, message_reference: 42 }));
    }

    #[test]
    fn decodes_live_beacon_from_server_tests() {
        // Live beacon quoted in brew-server src/position.rs: 37.991956 N, 23.764189 E.
        let b = [0x0a, 0x01, 0x0e, 0x62, 0x39, 0xb0, 0x43, 0x9a, 0xff, 0xe0, 0x20];
        let r = parse_lip(&b).unwrap();
        assert!((r.location.latitude - 37.991956).abs() < 1e-5, "{}", r.location.latitude);
        assert!((r.location.longitude - 23.764189).abs() < 1e-5, "{}", r.location.longitude);
    }

    #[test]
    fn lip_round_trip() {
        let loc = Location { latitude: 37.9439, longitude: 23.5015, accuracy_m: Some(8.0), speed_kmh: Some(54.0), heading_deg: Some(91.0) };
        let (v, bits) = build_lip_short(&loc, LipReason::MaxIntervalExceeded);
        assert_eq!(bits, 8 + 76);
        assert_eq!(v.len(), 11);
        let r = parse_lip(&v).unwrap();
        assert!((r.location.latitude - loc.latitude).abs() < 2e-5);
        assert!((r.location.longitude - loc.longitude).abs() < 2e-5);
        assert_eq!(r.location.accuracy_m, Some(20.0));
        assert!((r.location.speed_kmh.unwrap() - 54.0).abs() < 2.5);
        assert_eq!(r.location.heading_deg, Some(90.0));
        assert_eq!(r.reason, Some(129));
        // Southern/western hemisphere sign handling.
        let (v, _) = build_lip_short(&Location { latitude: -33.86, longitude: -70.65, accuracy_m: None, speed_kmh: None, heading_deg: None }, LipReason::PowerOn);
        let r = parse_lip(&v).unwrap();
        assert!((r.location.latitude + 33.86).abs() < 2e-5 && (r.location.longitude + 70.65).abs() < 2e-5);
    }
}
