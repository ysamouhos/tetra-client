# TETRA Brew Terminal

A cross-platform TETRA terminal app (Android first, iOS second) that connects
to [brew-server](https://github.com/ysamouhos/brew-server) over the Brew
(TETRA Homebrew) protocol.

| Feature | Status |
|---|---|
| Brew connection: HTTP Digest discovery, session path, WebSocket `brew` sub-protocol, `X-Brew-Mode: Terminal`, Brew v1 | ✅ live-tested |
| Register / re-register / deregister, affiliate / de-affiliate talkgroups | ✅ live-tested |
| Group calls, half duplex PTT, talker name (SS-TPI mnemonic) | ✅ live-tested |
| Private calls, full duplex, hook (ring + answer) | ✅ live-tested |
| Private calls, half duplex, direct (no answer) | ✅ live-tested |
| Call priority 0–15, emergency (15), pre-emption | ✅ live-tested |
| Text SDS, private and group, SDS-TL delivery reports, flash messages | ✅ live-tested |
| LIP short location reports via SDS (send and receive) | ✅ live-tested |
| TETRA ACELP voice (ETSI EN 300 395-2), STE framing | ✅ live-tested |
| Talkgroup list with scan, DTMF in private calls | ✅ in app |

"Live-tested" means two instances of the client exchanged it through a real
brew-server built from your repo, with Digest auth on (8/8 scenarios, no
server warnings).

## Layout

```
tetra_core/      Rust: everything protocol, call and codec related (shared by both platforms)
  src/protocol.rs   Brew wire format (mirrors brew-server's protocol.rs byte for byte)
  src/calls.rs      Call engine: group/private, simplex/duplex, priority, pre-emption, timers
  src/sds.rs        SDS-TL text (Latin-1, ISO 8859-7 Greek, UCS-2), reports, LIP encode/decode
  src/codec.rs      ACELP encoder/decoder + 60 ms framing (vendored ETSI codec, same as server)
  src/transport.rs  Digest auth, discovery, TLS (rustls + ring), WebSocket upgrade
  src/client.rs     The running terminal: reconnect, re-registration, SDS bookkeeping, audio
  src/api.rs        Flat API for flutter_rust_bridge
  tests/            Unit tests + end-to-end test against a mock Brew server
  examples/live_two_terminals.rs   Live test against a real brew-server
app/             Flutter UI (Talkgroups + PTT, Calls, Messages, Settings)
```

All TETRA logic lives in Rust, so Android and iOS behave identically. The
Flutter side only moves 8 kHz PCM between the mic/speaker and the core.

## Build (Android)

Prerequisites: Flutter ≥ 3.22, Android Studio with the NDK, Rust via rustup.

```bash
cd app
./tool/setup.sh        # one time: platform folders, Rust bridge, permissions, bindings
flutter run            # with an Android phone attached
```

### iOS (no Mac needed)

`.github/workflows/ios.yml` builds the app on GitHub's macOS runners on every
push to `main` (or by hand from the Actions tab). Each run produces:

* `tetra-terminal-unsigned-ipa`: install it with Sideloadly or AltStore from
  Windows, signed with a free Apple ID (re-sign every 7 days), or with your own
  certificate once you have an Apple Developer account.
* `tetra-terminal-simulator`: `Runner.app` for the iOS Simulator.

### First run

In **Settings**, enter the server URL (e.g. `https://your-host:9000/brew/`),
the username and password from `[auth.users]` in `brew-server.toml`, and
your ISSI. Then add talkgroups (GSSIs) on the **Talkgroups** tab.

## Test the core

```bash
cd tetra_core
cargo test                                   # 23 unit tests + end-to-end session

# against a running brew-server with two [auth.users] entries:
cargo run --example live_two_terminals -- http://127.0.0.1:9100/brew/ 2040001:pw1 2040002:pw2 91
```

## Protocol notes

* **Spec sources**: TetraPack Brew specification; brew-server `src/protocol.rs`
  as ground truth for layouts (v1 `mnemonic[34]` on `GROUP_TX` and
  `SETUP_REQUEST` only, 2-byte `CONNECT_CONFIRM`, 58-byte `SHORT_TRANSFER`,
  36-byte STE voice payload carrying two 137-bit ACELP subframes).
* **Private calls** follow FlowStation semantics as documented in
  brew-server: `SETUP_REQUEST` → `SETUP_ACCEPT` + `CALL_ALERT` →
  `CONNECT_REQUEST` (answer) → `CONNECT_CONFIRM`. `method=1` rings,
  `method=0` connects directly. `duplex=1` keeps both microphones live.
* **Half-duplex private floor**: the talker sends `SIMPLEX_GRANTED` on PTT
  and `SIMPLEX_IDLE` on release; the other side treats a received
  `SIMPLEX_GRANTED` as "peer talking".
* **Priority**: ETSI 4-bit call priority. 12–14 are pre-emptive, 15 is
  emergency. Higher number wins (brew-server's `higher_priority_number_wins`).
  The server pre-empts group floors; the client also pre-empts its own
  lower-priority private call for a pre-emptive incoming call, and picks
  which call's audio to play by priority.
* **SDS**: text uses PID 0x82 (0x89 for flash) with SDS-TL; reports are
  requested for private messages only. LIP uses PID 0x0A short location
  reports (76 bits), validated against the live Athens beacon in
  brew-server's tests.

## Known gaps / next steps

* **Flutter code was written but not compiled here** (no Flutter SDK in my
  build environment). The Rust core is fully built and tested. Expect a
  couple of small fixes on the first `flutter analyze`, most likely around
  generated binding names and the `record` / `flutter_pcm_sound` plugin APIs,
  which are isolated in `lib/services/audio_io.dart`.
* **Half-duplex private floor against real radios**: verified client-to-client
  through brew-server. Whether a Basestation-attached radio uses the
  `SIMPLEX_GRANTED`/`SIMPLEX_IDLE` grant fields the same way is unverified.
* **Background operation**: calls are received while the app is open.
  Receiving with the screen off needs an Android foreground service
  (microphone type) and, on iOS, the PushToTalk framework.
* **Hardware PTT keys** on rugged phones are not mapped yet.
* **Password storage** uses shared_preferences; switch to
  flutter_secure_storage before release.
* **ACELP codec licensing**: the vendored ETSI reference codec comes from
  your brew-server repo. Check ETSI's IPR terms before publishing to an app store.
