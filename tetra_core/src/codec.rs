//! TETRA ACELP voice (ETSI EN 300 395-2) via the vendored reference codec,
//! plus the 60 ms framing Brew uses on the wire.
//!
//! Audio contract with the app: 8 kHz, mono, signed 16-bit PCM. The phone
//! side records/plays at 8 kHz (Android AudioRecord/AudioTrack and iOS
//! AVAudioEngine both support it) and exchanges 480-sample (60 ms) blocks.

use crate::protocol::{self, ACELP_CODED_FRAME_BYTES, ACELP_PCM_SAMPLES};
use std::os::raw::c_int;
use uuid::Uuid;

/// Samples in one Brew traffic frame (two ACELP subframes).
pub const FRAME_SAMPLES: usize = 2 * ACELP_PCM_SAMPLES;
pub const SAMPLE_RATE: u32 = 8000;

#[repr(C)]
struct RawCodec {
    _p: [u8; 0],
}

unsafe extern "C" {
    fn tetra_encoder_create() -> *mut RawCodec;
    fn tetra_decoder_create() -> *mut RawCodec;
    fn tetra_codec_destroy(st: *mut RawCodec);
    fn tetra_encode(st: *mut RawCodec, pcm: *const i16, coded: *mut u8);
    fn tetra_decode(st: *mut RawCodec, coded: *const u8, pcm: *mut i16, bfi: c_int);
}

struct Handle(*mut RawCodec);
// Owned by exactly one encoder/decoder, which is moved, never shared.
unsafe impl Send for Handle {}
impl Drop for Handle {
    fn drop(&mut self) {
        unsafe { tetra_codec_destroy(self.0) }
    }
}

/// Stateful ACELP encoder: one per outgoing transmission.
pub struct VoiceEncoder {
    h: Handle,
    pending: Vec<i16>,
}

impl Default for VoiceEncoder {
    fn default() -> Self {
        Self::new()
    }
}

impl VoiceEncoder {
    pub fn new() -> Self {
        Self { h: Handle(unsafe { tetra_encoder_create() }), pending: Vec::with_capacity(FRAME_SAMPLES * 2) }
    }

    fn encode_sub(&mut self, pcm: &[i16]) -> [u8; ACELP_CODED_FRAME_BYTES] {
        debug_assert_eq!(pcm.len(), ACELP_PCM_SAMPLES);
        let mut out = [0u8; ACELP_CODED_FRAME_BYTES];
        unsafe { tetra_encode(self.h.0, pcm.as_ptr(), out.as_mut_ptr()) };
        out
    }

    /// Feed any amount of microphone PCM; returns one 36-byte STE payload per
    /// complete 60 ms block. Leftover samples are kept for the next call.
    pub fn push(&mut self, pcm: &[i16]) -> Vec<[u8; protocol::STE_VOICE_PAYLOAD_BYTES]> {
        self.pending.extend_from_slice(pcm);
        let mut out = Vec::new();
        while self.pending.len() >= FRAME_SAMPLES {
            let block: Vec<i16> = self.pending.drain(..FRAME_SAMPLES).collect();
            let a = self.encode_sub(&block[..ACELP_PCM_SAMPLES]);
            let b = self.encode_sub(&block[ACELP_PCM_SAMPLES..]);
            out.push(protocol::pack_ste(&a, &b));
        }
        out
    }

    /// Same as [`push`] but returns ready-to-send Brew frames for call `id`.
    pub fn push_frames(&mut self, id: &Uuid, pcm: &[i16]) -> Vec<Vec<u8>> {
        self.push(pcm)
            .into_iter()
            .map(|p| protocol::build_frame(protocol::FRAME_TRAFFIC_CHANNEL, id, (p.len() * 8) as u16, &p))
            .collect()
    }
}

/// Stateful ACELP decoder: one per incoming transmission.
pub struct VoiceDecoder {
    h: Handle,
}

impl Default for VoiceDecoder {
    fn default() -> Self {
        Self::new()
    }
}

impl VoiceDecoder {
    pub fn new() -> Self {
        Self { h: Handle(unsafe { tetra_decoder_create() }) }
    }

    fn decode_sub(&mut self, coded: &[u8; ACELP_CODED_FRAME_BYTES], bad: bool) -> [i16; ACELP_PCM_SAMPLES] {
        let mut pcm = [0i16; ACELP_PCM_SAMPLES];
        unsafe { tetra_decode(self.h.0, coded.as_ptr(), pcm.as_mut_ptr(), bad as c_int) };
        pcm
    }

    /// Decode one STE payload into 480 samples. A malformed payload runs the
    /// codec's bad-frame concealment instead of producing garbage.
    pub fn decode(&mut self, ste: &[u8]) -> Vec<i16> {
        let (a, b, bad) = match protocol::unpack_ste(ste) {
            Some((a, b)) => (a, b, false),
            None => ([0; ACELP_CODED_FRAME_BYTES], [0; ACELP_CODED_FRAME_BYTES], true),
        };
        let mut out = Vec::with_capacity(FRAME_SAMPLES);
        out.extend_from_slice(&self.decode_sub(&a, bad));
        out.extend_from_slice(&self.decode_sub(&b, bad));
        out
    }

    /// Concealment for a frame that never arrived (jitter buffer underrun).
    pub fn conceal(&mut self) -> Vec<i16> {
        self.decode(&[])
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn encodes_60ms_blocks_and_decodes_tone() {
        let mut enc = VoiceEncoder::new();
        let tone: Vec<i16> = (0..FRAME_SAMPLES * 5).map(|i| ((i as f32 * 0.15).sin() * 9000.0) as i16).collect();
        // Feed in odd-sized chunks like a real audio callback would.
        let mut frames = Vec::new();
        for chunk in tone.chunks(333) {
            frames.extend(enc.push(chunk));
        }
        assert_eq!(frames.len(), 5);
        let mut dec = VoiceDecoder::new();
        let mut energy = 0i64;
        for f in &frames {
            let pcm = dec.decode(f);
            assert_eq!(pcm.len(), FRAME_SAMPLES);
            energy += pcm.iter().map(|&s| (s as i64).abs()).sum::<i64>();
        }
        assert!(energy > 0, "decoded audio should not be silent");
        assert_eq!(dec.conceal().len(), FRAME_SAMPLES);
    }
}
