import 'dart:async';
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
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission denied');
    }
    final stream = await _recorder.startStream(RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
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
        final samples = copy.buffer.asInt16List();
        micChunks++;
        micSamples += samples.length;
        for (final v in samples) {
          final a = v < 0 ? -v : v;
          if (a > micPeak) micPeak = a;
        }
        onPcm(samples);
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
