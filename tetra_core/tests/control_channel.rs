//! The Basestation control channel against a stand-in for brew-server's
//! control listener (`fsnet.rs`: Basic auth, sub-protocol echo, extensions).

use futures_util::{SinkExt, StreamExt};
use std::time::Duration;
use tetra_core::control::{self, ControlEndpoint, ControlEvent, DgnaGroup};
use tokio::net::TcpListener;
use tokio_tungstenite::tungstenite::handshake::server::{Request, Response};
use tokio_tungstenite::tungstenite::Message as WsMsg;

const ME: u32 = 2320997;

async fn next_json(ws: &mut tokio_tungstenite::WebSocketStream<tokio::net::TcpStream>) -> serde_json::Value {
    loop {
        match tokio::time::timeout(Duration::from_secs(5), ws.next()).await.expect("server recv timeout") {
            Some(Ok(WsMsg::Binary(b))) => return serde_json::from_slice(&b).unwrap(),
            Some(Ok(_)) => continue,
            other => panic!("closed: {other:?}"),
        }
    }
}

async fn next_event(ev: &mut tokio::sync::mpsc::UnboundedReceiver<ControlEvent>) -> ControlEvent {
    tokio::time::timeout(Duration::from_secs(5), ev.recv()).await.expect("event timeout").expect("events closed")
}

#[tokio::test(flavor = "multi_thread")]
async fn dgna_for_our_issi_is_applied_and_reported() {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ep = ControlEndpoint {
        url: control::control_url(&format!("127.0.0.1:{port}"), "", false).unwrap().to_string(),
        username: ME.to_string(),
        password: "pw".into(),
        user_agent: "TetraBrewTerminal/test".into(),
        insecure_tls: false,
    };
    let held = vec![DgnaGroup { gssi: 2328, mnemonic: Some("Old".into()), attachment_mode: 0 }];
    let (h, mut ev) = control::spawn(ep, ME, held);

    let (s, _) = l.accept().await.unwrap();
    let mut ws = tokio_tungstenite::accept_hdr_async(s, |r: &Request, mut resp: Response| {
        assert_eq!(r.uri().path(), "/");
        assert_eq!(r.headers()["Sec-WebSocket-Protocol"], control::SUBPROTOCOL);
        assert_eq!(r.headers()["Authorization"], control::basic_authorization(&ME.to_string(), "pw"));
        resp.headers_mut().insert("Sec-WebSocket-Protocol", control::SUBPROTOCOL.parse().unwrap());
        resp.headers_mut().insert("X-Brew-Extensions", "fleet-control, dgna-report".parse().unwrap());
        Ok(resp)
    })
    .await
    .unwrap();
    assert_eq!(next_event(&mut ev).await, ControlEvent::Connected);

    // What the app already holds, right after connecting.
    assert_eq!(next_json(&mut ws).await, serde_json::json!({"DgnaGroups":{"groups":[{"issi":ME,"gssi":2328,"mnemonic":"Old","attachment_mode":0}]}}));

    // Another radio's DGNA and a Fleet Control command are not ours.
    ws.send(WsMsg::Binary(br#"{"Dgna":{"issi":1,"gssi":9,"mnemonic":null,"attachment_mode":0,"attach":true}}"#.to_vec().into())).await.unwrap();
    ws.send(WsMsg::Binary(br#"{"FleetPing":{"handle":3}}"#.to_vec().into())).await.unwrap();

    // Assign: event for the app, DgnaChanged for the server.
    let assign = format!(r#"{{"Dgna":{{"issi":{ME},"gssi":2329,"mnemonic":"Event","attachment_mode":1,"attach":true}}}}"#);
    ws.send(WsMsg::Binary(assign.into_bytes().into())).await.unwrap();
    let group = DgnaGroup { gssi: 2329, mnemonic: Some("Event".into()), attachment_mode: 1 };
    assert_eq!(next_event(&mut ev).await, ControlEvent::Dgna { group: group.clone(), attach: true });
    assert_eq!(next_json(&mut ws).await, serde_json::json!({"DgnaChanged":{"issi":ME,"gssi":2329,"mnemonic":"Event","attachment_mode":1,"assigned":true}}));

    // Deassign of the old one.
    let deassign = format!(r#"{{"Dgna":{{"issi":{ME},"gssi":2328,"mnemonic":null,"attachment_mode":0,"attach":false}}}}"#);
    ws.send(WsMsg::Binary(deassign.into_bytes().into())).await.unwrap();
    assert!(matches!(next_event(&mut ev).await, ControlEvent::Dgna { attach: false, group } if group.gssi == 2328));
    assert_eq!(next_json(&mut ws).await, serde_json::json!({"DgnaChanged":{"issi":ME,"gssi":2328,"mnemonic":null,"attachment_mode":0,"assigned":false}}));

    h.shutdown();
    assert_eq!(next_event(&mut ev).await, ControlEvent::Disconnected { error: None });
}

#[tokio::test(flavor = "multi_thread")]
async fn without_dgna_report_nothing_is_reported() {
    let l = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = l.local_addr().unwrap().port();
    let ep = ControlEndpoint { url: format!("ws://127.0.0.1:{port}/"), username: String::new(), password: String::new(), user_agent: "t".into(), insecure_tls: false };
    let (h, mut ev) = control::spawn(ep, ME, vec![DgnaGroup { gssi: 5, mnemonic: None, attachment_mode: 0 }]);
    let (s, _) = l.accept().await.unwrap();
    let mut ws = tokio_tungstenite::accept_hdr_async(s, |r: &Request, mut resp: Response| {
        assert!(r.headers().get("Authorization").is_none(), "no login, no auth header");
        resp.headers_mut().insert("Sec-WebSocket-Protocol", control::SUBPROTOCOL.parse().unwrap());
        Ok(resp)
    })
    .await
    .unwrap();
    assert_eq!(next_event(&mut ev).await, ControlEvent::Connected);
    let assign = format!(r#"{{"Dgna":{{"issi":{ME},"gssi":6,"attach":true}}}}"#);
    ws.send(WsMsg::Binary(assign.into_bytes().into())).await.unwrap();
    assert!(matches!(next_event(&mut ev).await, ControlEvent::Dgna { attach: true, group } if group.gssi == 6));
    // Nothing but pings reaches the server.
    let got = tokio::time::timeout(Duration::from_millis(300), ws.next()).await;
    assert!(!matches!(got, Ok(Some(Ok(WsMsg::Binary(_))))), "{got:?}");
    h.shutdown();
}
