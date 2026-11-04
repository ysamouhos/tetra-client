import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart';

/// 8 kHz mono PCM16 microphone capture and speaker playback.
///
/// The Rust core does all ACELP work; this layer only moves raw samples.
/// Third-party audio plugin calls are confined to this file so they can be
/// swapped (e.g. for a native AudioRecord/AudioTrack channel) without
/// touching the rest of the app.
class AudioIO {
  static const sampleRate = 8000;

  /// The mic is captured at 16 kHz and decimated here with a proper low-pass.
  /// Asking Android for 8 kHz directly makes many devices resample badly
  /// (aliasing = glitches and whistles that the ACELP codec amplifies).
  static const _micRate = 16000;
  final _decim = _Decimator2();

  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  bool _playerReady = false;
  DateTime _lastPlay = DateTime.fromMillisecondsSinceEpoch(0);
  final _carry = BytesBuilder(copy: false);

  Future<void> init() async {
    // iOS: one session for simultaneous mic + speaker (full-duplex calls), voice
    // processing (echo cancellation), loudspeaker by default, Bluetooth headsets
    // allowed. On Android this maps to voice-communication audio.
    final session = await AudioSession.instance;
    await session.configure(AudioSessionConfiguration(
      avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
      avAudioSessionCategoryOptions: AVAudioSessionCategoryOptions.defaultToSpeaker |
          AVAudioSessionCategoryOptions.allowBluetooth |
          AVAudioSessionCategoryOptions.allowBluetoothA2dp,
      avAudioSessionMode: AVAudioSessionMode.voiceChat,
      androidAudioAttributes: const AndroidAudioAttributes(
        contentType: AndroidAudioContentType.speech,
        usage: AndroidAudioUsage.voiceCommunication,
      ),
      androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
    ));
    await session.setActive(true);
    await FlutterPcmSound.setup(sampleRate: sampleRate, channelCount: 1);
    // ~120 ms of headroom: two Brew frames of jitter.
    await FlutterPcmSound.setFeedThreshold(sampleRate ~/ 8);
    _playerReady = true;
  }

  bool get micRunning => _micSub != null;

  // Diagnostics for the last/current capture session.
  int micChunks = 0;
  int micSamples = 0;
  int micPeak = 0;
  Object? micError;
  String get micSummary =>
      'mic: ${micRunning ? "running" : "stopped"}, chunks=$micChunks, samples=$micSamples, peak=$micPeak'
      '${micError != null ? ", error=$micError" : ""}';

  /// Starts streaming microphone audio to [onPcm]. Echo cancellation is on
  /// so full-duplex calls do not feed the speaker back into the mic.
  ///
  /// [voiceProcessing] enables platform echo cancellation / noise suppression /
  /// AGC. Only full-duplex calls need it; in half-duplex PTT the speaker is
  /// silent while the mic is live, and the processing only distorts the signal
  /// the ACELP encoder sees (and on iOS contends with the playback engine).
  Future<void> startMic(void Function(Int16List pcm) onPcm, {bool voiceProcessing = false}) async {
    if (_micSub != null) return;
    micChunks = 0;
    micSamples = 0;
    micPeak = 0;
    micError = null;
    _decim.reset();
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission denied');
    }
    final stream = await _recorder.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: _micRate,
      numChannels: 1,
      echoCancel: voiceProcessing,
      noiseSuppress: voiceProcessing,
      autoGain: voiceProcessing,
      androidConfig: const AndroidRecordConfig(
        // Plain mic: on Samsung (and others) voiceCommunication yields near-silent input
        // unless the whole system is in call mode.
        audioSource: AndroidAudioSource.mic,
      ),
    ));
    _micSub = stream.listen((bytes) {
      // Chunks can split a sample; keep any odd trailing byte for next time.
      _carry.add(bytes);
      final all = _carry.takeBytes();
      final even = all.length & ~1;
      if (even > 0) {
        final copy = Uint8List.fromList(all.sublist(0, even));
        final samples = _decim.process(copy.buffer.asInt16List());
        if (samples.isNotEmpty) {
          micChunks++;
          micSamples += samples.length;
          for (final v in samples) {
            final a = v < 0 ? -v : v;
            if (a > micPeak) micPeak = a;
          }
          onPcm(samples);
        }
      }
      if (even < all.length) _carry.add(all.sublist(even));
    }, onError: (Object e) => micError = e);
  }

  Future<void> stopMic() async {
    await _micSub?.cancel();
    _micSub = null;
    _carry.clear();
    if (await _recorder.isRecording()) await _recorder.stop();
  }

  /// Plays one decoded Brew frame (480 samples = 60 ms).
  void play(Int16List pcm) {
    if (!_playerReady) return;
    // New talk spurt (or after an underrun): queue 60 ms of silence first so
    // network jitter between frames does not turn into clicks and gaps.
    final now = DateTime.now();
    if (now.difference(_lastPlay) > const Duration(milliseconds: 150)) {
      FlutterPcmSound.feed(PcmArrayInt16.fromList(Int16List(pcm.length)));
    }
    _lastPlay = now;
    FlutterPcmSound.feed(PcmArrayInt16.fromList(pcm));
  }

  Future<void> dispose() async {
    await stopMic();
    await _recorder.dispose();
    await FlutterPcmSound.release();
  }
}

/// 16 kHz -> 8 kHz: windowed-sinc low-pass (cut-off 3.4 kHz) then keep every
/// second sample. Streaming: carries filter history between chunks.
class _Decimator2 {
  static const _taps = 47;
  static const micGain = 0.6;
  /// Peak ceiling after the gain. Louder input is attenuated instead of being
  /// allowed to overdrive the ACELP encoder (harsh beeps on loud speech).
  static const _limit = 12000.0;
  /// Per-sample gain recovery after a peak (~100 ms at 8 kHz).
  static const _release = 0.0012;
  double _gain = 1.0;
  static final List<double> _h = _design();

  static List<double> _design() {
    const fc = 3400 / 16000; // cycles per input sample
    const m = (_taps - 1) / 2;
    final h = List<double>.generate(_taps, (n) {
      final x = n - m;
      final sinc = x == 0 ? 2 * fc : math.sin(2 * math.pi * fc * x) / (math.pi * x);
      final w = 0.54 - 0.46 * math.cos(2 * math.pi * n / (_taps - 1));
      return sinc * w;
    });
    final sum = h.fold<double>(0, (a, b) => a + b);
    // Unity DC gain, then micGain (-4 dB): phone mics run hot (peaks of 20000+) and a
    // near-clipping input makes the ACELP encoder produce harsh beeps.
    return [for (final v in h) v / sum * micGain];
  }

  List<double> _hist = List<double>.filled(_taps - 1, 0);
  int _count = 0;

  void reset() {
    _gain = 1.0;
    _hist = List<double>.filled(_taps - 1, 0);
    _count = 0;
  }

  Int16List process(Int16List input) {
    final n = input.length;
    final c = List<double>.filled(_taps - 1 + n, 0);
    for (var i = 0; i < _taps - 1; i++) {
      c[i] = _hist[i];
    }
    for (var i = 0; i < n; i++) {
      c[_taps - 1 + i] = input[i].toDouble();
    }
    final out = <int>[];
    for (var k = 0; k < n; k++) {
      if ((_count + k).isEven) {
        var y = 0.0;
        final base = _taps - 1 + k;
        for (var t = 0; t < _taps; t++) {
          y += _h[t] * c[base - t];
        }
        // Instant-attack limiter: pull the gain down to fit the peak, ease back up.
        final a = y.abs();
        final want = a * _gain > _limit ? _limit / a : 1.0;
        _gain = want < _gain ? want : _gain + (1.0 - _gain) * _release;
        out.add((y * _gain).round().clamp(-32768, 32767));
      }
    }
    _count += n;
    _hist = c.sublist(n);
    return Int16List.fromList(out);
  }
}
