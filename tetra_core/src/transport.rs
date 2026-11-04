//! Connection set-up: HTTP Digest discovery and the WebSocket upgrade.
//!
//! Flow (Brew spec "Endpoint, authentication", as brew-server implements it):
//! 1. `GET /brew` with `User-Agent`, `X-Brew-Mode: Terminal`, `X-Brew-Version: 1`.
//! 2. On 401, answer the `Digest realm=…, nonce=…, qop="auth", opaque=…`
//!    challenge (RFC 2617 MD5, qop=auth) on the same path.
//! 3. The 200 body is the WebSocket path (`/brew/session/<token>`, single use).
//! 4. Upgrade on that path with sub-protocol `brew`.

use md5::{Digest, Md5};
use std::sync::Arc;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::http::HeaderValue;
use tokio_tungstenite::WebSocketStream;
use url::Url;

pub trait Io: AsyncRead + AsyncWrite + Unpin + Send {}
impl<T: AsyncRead + AsyncWrite + Unpin + Send> Io for T {}
pub type Stream = Box<dyn Io>;
pub type Ws = WebSocketStream<Stream>;

#[derive(Debug, thiserror::Error)]
pub enum ConnectError {
    #[error("invalid server URL: {0}")]
    Url(String),
    #[error("network error: {0}")]
    Io(#[from] std::io::Error),
    #[error("TLS error: {0}")]
    Tls(String),
    #[error("authentication failed (check ISSI/username and password)")]
    Unauthorized,
    #[error("server refused connection: HTTP {0}")]
    Http(u16),
    #[error("malformed HTTP response")]
    BadResponse,
    #[error("WebSocket error: {0}")]
    Ws(#[from] tokio_tungstenite::tungstenite::Error),
}

#[derive(Debug, Clone)]
pub struct Endpoint {
    /// e.g. `https://brew.example.org:9000/brew` (http:// for a lab server).
    pub url: String,
    pub username: String,
    pub password: String,
    pub user_agent: String,
    /// Accept self-signed certificates (lab use only).
    pub insecure_tls: bool,
}

fn md5_hex(s: &str) -> String {
    hex::encode(Md5::digest(s.as_bytes()))
}

fn tls_config(insecure: bool) -> Arc<rustls::ClientConfig> {
    let provider = Arc::new(rustls::crypto::ring::default_provider());
    let builder = rustls::ClientConfig::builder_with_provider(provider.clone())
        .with_safe_default_protocol_versions()
        .expect("ring supports default versions");
    let cfg = if insecure {
        builder.dangerous().with_custom_certificate_verifier(Arc::new(NoVerify(provider))).with_no_client_auth()
    } else {
        let roots = rustls::RootCertStore { roots: webpki_roots::TLS_SERVER_ROOTS.to_vec() };
        builder.with_root_certificates(roots).with_no_client_auth()
    };
    Arc::new(cfg)
}

async fn open(url: &Url, insecure: bool) -> Result<Stream, ConnectError> {
    let host = url.host_str().ok_or_else(|| ConnectError::Url("missing host".into()))?.to_string();
    let port = url.port_or_known_default().ok_or_else(|| ConnectError::Url("missing port".into()))?;
    let tcp = TcpStream::connect((host.as_str(), port)).await?;
    tcp.set_nodelay(true)?; // recommended by the Brew spec
    match url.scheme() {
        "http" | "ws" => Ok(Box::new(tcp)),
        "https" | "wss" => {
            let name = rustls::pki_types::ServerName::try_from(host).map_err(|e| ConnectError::Tls(e.to_string()))?;
            let tls = tokio_rustls::TlsConnector::from(tls_config(insecure))
                .connect(name, tcp)
                .await
                .map_err(|e| ConnectError::Tls(e.to_string()))?;
            Ok(Box::new(tls))
        }
        s => Err(ConnectError::Url(format!("unsupported scheme {s}"))),
    }
}

struct HttpResponse {
    status: u16,
    headers: Vec<(String, String)>,
    body: String,
}

impl HttpResponse {
    fn header(&self, name: &str) -> Option<&str> {
        self.headers.iter().find(|(k, _)| k.eq_ignore_ascii_case(name)).map(|(_, v)| v.as_str())
    }
}

async fn http_get(url: &Url, ep: &Endpoint, authorization: Option<&str>) -> Result<HttpResponse, ConnectError> {
    let mut s = open(url, ep.insecure_tls).await?;
    let host = match url.port() {
        Some(p) => format!("{}:{p}", url.host_str().unwrap_or_default()),
        None => url.host_str().unwrap_or_default().to_string(),
    };
    let mut req = format!(
        "GET {} HTTP/1.1\r\nHost: {host}\r\nUser-Agent: {}\r\nX-Brew-Mode: Terminal\r\nX-Brew-Version: {}\r\nConnection: close\r\n",
        url.path(),
        ep.user_agent,
        crate::protocol::BREW_PROTOCOL_VERSION
    );
    if let Some(a) = authorization {
        req.push_str(&format!("Authorization: {a}\r\n"));
    }
    req.push_str("\r\n");
    s.write_all(req.as_bytes()).await?;
    let mut raw = Vec::new();
    // Bounded read: the discovery response is tiny.
    let _ = tokio::time::timeout(std::time::Duration::from_secs(10), s.take(64 * 1024).read_to_end(&mut raw)).await;
    parse_http(&raw).ok_or(ConnectError::BadResponse)
}

fn parse_http(raw: &[u8]) -> Option<HttpResponse> {
    let text = String::from_utf8_lossy(raw);
    let (head, body) = text.split_once("\r\n\r\n")?;
    let mut lines = head.lines();
    let status = lines.next()?.split_whitespace().nth(1)?.parse().ok()?;
    let headers = lines.filter_map(|l| l.split_once(':')).map(|(k, v)| (k.trim().to_string(), v.trim().to_string())).collect::<Vec<_>>();
    let chunked = headers.iter().any(|(k, v)| k.eq_ignore_ascii_case("transfer-encoding") && v.contains("chunked"));
    let body = if chunked {
        // Minimal chunked decoding: concatenate chunk payloads.
        let mut out = String::new();
        let mut rest = body;
        while let Some((size, after)) = rest.split_once("\r\n") {
            let n = usize::from_str_radix(size.trim(), 16).ok()?;
            if n == 0 {
                break;
            }
            out.push_str(after.get(..n)?);
            rest = after.get(n + 2..).unwrap_or("");
        }
        out
    } else {
        body.to_string()
    };
    Some(HttpResponse { status, headers, body: body.trim().to_string() })
}

fn parse_challenge(h: &str) -> std::collections::HashMap<String, String> {
    let v = h.trim().strip_prefix("Digest").unwrap_or(h).trim();
    let mut out = std::collections::HashMap::new();
    let mut rest = v;
    while !rest.is_empty() {
        let Some((k, after)) = rest.split_once('=') else { break };
        let k = k.trim().trim_start_matches(',').trim().to_ascii_lowercase();
        let (val, tail) = if let Some(q) = after.strip_prefix('"') {
            let end = q.find('"').unwrap_or(q.len());
            (&q[..end], q.get(end + 1..).unwrap_or(""))
        } else {
            let end = after.find(',').unwrap_or(after.len());
            (after[..end].trim(), &after[end..])
        };
        out.insert(k, val.to_string());
        rest = tail.trim_start_matches([',', ' ']);
    }
    out
}

/// RFC 2617 Digest response (MD5, qop=auth when offered).
pub fn digest_authorization(challenge: &str, user: &str, pass: &str, method: &str, uri: &str, cnonce: &str) -> String {
    let c = parse_challenge(challenge);
    let realm = c.get("realm").cloned().unwrap_or_default();
    let nonce = c.get("nonce").cloned().unwrap_or_default();
    let ha1 = md5_hex(&format!("{user}:{realm}:{pass}"));
    let ha2 = md5_hex(&format!("{method}:{uri}"));
    let qop_auth = c.get("qop").is_some_and(|q| q.split(',').any(|x| x.trim() == "auth"));
    let mut h = format!("Digest username=\"{user}\", realm=\"{realm}\", nonce=\"{nonce}\", uri=\"{uri}\"");
    if qop_auth {
        let nc = "00000001";
        let resp = md5_hex(&format!("{ha1}:{nonce}:{nc}:{cnonce}:auth:{ha2}"));
        h.push_str(&format!(", qop=auth, nc={nc}, cnonce=\"{cnonce}\", response=\"{resp}\""));
    } else {
        h.push_str(&format!(", response=\"{}\"", md5_hex(&format!("{ha1}:{nonce}:{ha2}"))));
    }
    if let Some(o) = c.get("opaque") {
        h.push_str(&format!(", opaque=\"{o}\""));
    }
    h
}

/// Accepts `http://`, `https://`, `ws://`, `wss://`, or a bare `host:port/path`
/// (treated as plain `http://`). Discovery always runs over HTTP(S).
pub fn normalize_url(raw: &str) -> Result<Url, ConnectError> {
    let raw = raw.trim();
    let with_scheme = if raw.contains("://") { raw.to_string() } else { format!("http://{raw}") };
    let mut url = Url::parse(&with_scheme).map_err(|e| ConnectError::Url(e.to_string()))?;
    let scheme = match url.scheme() {
        "http" | "ws" => "http",
        "https" | "wss" => "https",
        s => return Err(ConnectError::Url(format!("unsupported scheme {s} (use http:// or https://)"))),
    };
    if url.scheme() != scheme {
        url = Url::parse(&with_scheme.replacen(url.scheme(), scheme, 1)).map_err(|e| ConnectError::Url(e.to_string()))?;
    }
    if url.path().is_empty() || url.path() == "/" {
        url.set_path("/brew/");
    }
    Ok(url)
}

/// Discovery + authentication + WebSocket upgrade.
pub async fn connect(ep: &Endpoint) -> Result<Ws, ConnectError> {
    let url = normalize_url(&ep.url)?;
    let mut resp = http_get(&url, ep, None).await?;
    if resp.status == 401 {
        let challenge = resp.header("WWW-Authenticate").ok_or(ConnectError::Unauthorized)?.to_string();
        let cnonce = format!("{:016x}", rand::random::<u64>());
        let auth = digest_authorization(&challenge, &ep.username, &ep.password, "GET", url.path(), &cnonce);
        resp = http_get(&url, ep, Some(&auth)).await?;
        if resp.status == 401 || resp.status == 403 {
            return Err(ConnectError::Unauthorized);
        }
    }
    if resp.status != 200 {
        return Err(ConnectError::Http(resp.status));
    }
    let path = resp.body.lines().next().unwrap_or("").trim();
    let mut ws_url = url.clone();
    ws_url.set_path(if path.is_empty() { url.path() } else { path });
    let ws_scheme = if url.scheme() == "https" { "wss" } else { "ws" };
    let ws_url_str = ws_url.as_str().replacen(url.scheme(), ws_scheme, 1);

    let mut req = ws_url_str.as_str().into_client_request()?;
    let h = req.headers_mut();
    h.insert("Sec-WebSocket-Protocol", HeaderValue::from_static("brew"));
    h.insert("User-Agent", HeaderValue::from_str(&ep.user_agent).map_err(|_| ConnectError::Url("bad user agent".into()))?);
    h.insert("X-Brew-Mode", HeaderValue::from_static("Terminal"));
    h.insert("X-Brew-Version", HeaderValue::from_static("1"));
    let stream = open(&ws_url, ep.insecure_tls).await?;
    let (ws, _resp) = tokio_tungstenite::client_async(req, stream).await?;
    Ok(ws)
}

#[derive(Debug)]
struct NoVerify(Arc<rustls::crypto::CryptoProvider>);

impl rustls::client::danger::ServerCertVerifier for NoVerify {
    fn verify_server_cert(
        &self,
        _: &rustls::pki_types::CertificateDer<'_>,
        _: &[rustls::pki_types::CertificateDer<'_>],
        _: &rustls::pki_types::ServerName<'_>,
        _: &[u8],
        _: rustls::pki_types::UnixTime,
    ) -> Result<rustls::client::danger::ServerCertVerified, rustls::Error> {
        Ok(rustls::client::danger::ServerCertVerified::assertion())
    }
    fn verify_tls12_signature(
        &self,
        m: &[u8],
        c: &rustls::pki_types::CertificateDer<'_>,
        d: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls12_signature(m, c, d, &self.0.signature_verification_algorithms)
    }
    fn verify_tls13_signature(
        &self,
        m: &[u8],
        c: &rustls::pki_types::CertificateDer<'_>,
        d: &rustls::DigitallySignedStruct,
    ) -> Result<rustls::client::danger::HandshakeSignatureValid, rustls::Error> {
        rustls::crypto::verify_tls13_signature(m, c, d, &self.0.signature_verification_algorithms)
    }
    fn supported_verify_schemes(&self) -> Vec<rustls::SignatureScheme> {
        self.0.signature_verification_algorithms.supported_schemes()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn url_forms() {
        assert_eq!(normalize_url("192.168.1.10:9000/brew/").unwrap().as_str(), "http://192.168.1.10:9000/brew/");
        assert_eq!(normalize_url("http://h:9000").unwrap().as_str(), "http://h:9000/brew/");
        assert_eq!(normalize_url("wss://h/brew/").unwrap().as_str(), "https://h/brew/");
        assert_eq!(normalize_url("ws://h:9000/brew").unwrap().as_str(), "http://h:9000/brew");
        assert!(normalize_url("ftp://h").is_err());
    }

    #[test]
    fn digest_matches_server_verification() {
        // Recompute exactly as brew-server's verify_digest() does.
        let ch = r#"Digest realm="brew-server", nonce="abc123", qop="auth", opaque="0f0f""#;
        let h = digest_authorization(ch, "2040001", "secret", "GET", "/brew", "cafe");
        let ha1 = md5_hex("2040001:brew-server:secret");
        let ha2 = md5_hex("GET:/brew");
        let want = md5_hex(&format!("{ha1}:abc123:00000001:cafe:auth:{ha2}"));
        let p = parse_challenge(&h);
        assert_eq!(p["response"], want);
        assert_eq!(p["opaque"], "0f0f");
        assert_eq!(p["uri"], "/brew");
    }

    #[test]
    fn parses_discovery_response() {
        let raw = b"HTTP/1.1 200 OK\r\ncontent-type: text/plain\r\nx-brew-version: 1\r\n\r\n/brew/session/abcd";
        let r = parse_http(raw).unwrap();
        assert_eq!((r.status, r.body.as_str()), (200, "/brew/session/abcd"));
        let chunked = b"HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\n\r\n12\r\n/brew/session/abcd\r\n0\r\n\r\n";
        assert_eq!(parse_http(chunked).unwrap().body, "/brew/session/abcd");
    }
}
