//! Basestation control channel, as FlowStation opens it next to its Brew login
//! (brew-server `control.rs`): a BTS-initiated WebSocket at `/` with
//! sub-protocol `bluestation-control-v1`, optional HTTP Basic auth, JSON
//! frames. Only used when a profile logs in as a Basestation.
//!
//! The app takes the commands that concern its own ISSI:
//! - `Dgna` (SS-DGNA assign / deassign): the group is added to or removed from
//!   the app's list. The app has no air interface, so it confirms at once and
//!   reports `DgnaChanged` when the server offered `dgna-report`. The
//!   attachment mode is kept and reported back unchanged, not interpreted.
//!
//! Everything else (Fleet Control, updates, live SDS, kicks, emergency clear:
//! the app keeps no emergency state) is ignored; the
//! app sends no `StationHello`, so the server never offers it Fleet Control
//! commands.

use futures_util::{SinkExt, StreamExt};
use std::time::Duration;
use tokio::sync::mpsc;
use tokio_tungstenite::tungstenite::{client::IntoClientRequest, http::HeaderValue, Message as WsMsg};
use url::Url;

use crate::transport::ConnectError;

pub const SUBPROTOCOL: &str = "bluestation-control-v1";
/// Server extension (control channel `X-Brew-Extensions`) asking for DGNA reports.
pub const EXT_DGNA_REPORT: &str = "dgna-report";
/// brew-server's default `[control] listen` port.
pub const DEFAULT_PORT: u16 = 9002;
const PING_EVERY: Duration = Duration::from_secs(10);
const RETRY_MIN: Duration = Duration::from_secs(5);
const RETRY_MAX: Duration = Duration::from_secs(60);

#[derive(Debug, Clone)]
pub struct ControlEndpoint {
    /// `ws://host:port/` or `wss://host:port/`, see [`control_url`].
    pub url: String,
    pub username: String,
    pub password: String,
    pub user_agent: String,
    pub insecure_tls: bool,
}

/// A group given by DGNA, as the server's `DgnaEntry`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DgnaGroup {
    pub gssi: u32,
    pub mnemonic: Option<String>,
    pub attachment_mode: u8,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ControlEvent {
    Connected,
    Disconnected { error: Option<String> },
    /// DGNA for our ISSI: `attach` true = assign, false = deassign.
    Dgna { group: DgnaGroup, attach: bool },
}

/// A command from the server that concerns `issi`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Parsed {
    Dgna { group: DgnaGroup, attach: bool },
}

/// Reads one control frame (`{"Dgna":{..}}`; other commands, also bare
/// strings for unit commands, are not taken). `None` for anything else or another ISSI.
pub fn parse_command(frame: &[u8], issi: u32) -> Option<Parsed> {
    let v: serde_json::Value = serde_json::from_slice(frame).ok()?;
    let (tag, body) = v.as_object()?.iter().next()?;
    let for_us = body.get("issi").and_then(|i| i.as_u64()) == Some(issi as u64);
    match tag.as_str() {
        "Dgna" if for_us => {
            let gssi = body.get("gssi")?.as_u64().filter(|g| (1..=0xFF_FFFF).contains(g))? as u32;
            let mnemonic = body.get("mnemonic").and_then(|m| m.as_str()).map(str::trim).filter(|m| !m.is_empty()).map(str::to_owned);
            let attachment_mode = body.get("attachment_mode").and_then(|m| m.as_u64()).unwrap_or(0).min(255) as u8;
            let attach = body.get("attach")?.as_bool()?;
            Some(Parsed::Dgna { group: DgnaGroup { gssi, mnemonic, attachment_mode }, attach })
        }
        _ => None,
    }
}

/// `DgnaChanged` (`dgna-report`), as FlowStation sends it: no name or mode on
/// a deassign.
pub fn build_changed(issi: u32, group: &DgnaGroup, assigned: bool) -> Vec<u8> {
    let body = serde_json::json!({
        "issi": issi,
        "gssi": group.gssi,
        "mnemonic": if assigned { group.mnemonic.clone() } else { None },
        "attachment_mode": if assigned { group.attachment_mode } else { 0 },
        "assigned": assigned,
    });
    serde_json::to_vec(&serde_json::json!({ "DgnaChanged": body })).unwrap_or_default()
}

/// `DgnaGroups` (`dgna-report`): what we hold, once after each connect.
pub fn build_groups(issi: u32, groups: &[DgnaGroup]) -> Vec<u8> {
    let list: Vec<serde_json::Value> = groups
        .iter()
        .map(|g| serde_json::json!({ "issi": issi, "gssi": g.gssi, "mnemonic": g.mnemonic, "attachment_mode": g.attachment_mode }))
        .collect();
    serde_json::to_vec(&serde_json::json!({ "DgnaGroups": { "groups": list } })).unwrap_or_default()
}

/// The control channel URL: `raw` as `host`, `host:port` or a full URL; empty
/// = the Brew server's host. Port 9002 unless given; `wss` with `tls`.
pub fn control_url(raw: &str, brew_url: &str, tls: bool) -> Result<Url, ConnectError> {
    let raw = raw.trim();
    let host_port = if raw.is_empty() {
        let brew = crate::transport::normalize_url(brew_url)?;
        brew.host_str().ok_or_else(|| ConnectError::Url("missing host".into()))?.to_string()
    } else {
        let without_scheme = raw.split_once("://").map_or(raw, |(_, r)| r);
        without_scheme.split('/').next().unwrap_or_default().to_string()
    };
    if host_port.is_empty() {
        return Err(ConnectError::Url("missing control host".into()));
    }
    let scheme = if tls { "wss" } else { "ws" };
    let mut url = Url::parse(&format!("{scheme}://{host_port}/")).map_err(|e| ConnectError::Url(e.to_string()))?;
    if url.port().is_none() {
        let _ = url.set_port(Some(DEFAULT_PORT));
    }
    Ok(url)
}

/// `Authorization: Basic …` (RFC 7617).
pub fn basic_authorization(user: &str, pass: &str) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let input = format!("{user}:{pass}").into_bytes();
    let mut out = String::with_capacity(input.len().div_ceil(3) * 4);
    for c in input.chunks(3) {
        let n = (u32::from(c[0]) << 16) | (u32::from(*c.get(1).unwrap_or(&0)) << 8) | u32::from(*c.get(2).unwrap_or(&0));
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    format!("Basic {out}")
}

pub enum ControlCommand {
    Shutdown,
}

#[derive(Clone)]
pub struct ControlHandle(mpsc::UnboundedSender<ControlCommand>);

impl ControlHandle {
    pub fn shutdown(&self) {
        let _ = self.0.send(ControlCommand::Shutdown);
    }
}

async fn connect(ep: &ControlEndpoint) -> Result<(crate::transport::Ws, bool), ConnectError> {
    let url = Url::parse(&ep.url).map_err(|e| ConnectError::Url(e.to_string()))?;
    let mut req = url.as_str().into_client_request()?;
    let h = req.headers_mut();
    h.insert("Sec-WebSocket-Protocol", HeaderValue::from_static(SUBPROTOCOL));
    h.insert("User-Agent", HeaderValue::from_str(&ep.user_agent).map_err(|_| ConnectError::Url("bad user agent".into()))?);
    if !ep.username.is_empty() {
        let auth = basic_authorization(&ep.username, &ep.password);
        h.insert("Authorization", HeaderValue::from_str(&auth).map_err(|_| ConnectError::Url("bad credentials".into()))?);
    }
    let stream = crate::transport::open(&url, ep.insecure_tls).await?;
    let (ws, resp) = tokio_tungstenite::client_async(req, stream).await.map_err(|e| match e {
        tokio_tungstenite::tungstenite::Error::Http(r) if r.status() == 401 || r.status() == 403 => ConnectError::Unauthorized,
        e => ConnectError::Ws(e),
    })?;
    let offered = crate::transport::parse_extensions(resp.headers().get("X-Brew-Extensions").and_then(|v| v.to_str().ok()));
    Ok((ws, offered.iter().any(|e| e == EXT_DGNA_REPORT)))
}

/// Runs the channel until [`ControlHandle::shutdown`], reconnecting after a
/// drop. `groups`: the DGNA groups the app already holds for `issi`.
pub fn spawn(ep: ControlEndpoint, issi: u32, groups: Vec<DgnaGroup>) -> (ControlHandle, mpsc::UnboundedReceiver<ControlEvent>) {
    let (cmd_tx, mut cmd_rx) = mpsc::unbounded_channel();
    let (ev_tx, ev_rx) = mpsc::unbounded_channel();
    tokio::spawn(async move {
        let mut held = groups;
        let mut retry = RETRY_MIN;
        loop {
            let error = match connect(&ep).await {
                Ok((ws, report)) => {
                    retry = RETRY_MIN;
                    let _ = ev_tx.send(ControlEvent::Connected);
                    let (mut tx, mut rx) = ws.split();
                    let sent = !report || tx.send(WsMsg::Binary(build_groups(issi, &held).into())).await.is_ok();
                    let mut ping = tokio::time::interval_at(tokio::time::Instant::now() + PING_EVERY, PING_EVERY);
                    if !sent {
                        Some("connection lost".to_string())
                    } else { loop {
                        tokio::select! {
                            cmd = cmd_rx.recv() => match cmd {
                                Some(ControlCommand::Shutdown) | None => {
                                    let _ = tx.send(WsMsg::Close(None)).await;
                                    let _ = ev_tx.send(ControlEvent::Disconnected { error: None });
                                    return;
                                }
                            },
                            _ = ping.tick() => {
                                if tx.send(WsMsg::Ping(Vec::new().into())).await.is_err() { break Some("connection lost".to_string()); }
                            }
                            msg = rx.next() => match msg {
                                Some(Ok(WsMsg::Binary(b))) => handle_frame(&b, issi, report, &mut held, &mut tx, &ev_tx).await,
                                Some(Ok(WsMsg::Text(t))) => handle_frame(t.as_bytes(), issi, report, &mut held, &mut tx, &ev_tx).await,
                                Some(Ok(WsMsg::Close(_))) | None => break Some("closed by the server".to_string()),
                                Some(Ok(_)) => {}
                                Some(Err(e)) => break Some(e.to_string()),
                            },
                        }
                    } }
                }
                Err(e) => Some(e.to_string()),
            };
            let _ = ev_tx.send(ControlEvent::Disconnected { error });
            tokio::select! {
                _ = tokio::time::sleep(retry) => {}
                cmd = cmd_rx.recv() => if matches!(cmd, Some(ControlCommand::Shutdown) | None) { return },
            }
            retry = (retry * 2).min(RETRY_MAX);
        }
    });
    (ControlHandle(cmd_tx), ev_rx)
}

async fn handle_frame<S>(frame: &[u8], issi: u32, report: bool, held: &mut Vec<DgnaGroup>, tx: &mut S, ev: &mpsc::UnboundedSender<ControlEvent>)
where
    S: futures_util::Sink<WsMsg> + Unpin,
{
    match parse_command(frame, issi) {
        Some(Parsed::Dgna { group, attach }) => {
            held.retain(|g| g.gssi != group.gssi);
            if attach {
                held.push(group.clone());
            }
            if report {
                let _ = tx.send(WsMsg::Binary(build_changed(issi, &group, attach).into())).await;
            }
            let _ = ev.send(ControlEvent::Dgna { group, attach });
        }
        None => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_dgna_for_our_issi_only() {
        let assign = br#"{"Dgna":{"issi":2320997,"gssi":2329,"mnemonic":"Event","attachment_mode":1,"attach":true}}"#;
        assert_eq!(
            parse_command(assign, 2320997),
            Some(Parsed::Dgna { group: DgnaGroup { gssi: 2329, mnemonic: Some("Event".into()), attachment_mode: 1 }, attach: true })
        );
        assert_eq!(parse_command(assign, 2320998), None, "another radio");
        let deassign = br#"{"Dgna":{"issi":7,"gssi":91,"mnemonic":null,"attachment_mode":0,"attach":false}}"#;
        assert_eq!(parse_command(deassign, 7), Some(Parsed::Dgna { group: DgnaGroup { gssi: 91, mnemonic: None, attachment_mode: 0 }, attach: false }));
        assert_eq!(parse_command(br#"{"ClearEmergency":{"issi":7}}"#, 7), None, "not taken");
        assert_eq!(parse_command(br#"{"KickMs":{"issi":7}}"#, 7), None, "not taken");
        assert_eq!(parse_command(br#""RestartService""#, 7), None);
        assert_eq!(parse_command(br#"{"Dgna":{"issi":7,"gssi":0,"attach":true}}"#, 7), None, "GSSI 0");
        assert_eq!(parse_command(b"garbage", 7), None);
    }

    #[test]
    fn reports_match_the_server_shape() {
        let g = DgnaGroup { gssi: 2329, mnemonic: Some("Event".into()), attachment_mode: 1 };
        let v: serde_json::Value = serde_json::from_slice(&build_changed(7, &g, true)).unwrap();
        assert_eq!(v, serde_json::json!({"DgnaChanged":{"issi":7,"gssi":2329,"mnemonic":"Event","attachment_mode":1,"assigned":true}}));
        let v: serde_json::Value = serde_json::from_slice(&build_changed(7, &g, false)).unwrap();
        assert_eq!(v, serde_json::json!({"DgnaChanged":{"issi":7,"gssi":2329,"mnemonic":null,"attachment_mode":0,"assigned":false}}));
        let v: serde_json::Value = serde_json::from_slice(&build_groups(7, &[g])).unwrap();
        assert_eq!(v, serde_json::json!({"DgnaGroups":{"groups":[{"issi":7,"gssi":2329,"mnemonic":"Event","attachment_mode":1}]}}));
    }

    #[test]
    fn control_url_defaults_to_the_brew_host_on_9002() {
        assert_eq!(control_url("", "https://brew.example.org/brew/", false).unwrap().as_str(), "ws://brew.example.org:9002/");
        assert_eq!(control_url("", "brew.example.org:9000", true).unwrap().as_str(), "wss://brew.example.org:9002/");
        assert_eq!(control_url("ctl.example.org:9443", "x", true).unwrap().as_str(), "wss://ctl.example.org:9443/");
        assert_eq!(control_url("wss://ctl.example.org/", "x", false).unwrap().as_str(), "ws://ctl.example.org:9002/", "the switch decides TLS");
    }

    #[test]
    fn basic_auth_is_rfc_7617() {
        assert_eq!(basic_authorization("Aladdin", "open sesame"), "Basic QWxhZGRpbjpvcGVuIHNlc2FtZQ==");
        assert_eq!(basic_authorization("a", "b"), "Basic YTpi");
        assert_eq!(basic_authorization("ab", "c"), "Basic YWI6Yw==");
    }
}
