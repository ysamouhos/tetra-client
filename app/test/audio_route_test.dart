import 'package:audio_session/audio_session.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetra_terminal/model/settings.dart';
import 'package:tetra_terminal/services/audio_io.dart';

class _Secrets implements SecretStore {
  final v = <String, String>{};
  @override
  Future<String?> read(String key) async => v[key];
  @override
  Future<void> write(String key, String value) async => v[key] = value;
  @override
  Future<void> delete(String key) async => v.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('loudspeaker mode forces the speaker, also when iOS fell back to the receiver', () {
    expect(iosOverride(speaker: true, outputs: [AVAudioSessionPort.builtInReceiver]), AVAudioSessionPortOverride.speaker);
    expect(iosOverride(speaker: true, outputs: [AVAudioSessionPort.builtInSpeaker]), AVAudioSessionPortOverride.speaker);
  });

  test('earpiece mode clears the override', () {
    expect(iosOverride(speaker: false, outputs: [AVAudioSessionPort.builtInSpeaker]), AVAudioSessionPortOverride.none);
  });

  test('a headset or Bluetooth device always wins', () {
    for (final port in [AVAudioSessionPort.headphones, AVAudioSessionPort.bluetoothHfp, AVAudioSessionPort.bluetoothA2dp, AVAudioSessionPort.carAudio]) {
      expect(iosOverride(speaker: true, outputs: [port]), AVAudioSessionPortOverride.none, reason: '$port');
    }
    expect(isHeadset(AndroidAudioDeviceType.bluetoothSco), isTrue);
    expect(isHeadset(AndroidAudioDeviceType.wiredHeadset), isTrue);
    expect(isHeadset(AndroidAudioDeviceType.builtInSpeaker), isFalse);
    expect(isHeadset(AndroidAudioDeviceType.builtInEarpiece), isFalse);
  });

  test('the choice is saved, loudspeaker by default', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = _Secrets();
    final s = Settings();
    expect(s.speakerOut, isTrue);
    s.speakerOut = false;
    await s.save();
    expect((await Settings.load()).speakerOut, isFalse);
  });
}
