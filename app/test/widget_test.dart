import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetra_terminal/model/settings.dart';
import 'package:tetra_terminal/model/terminal_model.dart';
import 'package:tetra_terminal/src/rust/api.dart';

class MemorySecrets implements SecretStore {
  final values = <String, String>{};
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async => values[key] = value;
  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // The audio plugin has no test implementation.
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.llfbandit.record/messages'), (_) async => null);
  test('settings persist and affiliate selected + scanned groups', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = MemorySecrets();
    final s = Settings()
      ..issi = 2040001
      ..username = '2040001'
      ..serverUrl = 'https://brew.example.org/brew/'
      ..talkgroups = [Talkgroup(91, 'Ops'), Talkgroup(92, 'Spare', scan: false)]
      ..selectedGssi = 92
      ..appearance = 'dark';
    await s.save();
    final loaded = await Settings.load();
    expect(loaded.isConfigured, isTrue);
    expect(loaded.affiliatedGroups, [91, 92]);
    expect(loaded.talkgroups[1].scan, isFalse);
    expect(loaded.appearance, 'dark');
  });

  test('password lives in the keychain, and an old stored one moves there', () async {
    final secrets = MemorySecrets();
    Settings.secrets = secrets;
    SharedPreferences.setMockInitialValues({'settings.v1': '{"username":"2040001","issi":2040001,"password":"old"}'});
    final loaded = await Settings.load();
    expect(loaded.password, 'old');
    expect(secrets.values['brew.password.p1'], 'old');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings.v1'), isNot(contains('old')));
    loaded.password = 'new';
    await loaded.save();
    expect(secrets.values['brew.password.p1'], 'new');
    expect(prefs.getString('settings.v1'), isNot(contains('new')));
  });

  test('several connection profiles, each with its own password and groups', () async {
    final secrets = MemorySecrets();
    Settings.secrets = secrets;
    SharedPreferences.setMockInitialValues({});
    final s = Settings()
      ..serverUrl = 'https://a.example.org/brew/'
      ..password = 'pa'
      ..talkgroups = [Talkgroup(91, 'Ops')];
    final b = ConnectionProfile(id: s.newProfileId(), label: 'Lab', serverUrl: 'https://b.example.org/brew/', password: 'pb', issi: 7);
    expect(b.id, 'p2');
    s.profiles.add(b);
    s.activeId = b.id;
    await s.save();
    expect(secrets.values, {'brew.password.p1': 'pa', 'brew.password.p2': 'pb'});

    final loaded = await Settings.load();
    expect(loaded.profiles.map((p) => p.displayName), ['a.example.org', 'Lab']);
    expect(loaded.activeId, 'p2');
    expect(loaded.serverUrl, 'https://b.example.org/brew/', reason: 'getters follow the active profile');
    expect(loaded.password, 'pb');
    expect(loaded.talkgroups, isEmpty);
    loaded.activeId = 'p1';
    expect(loaded.talkgroups.single.gssi, 91);

    await loaded.removeProfile(loaded.profiles.last);
    expect(loaded.profiles.length, 1);
    expect(secrets.values.keys, ['brew.password.p1'], reason: 'removing a profile deletes its password');
    await loaded.removeProfile(loaded.profiles.single);
    expect(loaded.profiles.length, 1, reason: 'the last profile stays');
  });

  test('login mode is per connection, Terminal unless set', () async {
    Settings.secrets = MemorySecrets();
    SharedPreferences.setMockInitialValues({});
    final s = Settings();
    expect(s.basestation, isFalse, reason: 'Terminal stays the default (TetraPack)');
    final own = s.active.copy(id: 'p2')..basestation = true;
    s.profiles.add(own);
    await s.save();
    final loaded = await Settings.load();
    expect(loaded.profiles.firstWhere((p) => p.id == 'p1').basestation, isFalse);
    expect(loaded.profiles.firstWhere((p) => p.id == 'p2').basestation, isTrue);
    loaded.activeId = 'p2';
    expect(loaded.basestation, isTrue);
    // A profile saved before the option existed logs in as a Terminal.
    expect(ConnectionProfile.fromJson({'id': 'old', 'serverUrl': 'x'}).basestation, isFalse);
  });

  test('groups of other networks and the home network', () async {
    SharedPreferences.setMockInitialValues({});
    Settings.secrets = MemorySecrets();
    final s = Settings()
      ..homeMcc = 901
      ..homeMnc = 1638
      ..talkgroups = [Talkgroup(91, 'Ops'), Talkgroup(2324, 'TP', mcc: 901, mnc: 9999), Talkgroup(9, 'Home', mcc: 901, mnc: 1638)];
    await s.save();
    final loaded = await Settings.load();
    expect((loaded.homeMcc, loaded.homeMnc), (901, 1638));
    expect(loaded.groupsOfOtherNetworks.map((t) => t.gssi), [2324], reason: '91 has no network, 9 is in the home network');
  });

  test('status for the Live Activity and the widget', () {
    final m = TerminalModel(Settings()
      ..talkgroups = [Talkgroup(91, 'Austria'), Talkgroup(9, 'Vienna')]
      ..selectedGssi = 91)
      ..link = LinkState.online;
    var s = m.liveStatus();
    expect(s['group'], 'Austria');
    expect(s['talker'], isNull);
    expect(s['online'], isTrue);
    expect(s['live'], isFalse, reason: 'not connected by the user yet');

    final since = DateTime(2026, 11, 25, 10, 0, 0);
    m.groupActivity[9] = GroupCallState(9, 2320972, 'OE1ABC', 15, 'c1', since: since);
    s = m.liveStatus();
    expect(s['group'], 'Vienna', reason: 'a scanned group that is talking wins');
    expect(s['talker'], 'OE1ABC');
    expect(s['talkerSince'], since.millisecondsSinceEpoch);
    expect(s['emergency'], isTrue);

    m.groupActivity.clear();
    m.myTxCallId = 'me';
    m.myTxSince = since;
    s = m.liveStatus();
    expect((s['talker'], s['transmitting'], s['group']), ('You', true, 'Austria'));
    expect(s['lastTalker'], 'OE1ABC', reason: 'the widget shows who spoke last');
  });

  test('group access: verdicts and managed talkgroups', () {
    var (groups, listed) = parseGroupAccess('{"groups":[{"gssi":2321,"access":"refused"},{"gssi":9,"access":"listen"},{"gssi":7,"access":"odd"}]}');
    expect(groups, {2321: GroupAccess.refused, 9: GroupAccess.listen});
    expect(listed, isNull);
    final m = TerminalModel(Settings()
      ..talkgroups = [Talkgroup(9, 'Vienna'), Talkgroup(91, 'Austria'), Talkgroup(2324, 'TP', mcc: 901, mnc: 1638)]
      ..selectedGssi = 9);
    m.groupAccess = groups;
    expect(m.mayTalkOnSelected, isFalse, reason: '9 is listen only');
    m.settings.selectedGssi = 91;
    expect(m.mayTalkOnSelected, isTrue);
    (groups, listed) = parseGroupAccess('{"groups":[],"managed":true,"listed":[9]}');
    m
      ..groupAccess = groups
      ..managedGroups = listed;
    expect(m.accessOf(m.settings.talkgroups[1]), GroupAccess.refused, reason: 'not listed');
    expect(m.accessOf(m.settings.talkgroups[2]), GroupAccess.open, reason: 'groups of another network are not checked');
    expect(parseGroupAccess('garbage').$1, isEmpty);
  });

  test('SERVICE_NETWORKS is parsed with the server first', () {
    final n = parseNetworks('{"this":{"mcc":901,"mnc":9999},"networks":[{"mcc":901,"mnc":1638,"name":"TetraPack","up":true}]}');
    expect(n.map((x) => x.name), ['This server', 'TetraPack']);
    expect(n.first.own, isTrue);
    expect(n.last.up, isTrue);
    expect(parseNetworks('garbage'), isEmpty);
  });

  test('Live Activity standby line and tap-to-talk', () async {
    final m = TerminalModel(Settings()
      ..issi = 2320001
      ..name = 'OE1XYZ'
      ..talkgroups = [Talkgroup(91, 'Austria')]
      ..selectedGssi = 91
      ..pttAutoStopSeconds = 30);
    var s = m.liveStatus();
    expect((s['ownName'], s['ownIssi']), ('OE1XYZ', 2320001));
    expect(s['canTalk'], isFalse, reason: 'offline');
    m.togglePtt();
    expect(m.latchedTxEndsAt, isNull, reason: 'no key-up while offline');

    m.link = LinkState.online;
    expect(m.liveStatus()['canTalk'], isTrue);
    m.togglePtt();
    expect(m.latchedTxEndsAt, isNotNull);
    expect(m.latchedTxEndsAt!.difference(DateTime.now()).inSeconds, inInclusiveRange(29, 30));
    expect(m.liveStatus()['txEndsAt'], m.latchedTxEndsAt!.millisecondsSinceEpoch);
    m.togglePtt(); // second tap releases
    expect(m.latchedTxEndsAt, isNull);

    m.settings.pttAutoStopSeconds = 0;
    m.togglePtt();
    expect(m.latchedTxEndsAt, isNull, reason: 'auto-stop off');
    m.handleEvent(const AppEvent.txGranted(callId: 'c9'));
    expect(m.transmitting, isTrue);
    m.togglePtt();
    m.handleEvent(const AppEvent.txEnded(callId: 'c9', preempted: false));
    expect(m.transmitting, isFalse);
  });

  test('tap-to-talk auto-stop is saved', () async {
    final s = Settings()
      ..pttAutoStopSeconds = 120
      ..pttToggle = true;
    await s.save();
    final l = await Settings.load();
    expect((l.pttAutoStopSeconds, l.pttToggle), (120, true));
  });

  test('DGNA adds and removes only its own groups, and survives a restart', () async {
    SharedPreferences.setMockInitialValues({});
    final secrets = MemorySecrets();
    Settings.secrets = secrets;
    final m = TerminalModel(Settings()
      ..issi = 2320997
      ..talkgroups = [Talkgroup(91, 'Austria'), Talkgroup(92, 'Mine', scan: false)]
      ..selectedGssi = 91);
    await m.applyDgna(2329, 'Event', 1, attach: true);
    final event = m.settings.talkgroups.firstWhere((t) => t.gssi == 2329);
    expect((event.name, event.dgna, event.dgnaMode), ('Event', true, 1));
    expect(m.settings.affiliatedGroups, containsAll([91, 2329]), reason: 'a DGNA group is affiliated');

    await m.applyDgna(92, 'Other', 0, attach: true);
    final mine = m.settings.talkgroups.firstWhere((t) => t.gssi == 92);
    expect((mine.name, mine.dgna, mine.scan), ('Mine', false, true), reason: 'the user\'s own group stays theirs, now scanned');
    await m.applyDgna(92, null, 0, attach: false);
    expect(m.settings.talkgroups.any((t) => t.gssi == 92), isTrue, reason: 'not taken by a deassign');

    final p = m.settings.active
      ..basestation = true
      ..controlUrl = 'ctl.example.org:9443'
      ..controlTls = true
      ..controlUsername = 'app1'
      ..controlPassword = 'secret';
    await m.settings.save();
    expect(secrets.values[p.controlSecretKey], 'secret');
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('settings.v1'), isNot(contains('secret')));
    final l = await Settings.load();
    final lp = l.active;
    expect((lp.controlUrl, lp.controlTls, lp.controlUsername, lp.controlPassword), ('ctl.example.org:9443', true, 'app1', 'secret'));
    expect(l.talkgroups.firstWhere((t) => t.gssi == 2329).dgna, isTrue);

    await m.applyDgna(2329, null, 0, attach: false);
    expect(m.settings.talkgroups.any((t) => t.gssi == 2329), isFalse);
    expect(m.settings.affiliatedGroups, isNot(contains(2329)));
  });
}
