import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetra_terminal/model/settings.dart';

void main() {
  test('settings persist and affiliate selected + scanned groups', () async {
    SharedPreferences.setMockInitialValues({});
    final s = Settings()
      ..issi = 2040001
      ..username = '2040001'
      ..serverUrl = 'https://brew.example.org/brew/'
      ..talkgroups = [Talkgroup(91, 'Ops'), Talkgroup(92, 'Spare', scan: false)]
      ..selectedGssi = 92;
    await s.save();
    final loaded = await Settings.load();
    expect(loaded.isConfigured, isTrue);
    expect(loaded.affiliatedGroups, [91, 92]);
    expect(loaded.talkgroups[1].scan, isFalse);
  });
}
