//! End-to-end: the real client against a mock Brew server that mimics
//! brew-server's discovery (Digest 401 → 200 session path → WS upgrade with
//! sub-protocol "brew") and then plays scripted traffic.

use futures_util::{SinkExt, StreamExt};
use md5::{Digest, Md5};
use std::time::Duration;
use tetra_core::calls::CallEvent;
use tetra_core::client::{self, ClientConfig, ClientEvent, Command, MessageStatus};
use tetra_core::codec::VoiceEncoder;
use tetra_core::protocol::{self as p, CallPayload, CircularCall, GroupTransmission, Message};
use tetra_core::sds::{self, IncomingSds, LipReason, Location};
use tetra_core::transport::Endpoint;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;
use tokio::sync::mpsc::UnboundedReceiver;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::Message as WsMsg;
use uuid::Uuid;

const ME: u32 = 2040001;
const PEER: u32 = 2040002;
const TG: u32 = 91;

fn md5_hex(s: &str) -> String {
    hex::encode(Md5::digest(s.as_bytes()))
}

fn field<'a>(h: &'a str, k: &str) -> &'a str {
    let i = h.find(&format!("{k}=")).unwrap() + k.len() + 1;
    let r = &h[i..];
    if let Some(q) = r.strip_prefix('"') { &q[..q.find('"').unwrap()] } else { r.split(',').next().unwrap().trim() }
}

async fn read_request(s: &mut tokio::net::TcpStream) -> String {
    let mut buf = vec![0u8; 4096];
    let mut got = Vec::new();
    loop {
        let n = s.read(&mut buf).await.unwrap();
        got.extend_from_slice(&buf[..n]);
        if n == 0 || got.windows(4).any(|w| w == b"\r\n\r\n") {
            break;
        }
    }
    String::from_utf8_lossy(&got).into_owned()
}

/// Runs discovery on the first two connections and returns the WebSocket.
async fn accept_terminal(l: &TcpListener) -> tokio_tungstenite::WebSocketStream<tokio::net::TcpStream> {
    // 1) unauthenticated discovery → challenge
    let (mut s, _) = l.accept().await.unwrap();
    let req = read_request(&mut s).await;
    assert!(req.contains("X-Brew-Mode: Terminal"), "{req}");
    assert!(req.contains("User-Agent: "), "User-Agent is mandatory");
    s.write_all(b"HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Digest realm=\"brew-server\", nonce=\"n0nce\", qop=\"auth\", opaque=\"op\"\r\nContent-Length: 0\r\n\r\n").await.unwrap();
    drop(s);
    // 2) authenticated discovery → verify exactly like brew-server → session path
    let (mut s, _) = l.accept().await.unwrap();
    let req = read_request(&mut s).await;
    let auth = req.lines().find(|l| l.starts_with("Authorization:")).expect("Authorization header");
    let ha1 = md5_hex(&format!("{ME}:brew-server:pw"));
    let ha2 = md5_hex("GET:/brew");
    let want = md5_hex(&format!("{ha1}:n0nce:{}:{}:auth:{ha2}", field(auth, "nc"), field(auth, "cnonce")));
    assert_eq!(field(auth, "response"), want, "digest response must verify");
    s.write_all(b"HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Brew-Version: 1\r\nContent-Length: 19\r\n\r\n/brew/session/tok42").await.unwrap();
    drop(s);
    // 3) WebSocket upgrade on the session path
    let (s, _) = l.accept().await.unwrap();
    tokio_tungstenite::accept_hdr_async(s, |r: &Request, mut resp: Response| {
        assert_eq!(r.uri().path(), "/brew/session/tok42");
        assert_eq!(r.headers()["Sec-WebSocket-Protocol"], "brew");
        resp.headers_mut().insert("Sec-WebSocket-Protocol", "brew".parse().unwrap());
        Ok(resp)
    })
    .await
    .unwrap()
}

async fn recv_msg(ws: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>) -> Message {
    loop {
        match tokio::time::timeout(Duration::from_secs(5), ws.next()).await.expect("server recv timeout") {
            Some(Ok(WsMsg::Binary(b))) => return p::parse(&b).unwrap(),
            Some(Ok(_)) => continue,
            other => panic!("ws closed: {other:?}"),
        }
    }
}

async fn send(ws: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>, w: Vec<u8>) {
    ws.send(WsMsg::Binary(w.into())).await.unwrap();
}

async fn wait_for<F: Fn(&ClientEvent) -> bool>(ev: &mut UnboundedReceiver<ClientEvent>, f: F) -> ClientEvent {
    loop {
        let e = tokio::time::timeout(Duration::from_secs(5), ev.recv()).await.expect("event timeout").expect("events closed");
        if f(&e) {
            return e;
        }
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn full_terminal_session() {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let cfg = ClientConfig {
        endpoint: Endpoint {
            url: format!("http://127.0.0.1:{port}/brew"),
            username: ME.to_string(),
            password: "pw".into(),
            user_agent: "TetraBrewTerminal/test".into(),
            insecure_tls: false,
        },
        issi: ME,
        name: Some("SV1TEST".into()),
        groups: vec![TG, 92],
        selected_group: Some(TG),
        default_priority: 1,
        allow_preemption: true,
    };
    let (h, mut ev) = client::spawn(cfg);
    let mut ws = accept_terminal(&l).await;
    wait_for(&mut ev, |e| *e == ClientEvent::Connected).await;

    // Registration then affiliation.
    assert!(matches!(recv_msg(&mut ws).await, Message::Subscriber { kind: p::SUB_REGISTER, issi: ME, .. }));
    let Message::Subscriber { kind: p::SUB_AFFILIATE, groups, .. } = recv_msg(&mut ws).await else { panic!() };
    assert_eq!(groups, vec![TG, 92]);

    // ── Incoming group call with real ACELP audio ──
    let gid = Uuid::new_v4();
    let gt = GroupTransmission { source: PEER, destination: TG, priority: 1, access: 0, service: 0, mnemonic: Some("ALPHA".into()) };
    send(&mut ws, p::build_group_tx(&gid, &gt)).await;
    let e = wait_for(&mut ev, |e| matches!(e, ClientEvent::Call(CallEvent::GroupTxStarted { .. }))).await;
    assert!(matches!(e, ClientEvent::Call(CallEvent::GroupTxStarted { talker_name: Some(ref n), .. }) if n == "ALPHA"));
    let mut enc = VoiceEncoder::new();
    let tone: Vec<i16> = (0..480 * 3).map(|i| ((i as f32 * 0.2).sin() * 8000.0) as i16).collect();
    for f in enc.push_frames(&gid, &tone) {
        send(&mut ws, f).await;
    }
    for _ in 0..3 {
        let ClientEvent::Audio { call, pcm } = wait_for(&mut ev, |e| matches!(e, ClientEvent::Audio { .. })).await else { unreachable!() };
        assert_eq!((call, pcm.len()), (gid, 480));
    }
    send(&mut ws, p::build_cause(p::CALL_GROUP_IDLE, &gid, 0)).await;
    wait_for(&mut ev, |e| matches!(e, ClientEvent::Call(CallEvent::GroupTxEnded { .. }))).await;

    // ── Our PTT: GROUP_TX, voice frames, GROUP_IDLE ──
    h.send(Command::Ptt { pressed: true, group: None, emergency: false });
    let Message::CallControl { state: p::CALL_GROUP_TX, id: my, payload: CallPayload::Group(g) } = recv_msg(&mut ws).await else { panic!() };
    assert_eq!((g.source, g.destination, g.mnemonic.as_deref()), (ME, TG, Some("SV1TEST")));
    h.send(Command::MicPcm(vec![1000; 480 * 2]));
    for _ in 0..2 {
        let Message::Frame { kind, id, data, .. } = recv_msg(&mut ws).await else { panic!() };
        assert_eq!((kind, id, data.len()), (p::FRAME_TRAFFIC_CHANNEL, my, 36));
    }
    h.send(Command::Ptt { pressed: false, group: None, emergency: false });
    // The end of speech is followed by silent tail frames, then GROUP_IDLE.
    let mut tail = 0;
    loop {
        match recv_msg(&mut ws).await {
            Message::Frame { kind: p::FRAME_TRAFFIC_CHANNEL, id, .. } => {
                assert_eq!(id, my);
                tail += 1;
            }
            Message::CallControl { state: p::CALL_GROUP_IDLE, .. } => break,
            other => panic!("unexpected {other:?}"),
        }
    }
    assert!(tail >= 1, "silent tail frames precede GROUP_IDLE");

    // ── Incoming full-duplex private call, answered ──
    let pid = Uuid::new_v4();
    let setup = CircularCall { source: PEER, destination: ME, priority: 2, duplex: 1, method: 1, ..Default::default() };
    send(&mut ws, p::build_circular(p::CALL_SETUP_REQUEST, &pid, &setup)).await;
    assert!(matches!(recv_msg(&mut ws).await, Message::CallControl { state: p::CALL_SETUP_ACCEPT, .. }));
    assert!(matches!(recv_msg(&mut ws).await, Message::CallControl { state: p::CALL_ALERT, .. }));
    h.send(Command::Answer);
    assert!(matches!(recv_msg(&mut ws).await, Message::CallControl { state: p::CALL_CONNECT_REQUEST, .. }));
    send(&mut ws, p::build_grant(p::CALL_CONNECT_CONFIRM, &pid, 0, 0)).await;
    wait_for(&mut ev, |e| matches!(e, ClientEvent::Call(CallEvent::PrivateUpdated(c)) if c.state == tetra_core::calls::PrivateState::Connected)).await;
    h.send(Command::MicPcm(vec![0; 480])); // duplex: mic live without PTT
    assert!(matches!(recv_msg(&mut ws).await, Message::Frame { kind: p::FRAME_TRAFFIC_CHANNEL, id, .. } if id == pid));
    send(&mut ws, p::build_cause(p::CALL_RELEASE, &pid, 1)).await;
    wait_for(&mut ev, |e| matches!(e, ClientEvent::Call(CallEvent::PrivateEnded { .. }))).await;

    // ── Outgoing text SDS with SDS-TL report ──
    h.send(Command::SendText { local_id: 7, to: PEER, text: "Καλημέρα".into(), immediate: false, request_report: true });
    let Message::CallControl { state: p::CALL_SHORT_TRANSFER, id: sid, payload: CallPayload::ShortTransfer { source, destination, .. } } = recv_msg(&mut ws).await else { panic!() };
    assert_eq!((source, destination), (ME, PEER));
    let Message::Frame { kind: p::FRAME_SDS_TRANSFER, id, data, length_bits } = recv_msg(&mut ws).await else { panic!() };
    assert_eq!((id, length_bits as usize), (sid, data.len() * 8));
    let Some(IncomingSds::Text { text, message_reference: Some(mr), .. }) = sds::parse_incoming(&data) else { panic!() };
    assert_eq!(text, "Καλημέρα");
    send(&mut ws, p::build_frame(p::FRAME_SDS_REPORT, &sid, 8, &[0])).await;
    wait_for(&mut ev, |e| *e == ClientEvent::MessageStatus { local_id: 7, status: MessageStatus::NetworkAccepted }).await;
    let rid = Uuid::new_v4();
    let (r, bits) = sds::build_report(sds::PID_TEXT_TL, 0, mr);
    send(&mut ws, p::build_short_transfer(&rid, PEER, ME)).await;
    send(&mut ws, p::build_frame(p::FRAME_SDS_TRANSFER, &rid, bits, &r)).await;
    wait_for(&mut ev, |e| *e == ClientEvent::MessageStatus { local_id: 7, status: MessageStatus::Delivered { status: 0 } }).await;
    assert!(matches!(recv_msg(&mut ws).await, Message::Frame { kind: p::FRAME_SDS_REPORT, .. }));

    // ── Incoming text asking for a report: we answer with an SDS-TL report ──
    let tid = Uuid::new_v4();
    let (t, bits) = sds::build_text("Hello", 33, true, false);
    send(&mut ws, p::build_short_transfer(&tid, PEER, ME)).await;
    send(&mut ws, p::build_frame(p::FRAME_SDS_TRANSFER, &tid, bits, &t)).await;
    wait_for(&mut ev, |e| matches!(e, ClientEvent::TextReceived { from: PEER, text, .. } if text == "Hello")).await;
    assert!(matches!(recv_msg(&mut ws).await, Message::Frame { kind: p::FRAME_SDS_REPORT, id, .. } if id == tid));
    assert!(matches!(recv_msg(&mut ws).await, Message::CallControl { state: p::CALL_SHORT_TRANSFER, payload: CallPayload::ShortTransfer { destination: PEER, .. }, .. }));
    let Message::Frame { data, .. } = recv_msg(&mut ws).await else { panic!() };
    assert_eq!(sds::parse_incoming(&data), Some(IncomingSds::Report { pid: 0x82, delivery_status: 0, message_reference: 33 }));

    // ── LIP position report ──
    let loc = Location { latitude: 37.9439, longitude: 23.5015, accuracy_m: Some(5.0), speed_kmh: Some(0.0), heading_deg: None };
    h.send(Command::SendLocation { to: 9999, location: loc, reason: LipReason::MaxIntervalExceeded });
    assert!(matches!(recv_msg(&mut ws).await, Message::CallControl { state: p::CALL_SHORT_TRANSFER, .. }));
    let Message::Frame { data, length_bits, .. } = recv_msg(&mut ws).await else { panic!() };
    assert_eq!(length_bits, 84);
    let r = sds::parse_lip(&data).unwrap();
    assert!((r.location.latitude - 37.9439).abs() < 1e-4);

    // ── Clean shutdown deregisters ──
    h.send(Command::Shutdown);
    assert!(matches!(recv_msg(&mut ws).await, Message::Subscriber { kind: p::SUB_DEREGISTER, .. }));
}
