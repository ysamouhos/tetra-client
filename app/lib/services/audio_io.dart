import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:audio_session/audio_session.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:record/record.dart' hide IosAudioCategory;

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

  /// Microphone trim in dB (applies immediately, also mid-transmission).
  set micGainDb(double db) => _decim.setTrimDb(db);

  final _recorder = AudioRecorder();
  StreamSubscription<Uint8List>? _micSub;
  bool _playerReady = false;
  DateTime _lastPlay = DateTime.fromMillisecondsSinceEpoch(0);
  final _carry = BytesBuilder(copy: false);

  /// Loudspeaker (true) or earpiece, the "phone mode" (false). A headset or
  /// Bluetooth device always wins over both.
  bool speaker = true;
  AudioSession? _session;

  Future<void> init() async {
    // flutter_pcm_sound sets its own AVAudioSession category in setup(), so it
    // goes first and our configuration below wins. iosAllowBackgroundAudio is
    // essential: without it the plugin silently drops every frame fed while the
    // app is not active (screen locked or in the background).
    await FlutterPcmSound.setup(
      sampleRate: sampleRate,
      channelCount: 1,
      iosAudioCategory: IosAudioCategory.playAndRecord,
      iosAllowBackgroundAudio: true,
    );
    // iOS: one session for simultaneous mic + speaker (full-duplex calls), voice
    // processing (echo cancellation), loudspeaker by default, Bluetooth headsets
    // allowed. On Android this maps to voice-communication audio.
    final session = await AudioSession.instance;
    _session = session;
    await session.configure(_config());
    await session.setActive(true);
    // After a phone call or Siri the session is deactivated and the output unit
    // stopped. Reactivate and, in the background, restart the silence at once,
    // since iOS only lets an app keep (not start) audio there.
    session.interruptionEventStream.listen((e) async {
      if (e.begin) return;
      try {
        await session.setActive(true);
      } catch (_) {}
      await _applyRoute();
      if (_keepAlive != null) _feedSilenceIfLow();
    });
    // A plugin or the system can change the category or the route (headset
    // plugged in or out, another app): put the chosen output back. Our own
    // override is not answered, so this cannot loop.
    session.devicesChangedEventStream.listen((_) => _applyRoute());
    if (_isApple) {
      AVAudioSession().routeChangeStream.listen((c) {
        if (c.reason != AVAudioSessionRouteChangeReason.override) _applyRoute();
      });
    }
    await _applyRoute();
    // ~120 ms of headroom: two Brew frames of jitter.
    await FlutterPcmSound.setFeedThreshold(sampleRate ~/ 8);
    // The plugin reports how much is really queued; keeps our estimate honest.
    FlutterPcmSound.setFeedCallback((remaining) {
      _queue.sync(remaining);
      if (_keepAlive != null) _feedSilenceIfLow();
    });
    _playerReady = true;
  }

  static bool get _isApple => defaultTargetPlatform == TargetPlatform.iOS;

  /// iOS: one session for simultaneous mic + speaker (full-duplex calls),
  /// voice processing, Bluetooth headsets allowed; `defaultToSpeaker` only in
  /// loudspeaker mode. Android: voice-communication audio.
  AudioSessionConfiguration _config() => AudioSessionConfiguration(
        avAudioSessionCategory: AVAudioSessionCategory.playAndRecord,
        avAudioSessionCategoryOptions: (speaker ? AVAudioSessionCategoryOptions.defaultToSpeaker : AVAudioSessionCategoryOptions.none) |
            AVAudioSessionCategoryOptions.allowBluetooth |
            AVAudioSessionCategoryOptions.allowBluetoothA2dp,
        avAudioSessionMode: AVAudioSessionMode.voiceChat,
        androidAudioAttributes: const AndroidAudioAttributes(
          contentType: AndroidAudioContentType.speech,
          usage: AndroidAudioUsage.voiceCommunication,
        ),
        androidAudioFocusGainType: AndroidAudioFocusGainType.gainTransientMayDuck,
      );

  /// Switches between loudspeaker and earpiece at once (also mid-call).
  Future<void> setSpeaker(bool on) async {
    speaker = on;
    if (!_playerReady || _session == null) return;
    try {
      await _session!.configure(_config());
    } catch (_) {}
    await _applyRoute();
  }

  bool _routing = false;

  /// Puts the output where [speaker] says, unless a headset is connected.
  Future<void> _applyRoute() async {
    if (_session == null || _routing) return;
    _routing = true;
    try {
      if (_isApple) {
        final av = AVAudioSession();
        final outputs = (await av.currentRoute).outputs.map((o) => o.portType).toList();
        final o = iosOverride(speaker: speaker, outputs: outputs);
        if (o != null) await av.overrideOutputAudioPort(o);
      } else if (defaultTargetPlatform == TargetPlatform.android) {
        final am = AndroidAudioManager();
        final devices = await am.getDevices(AndroidGetAudioDevicesFlags.outputs);
        final headset = devices.any((d) => isHeadset(d.type));
        if (headset) {
          await am.setMode(AndroidAudioHardwareMode.normal);
          await am.setSpeakerphoneOn(false);
        } else if (speaker) {
          await am.setMode(AndroidAudioHardwareMode.normal);
          await am.setSpeakerphoneOn(true);
        } else {
          // Earpiece: communication mode with the speakerphone off.
          await am.setMode(AndroidAudioHardwareMode.inCommunication);
          await am.setSpeakerphoneOn(false);
        }
      }
    } catch (_) {
      // Routing is best effort; audio keeps playing on the current output.
    } finally {
      _routing = false;
    }
  }

  bool get micRunning => _micSub != null;

  /// Starts streaming microphone audio to [onPcm]. Echo cancellation is on
  /// so full-duplex calls do not feed the speaker back into the mic.
  ///
  /// [voiceProcessing] enables platform echo cancellation / noise suppression /
  /// AGC. Only full-duplex calls need it; in half-duplex PTT the speaker is
  /// silent while the mic is live, and the processing only distorts the signal
  /// the ACELP encoder sees (and on iOS contends with the playback engine).
  Future<void> startMic(void Function(Int16List pcm) onPcm, {bool voiceProcessing = false}) async {
    if (_micSub != null) return;
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
      // The session is ours (see init); letting the plugin reset it to its own
      // category drops voiceChat/defaultToSpeaker and can stop background audio.
      iosConfig: const IosRecordConfig(manageAudioSession: false),
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
        if (samples.isNotEmpty) onPcm(samples);
      }
      if (even < all.length) _carry.add(all.sublist(even));
    });
    await _applyRoute();
  }

  Future<void> stopMic() async {
    await _micSub?.cancel();
    _micSub = null;
    _carry.clear();
    if (await _recorder.isRecording()) await _recorder.stop();
    await _applyRoute();
  }

  final _queue = PlayoutQueue(sampleRate);

  void _feed(Int16List pcm) {
    _queue.fed(pcm.length);
    FlutterPcmSound.feed(PcmArrayInt16.fromList(pcm));
  }

  /// Plays one decoded Brew frame (480 samples = 60 ms).
  void play(Int16List pcm) {
    if (!_playerReady) return;
    // New talk spurt (or after an underrun): queue 60 ms of silence first so
    // network jitter between frames does not turn into clicks and gaps. Not
    // needed when keep-alive silence is still queued ahead of the frame.
    final now = DateTime.now();
    if (now.difference(_lastPlay) > const Duration(milliseconds: 150) && _queue.queuedSamples() < pcm.length) {
      _feed(Int16List(pcm.length));
    }
    _lastPlay = now;
    _feed(pcm);
  }

  Timer? _keepAlive;

  void _feedSilenceIfLow() {
    if (!_playerReady) return;
    if (DateTime.now().difference(_lastPlay) < const Duration(milliseconds: 300)) return; // a call is playing
    final n = _queue.silenceToFeed();
    if (n > 0) _feed(Int16List(n));
  }

  /// Background operation on iOS: the app may keep running in the background
  /// (UIBackgroundModes `audio`) only while its audio session plays, and iOS
  /// refuses to *start* playback once the app is in the background. So silence
  /// must already be flowing when the app leaves the foreground: the model
  /// turns this on as soon as the app becomes inactive, and the first block is
  /// fed right away. Afterwards a short queue of silence is topped up (timer
  /// plus the plugin's low-buffer callback) so the output unit never runs dry;
  /// calls then play as usual. Costs some battery.
  void keepAlive(bool on) {
    if (on && _keepAlive != null) return;
    _keepAlive?.cancel();
    _keepAlive = null;
    if (!on || !_playerReady) return;
    _keepAlive = Timer.periodic(const Duration(milliseconds: 100), (_) => _feedSilenceIfLow());
    _feedSilenceIfLow();
  }

  Future<void> dispose() async {
    keepAlive(false);
    await stopMic();
    await _recorder.dispose();
    await FlutterPcmSound.release();
  }
}

/// Output ports that are a headset or another external device: they always
/// win over the loudspeaker / earpiece choice.
const _externalPorts = {
  AVAudioSessionPort.headphones,
  AVAudioSessionPort.bluetoothA2dp,
  AVAudioSessionPort.bluetoothHfp,
  AVAudioSessionPort.bluetoothLe,
  AVAudioSessionPort.carAudio,
  AVAudioSessionPort.usbAudio,
  AVAudioSessionPort.airPlay,
  AVAudioSessionPort.lineOut,
  AVAudioSessionPort.hdmi,
};

/// iOS output override for the current route: force the loudspeaker in
/// loudspeaker mode (even if iOS fell back to the receiver), none in earpiece
/// mode, and leave an external device alone (`null`: nothing to do).
AVAudioSessionPortOverride? iosOverride({required bool speaker, required List<AVAudioSessionPort?> outputs}) {
  if (outputs.any(_externalPorts.contains)) return AVAudioSessionPortOverride.none;
  return speaker ? AVAudioSessionPortOverride.speaker : AVAudioSessionPortOverride.none;
}

/// Android device types that count as a headset (they win over the choice).
bool isHeadset(AndroidAudioDeviceType t) => const {
      AndroidAudioDeviceType.wiredHeadset,
      AndroidAudioDeviceType.wiredHeadphones,
      AndroidAudioDeviceType.bluetoothSco,
      AndroidAudioDeviceType.bluetoothA2dp,
      AndroidAudioDeviceType.usbHeadset,
      AndroidAudioDeviceType.hearingAid,
    }.contains(t);

/// Estimates how much audio is still queued in the player, so keep-alive
/// silence keeps it from running dry (on iOS the output unit stops when empty
/// and cannot be restarted in the background) without piling up latency in
/// front of the next call. Corrected by the plugin's remaining-frames reports.
class PlayoutQueue {
  PlayoutQueue(this.rate, {DateTime Function()? clock}) : _clock = clock ?? DateTime.now;
  final int rate;
  final DateTime Function() _clock;
  DateTime _until = DateTime.fromMillisecondsSinceEpoch(0);

  /// Top up when less than this is queued...
  int get lowWater => rate * 15 ~/ 100; // 150 ms
  /// ...with this much silence (keeps the queue, and call latency, under ~400 ms).
  int get block => rate * 25 ~/ 100; // 250 ms

  Duration _dur(int samples) => Duration(microseconds: samples * 1000000 ~/ rate);

  void fed(int samples) {
    final now = _clock();
    _until = (_until.isAfter(now) ? _until : now).add(_dur(samples));
  }

  void sync(int remainingSamples) => _until = _clock().add(_dur(remainingSamples));

  int queuedSamples() {
    final left = _until.difference(_clock());
    return left.isNegative ? 0 : left.inMicroseconds * rate ~/ 1000000;
  }

  /// Samples of silence to feed now (0 = enough queued).
  int silenceToFeed() => queuedSamples() < lowWater ? block : 0;
}

/// 16 kHz -> 8 kHz: windowed-sinc low-pass (cut-off 3.4 kHz) then keep every
/// second sample. Streaming: carries filter history between chunks.
class _Decimator2 {
  static const _taps = 47;
  /// Built-in level (-4.4 dB); the user's trim is applied on top.
  static const _baseGain = 0.6;
  double gain = _baseGain;

  void setTrimDb(double db) => gain = _baseGain * math.pow(10, db / 20).toDouble();
  final _lim = _Limiter();
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
    // Unity DC gain; level is applied in [process] (phone mics run hot, and a
    // near-clipping input makes the ACELP encoder produce harsh beeps).
    return [for (final v in h) v / sum];
  }

  List<double> _hist = List<double>.filled(_taps - 1, 0);
  int _count = 0;

  void reset() {
    _lim.reset();
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
        out.add(_lim.process(y * gain).round().clamp(-32768, 32767));
      }
    }
    _count += n;
    _hist = c.sublist(n);
    return Int16List.fromList(out);
  }
}

/// Look-ahead peak limiter. Louder input is attenuated instead of being allowed
/// to overdrive the ACELP encoder (harsh beeps on loud speech). The gain ramps
/// down smoothly *before* a peak (the signal is delayed by [_look] samples), so
/// limiting adds no clicks, and recovers slowly (~100 ms) so sustained loud
/// speech is not amplitude-modulated.
class _Limiter {
  static const _look = 16; // 2 ms at 8 kHz
  static const _limit = 12000.0;
  static const _release = 0.0012;

  // growable: we shift these (removeAt/add) every sample; filled() is fixed-length by default.
  final List<double> _g = List<double>.filled(2 * _look + 1, 1.0, growable: true); // wanted gains, oldest first
  final List<double> _x = List<double>.filled(_look + 1, 0.0, growable: true); // delayed signal
  double _r = 1.0;

  void reset() {
    _g.fillRange(0, _g.length, 1.0);
    _x.fillRange(0, _x.length, 0.0);
    _r = 1.0;
  }

  double process(double x) {
    _g.removeAt(0);
    final a = x.abs();
    _g.add(a > _limit ? _limit / a : 1.0);
    _x.removeAt(0);
    _x.add(x);
    // Sliding minimum over the look-ahead window, averaged over the same length:
    // guarantees the smoothed gain is <= the wanted gain at every sample.
    var sum = 0.0;
    for (var p = 0; p <= _look; p++) {
      var m = 1.0;
      for (var q = p; q <= p + _look; q++) {
        if (_g[q] < m) m = _g[q];
      }
      sum += m;
    }
    final smooth = sum / (_look + 1);
    final recovering = _r + (1.0 - _r) * _release;
    _r = smooth < recovering ? smooth : recovering;
    return _x[0] * _r;
  }
}
