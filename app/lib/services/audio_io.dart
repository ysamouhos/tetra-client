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

  /// Starts streaming microphone audio to [onPcm]. Echo cancellation is on
  /// so full-duplex calls do not feed the speaker back into the mic.
  Future<void> startMic(void Function(Int16List pcm) onPcm) async {
    if (_micSub != null) return;
    if (!await _recorder.hasPermission()) {
      throw StateError('Microphone permission denied');
    }
    final stream = await _recorder.startStream(const RecordConfig(
      encoder: AudioEncoder.pcm16bits,
      sampleRate: sampleRate,
      numChannels: 1,
      echoCancel: true,
      noiseSuppress: true,
      autoGain: true,
      androidConfig: AndroidRecordConfig(
        audioSource: AndroidAudioSource.voiceCommunication,
      ),
    ));
    _micSub = stream.listen((bytes) {
      // Chunks can split a sample; keep any odd trailing byte for next time.
      _carry.add(bytes);
      final all = _carry.takeBytes();
      final even = all.length & ~1;
      if (even > 0) {
        final copy = Uint8List.fromList(all.sublist(0, even));
        onPcm(copy.buffer.asInt16List());
      }
      if (even < all.length) _carry.add(all.sublist(even));
    });
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
    FlutterPcmSound.feed(PcmArrayInt16.fromList(pcm));
  }

  Future<void> dispose() async {
    await stopMic();
    await _recorder.dispose();
    await FlutterPcmSound.release();
  }
}
