//! Live test against a running brew-server: two terminals exercise group
//! calls, priority pre-emption, private duplex/simplex calls, text SDS with
//! delivery reports and LIP.
//!
//!   cargo run --example live_two_terminals -- http://127.0.0.1:9100/brew/ 2040001:pw1 2040002:pw2 91

use std::time::Duration;
use tetra_core::calls::{CallEvent, PrivateState};
use tetra_core::client::{self, ClientConfig, ClientEvent, ClientHandle, Command, MessageStatus};
use tetra_core::sds::{LipReason, Location};
use tetra_core::transport::Endpoint;
use tokio::sync::mpsc::UnboundedReceiver;

type Ev = UnboundedReceiver<ClientEvent>;

async fn wait(ev: &mut Ev, what: &str, f: impl Fn(&ClientEvent) -> bool) -> Result<ClientEvent, String> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(8);
    loop {
        match tokio::time::timeout_at(deadline, ev.recv()).await {
            Ok(Some(e)) if f(&e) => return Ok(e),
            Ok(Some(_)) => continue,
            Ok(None) => return Err(format!("{what}: event channel closed")),
            Err(_) => return Err(format!("timed out waiting for {what}")),
        }
    }
}

fn drain(ev: &mut Ev) -> Vec<ClientEvent> {
    let mut v = Vec::new();
    while let Ok(e) = ev.try_recv() {
        v.push(e);
    }
    v
}

fn terminal(url: &str, cred: &str, gssi: u32, name: &str) -> (u32, ClientHandle, Ev) {
    let (user, pass) = cred.split_once(':').expect("issi:password");
    let issi: u32 = user.parse().unwrap();
    let (h, ev) = client::spawn(ClientConfig {
        endpoint: Endpoint { url: url.into(), username: user.into(), password: pass.into(), user_agent: format!("TetraBrewTerminal/live-{issi}"), insecure_tls: true },
        issi,
        name: Some(name.into()),
        groups: vec![gssi],
        selected_group: Some(gssi),
        default_priority: 1,
        allow_preemption: true,
    });
    (issi, h, ev)
}

/// Streams `secs` of a tone as microphone audio in 60 ms chunks (real time).
async fn talk(h: &ClientHandle, secs: f32) {
    let frames = (secs / 0.06) as usize;
    for n in 0..frames {
        let pcm: Vec<i16> = (0..480).map(|i| (((n * 480 + i) as f32 * 0.12).sin() * 7000.0) as i16).collect();
        h.send(Command::MicPcm(pcm));
        tokio::time::sleep(Duration::from_millis(60)).await;
    }
}

fn audio_frames(evs: &[ClientEvent]) -> usize {
    evs.iter().filter(|e| matches!(e, ClientEvent::Audio { .. })).count()
}

async fn run(url: &str, ca: &str, cb: &str, tg: u32) -> Vec<(String, Result<String, String>)> {
    let (a_issi, a, mut ea) = terminal(url, ca, tg, "ALPHA");
    let (b_issi, b, mut eb) = terminal(url, cb, tg, "BRAVO");
    let mut results = Vec::new();
    macro_rules! step {
        ($name:expr, $body:expr) => {{
            let r: Result<String, String> = async { $body }.await;
            println!("{} {}: {}", if r.is_ok() { "PASS" } else { "FAIL" }, $name, r.as_ref().unwrap_or_else(|e| e));
            results.push(($name.to_string(), r));
            tokio::time::sleep(Duration::from_millis(300)).await;
            drain(&mut ea);
            drain(&mut eb);
        }};
    }

    step!("connect + register + affiliate", {
        wait(&mut ea, "A connected", |e| *e == ClientEvent::Connected).await?;
        wait(&mut eb, "B connected", |e| *e == ClientEvent::Connected).await?;
        tokio::time::sleep(Duration::from_millis(500)).await;
        Ok(format!("{a_issi} and {b_issi} online on TG {tg}"))
    });

    step!("group call (half duplex PTT) A -> TG", {
        a.send(Command::Ptt { pressed: true, group: None, emergency: false });
        wait(&mut ea, "A TxGranted", |e| matches!(e, ClientEvent::Call(CallEvent::TxGranted { .. }))).await?;
        talk(&a, 1.2).await;
        let started = wait(&mut eb, "B hears group tx", |e| matches!(e, ClientEvent::Call(CallEvent::GroupTxStarted { .. }))).await?;
        tokio::time::sleep(Duration::from_millis(300)).await;
        let heard = audio_frames(&drain(&mut eb));
        a.send(Command::Ptt { pressed: false, group: None, emergency: false });
        wait(&mut eb, "B group tx ended", |e| matches!(e, ClientEvent::Call(CallEvent::GroupTxEnded { .. }))).await?;
        let ClientEvent::Call(CallEvent::GroupTxStarted { talker, talker_name, .. }) = started else { unreachable!() };
        if talker != a_issi {
            return Err(format!("talker {talker} != {a_issi}"));
        }
        if heard < 10 {
            return Err(format!("B decoded only {heard} audio frames"));
        }
        Ok(format!("B heard {talker} ({talker_name:?}), decoded {heard} ACELP frames"))
    });

    step!("emergency pre-empts normal talker", {
        b.send(Command::Ptt { pressed: true, group: None, emergency: false });
        wait(&mut eb, "B TxGranted", |e| matches!(e, ClientEvent::Call(CallEvent::TxGranted { .. }))).await?;
        talk(&b, 0.4).await;
        a.send(Command::Ptt { pressed: true, group: None, emergency: true });
        wait(&mut ea, "A TxGranted (emergency)", |e| matches!(e, ClientEvent::Call(CallEvent::TxGranted { .. }))).await?;
        talk(&a, 0.4).await;
        let ended = wait(&mut eb, "B pre-empted", |e| matches!(e, ClientEvent::Call(CallEvent::TxEnded { preempted: true, .. }))).await;
        let em = wait(&mut eb, "B hears emergency", |e| matches!(e, ClientEvent::Call(CallEvent::GroupTxStarted { priority: 15, .. }))).await;
        a.send(Command::Ptt { pressed: false, group: None, emergency: false });
        b.send(Command::Ptt { pressed: false, group: None, emergency: false });
        ended?;
        em?;
        Ok("B's floor taken by server, B now hears A at priority 15".into())
    });

    step!("private call, full duplex, hook (answer)", {
        a.send(Command::Dial { issi: b_issi, duplex: true, hook: true, priority: None });
        wait(&mut eb, "B ringing", |e| matches!(e, ClientEvent::Call(CallEvent::PrivateUpdated(c)) if c.state == PrivateState::Ringing)).await?;
        wait(&mut ea, "A alerting", |e| matches!(e, ClientEvent::Call(CallEvent::PrivateUpdated(c)) if c.state == PrivateState::Alerting)).await?;
        b.send(Command::Answer);
        wait(&mut ea, "A connected", |e| matches!(e, ClientEvent::Call(CallEvent::PrivateUpdated(c)) if c.state == PrivateState::Connected)).await?;
        wait(&mut eb, "B connected", |e| matches!(e, ClientEvent::Call(CallEvent::PrivateUpdated(c)) if c.state == PrivateState::Connected)).await?;
        drain(&mut ea);
        drain(&mut eb);
        tokio::join!(talk(&a, 1.0), talk(&b, 1.0));
        tokio::time::sleep(Duration::from_millis(300)).await;
        let (fa, fb) = (audio_frames(&drain(&mut ea)), audio_frames(&drain(&mut eb)));
        a.send(Command::Hangup);
        wait(&mut eb, "B call ended", |e| matches!(e, ClientEvent::Call(CallEvent::PrivateEnded { .. }))).await?;
        if fa < 8 || fb < 8 {
            return Err(format!("duplex audio too low: A heard {fa}, B heard {fb}"));
        }
        Ok(format!("both talked at once: A heard {fa} frames, B heard {fb}"))
    });

    step!("private call, simplex, direct (no answer)", {
        b.send(Command::Dial { issi: a_issi, duplex: false, hook: false, priority: None });
        wait(&mut eb, "B connected", |e| matches!(e, ClientEvent::Call(CallEvent::PrivateUpdated(c)) if c.state == PrivateState::Connected)).await?;
        wait(&mut ea, "A connected", |e| matches!(e, ClientEvent::Call(CallEvent::PrivateUpdated(c)) if c.state == PrivateState::Connected)).await?;
        b.send(Command::Ptt { pressed: true, group: None, emergency: false });
        wait(&mut eb, "B floor", |e| matches!(e, ClientEvent::Call(CallEvent::TxGranted { .. }))).await?;
        talk(&b, 0.8).await;
        tokio::time::sleep(Duration::from_millis(300)).await;
        let heard = audio_frames(&drain(&mut ea));
        b.send(Command::Ptt { pressed: false, group: None, emergency: false });
        b.send(Command::Hangup);
        wait(&mut ea, "A call ended", |e| matches!(e, ClientEvent::Call(CallEvent::PrivateEnded { .. }))).await?;
        if heard < 6 {
            return Err(format!("A heard only {heard} frames"));
        }
        Ok(format!("A heard {heard} frames on B's PTT"))
    });

    step!("private text SDS with SDS-TL delivery report", {
        a.send(Command::SendText { local_id: 1, to: b_issi, text: "Καλημέρα from ALPHA".into(), immediate: false, request_report: true });
        let got = wait(&mut eb, "B text", |e| matches!(e, ClientEvent::TextReceived { .. })).await?;
        wait(&mut ea, "A delivered", |e| matches!(e, ClientEvent::MessageStatus { local_id: 1, status: MessageStatus::Delivered { .. } })).await?;
        Ok(format!("{got:?}"))
    });

    step!("group text SDS", {
        b.send(Command::SendText { local_id: 2, to: tg, text: "TG check".into(), immediate: false, request_report: false });
        let got = wait(&mut ea, "A group text", |e| matches!(e, ClientEvent::TextReceived { .. })).await?;
        Ok(format!("{got:?}"))
    });

    step!("LIP short location report", {
        let loc = Location { latitude: 37.9439, longitude: 23.5015, accuracy_m: Some(6.0), speed_kmh: Some(32.0), heading_deg: Some(270.0) };
        a.send(Command::SendLocation { to: b_issi, location: loc, reason: LipReason::MaxIntervalExceeded });
        let got = wait(&mut eb, "B location", |e| matches!(e, ClientEvent::LocationReceived { .. })).await?;
        Ok(format!("{got:?}"))
    });

    a.send(Command::Shutdown);
    b.send(Command::Shutdown);
    tokio::time::sleep(Duration::from_millis(300)).await;
    results
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    let url = args.get(1).map(String::as_str).unwrap_or("http://127.0.0.1:9100/brew/");
    let a = args.get(2).map(String::as_str).unwrap_or("2040001:pw1");
    let b = args.get(3).map(String::as_str).unwrap_or("2040002:pw2");
    let tg: u32 = args.get(4).and_then(|s| s.parse().ok()).unwrap_or(91);
    let results = run(url, a, b, tg).await;
    let failed = results.iter().filter(|(_, r)| r.is_err()).count();
    println!("\n{} passed, {} failed", results.len() - failed, failed);
    std::process::exit(if failed == 0 { 0 } else { 1 });
}
