import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Talkgroup {
  Talkgroup(this.gssi, this.name, {this.scan = true, this.mcc = 0, this.mnc = 0, this.dgna = false, this.dgnaMode = 0});
  final int gssi;
  String name;

  /// Scanned groups are affiliated, so their calls are heard. The selected
  /// group is always affiliated.
  bool scan;

  /// Multi Network: the group's network. 0/0 = the terminal's home network.
  int mcc;
  int mnc;
  bool get otherNetwork => mcc != 0 || mnc != 0;

  /// Given by the server per DGNA (Basestation mode); taken away the same way.
  bool dgna;

  /// SS-DGNA attachment mode as the server sent it, reported back unchanged.
  int dgnaMode;

  Map<String, dynamic> toJson() => {
        'gssi': gssi,
        'name': name,
        'scan': scan,
        if (otherNetwork) 'mcc': mcc,
        if (otherNetwork) 'mnc': mnc,
        if (dgna) 'dgna': true,
        if (dgna) 'dgnaMode': dgnaMode,
      };
  static Talkgroup fromJson(Map<String, dynamic> j) => Talkgroup(j['gssi'] as int, j['name'] as String,
      scan: j['scan'] as bool? ?? true, mcc: j['mcc'] as int? ?? 0, mnc: j['mnc'] as int? ?? 0, dgna: j['dgna'] as bool? ?? false, dgnaMode: j['dgnaMode'] as int? ?? 0);
}

/// Where passwords live: iOS Keychain / Android Keystore in the app, one
/// entry per connection profile. Replaceable in tests (the plugin has no test
/// implementation).
abstract class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class KeychainSecretStore implements SecretStore {
  final _storage = const FlutterSecureStorage();
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

/// One server login: where to connect, as whom, and that server's groups.
class ConnectionProfile {
  ConnectionProfile({
    required this.id,
    this.label = '',
    this.serverUrl = '',
    this.username = '',
    this.password = '',
    this.issi = 0,
    this.name = '',
    this.insecureTls = false,
    this.basestation = false,
    this.controlUrl = '',
    this.controlTls = false,
    this.controlUsername = '',
    this.controlPassword = '',
    this.homeMcc = 0,
    this.homeMnc = 0,
    this.externalPrefix = '',
    List<Talkgroup>? talkgroups,
    this.selectedGssi,
  }) : talkgroups = talkgroups ?? [];

  final String id;
  /// Shown in the list; empty = the server's host name.
  String label;
  String serverUrl;
  String username;
  /// Kept in the keychain, never in the preferences.
  String password;
  int issi;
  /// Talker name (SS-TPI mnemonic).
  String name;
  bool insecureTls;

  /// Log in as a Basestation (like FlowStation) instead of a Terminal. For a
  /// server whose operator lets this app in as a station.
  bool basestation;

  /// Basestation control channel (DGNA), only in Basestation mode: host or
  /// host:port, empty = the Brew host on port 9002.
  String controlUrl;
  bool controlTls;

  /// Login of `[control.users]`; empty = the Brew login.
  String controlUsername;

  /// Kept in the keychain; empty = the Brew password.
  String controlPassword;

  /// Multi Network (used only when the server offers `mni`): home network of
  /// this terminal. 0/0 = the server's own network.
  int homeMcc;
  int homeMnc;

  /// Digits the server's SIP route expects before an outside number (e.g. "9"). Empty = none.
  String externalPrefix;
  List<Talkgroup> talkgroups;
  int? selectedGssi;

  String get secretKey => 'brew.password.$id';
  String get controlSecretKey => 'brew.control.$id';

  String get displayName {
    if (label.trim().isNotEmpty) return label.trim();
    final host = Uri.tryParse(serverUrl.contains('://') ? serverUrl : 'http://$serverUrl')?.host ?? '';
    return host.isNotEmpty ? host : 'New connection';
  }

  bool get isConfigured => issi > 0 && serverUrl.isNotEmpty && username.isNotEmpty;

  ConnectionProfile copy({String? id}) => ConnectionProfile.fromJson(toJson(), id: id)
    ..password = password
    ..controlPassword = controlPassword;

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'serverUrl': serverUrl,
        'username': username,
        'issi': issi,
        'name': name,
        'insecureTls': insecureTls,
        'basestation': basestation,
        'controlUrl': controlUrl,
        'controlTls': controlTls,
        'controlUsername': controlUsername,
        'homeMcc': homeMcc,
        'homeMnc': homeMnc,
        'externalPrefix': externalPrefix,
        'talkgroups': talkgroups.map((t) => t.toJson()).toList(),
        'selectedGssi': selectedGssi,
      };

  static ConnectionProfile fromJson(Map<String, dynamic> j, {String? id}) => ConnectionProfile(
        id: id ?? j['id'] as String? ?? 'p1',
        label: j['label'] ?? '',
        serverUrl: j['serverUrl'] ?? '',
        username: j['username'] ?? '',
        issi: j['issi'] ?? 0,
        name: j['name'] ?? '',
        insecureTls: j['insecureTls'] ?? false,
        basestation: j['basestation'] ?? false,
        controlUrl: j['controlUrl'] ?? '',
        controlTls: j['controlTls'] ?? false,
        controlUsername: j['controlUsername'] ?? '',
        homeMcc: j['homeMcc'] ?? 0,
        homeMnc: j['homeMnc'] ?? 0,
        externalPrefix: j['externalPrefix'] ?? '',
        talkgroups: ((j['talkgroups'] as List?) ?? []).map((e) => Talkgroup.fromJson(e as Map<String, dynamic>)).toList(),
        selectedGssi: j['selectedGssi'],
      );
}

class Settings {
  /// Set by tests; the app uses the platform keychain.
  static SecretStore secrets = KeychainSecretStore();

  /// Connection profiles; [active] is the one in use.
  List<ConnectionProfile> profiles = [ConnectionProfile(id: 'p1', serverUrl: 'https://brew.example.org/brew')];
  String activeId = 'p1';
  ConnectionProfile get active => profiles.firstWhere((p) => p.id == activeId, orElse: () => profiles.first);

  // The active profile's fields (the rest of the app reads these).
  String get serverUrl => active.serverUrl;
  set serverUrl(String v) => active.serverUrl = v;
  String get username => active.username;
  set username(String v) => active.username = v;
  String get password => active.password;
  set password(String v) => active.password = v;
  int get issi => active.issi;
  set issi(int v) => active.issi = v;
  String get name => active.name;
  set name(String v) => active.name = v;
  bool get insecureTls => active.insecureTls;
  set insecureTls(bool v) => active.insecureTls = v;
  bool get basestation => active.basestation;
  int get homeMcc => active.homeMcc;
  set homeMcc(int v) => active.homeMcc = v;
  int get homeMnc => active.homeMnc;
  set homeMnc(int v) => active.homeMnc = v;
  String get externalPrefix => active.externalPrefix;
  set externalPrefix(String v) => active.externalPrefix = v;
  List<Talkgroup> get talkgroups => active.talkgroups;
  set talkgroups(List<Talkgroup> v) => active.talkgroups = v;
  int? get selectedGssi => active.selectedGssi;
  set selectedGssi(int? v) => active.selectedGssi = v;

  int defaultPriority = 1;
  bool allowPreemption = true;

  /// Microphone trim in dB on top of the built-in level (-12..+12).
  double micGainDb = 0;

  /// Keep running in the background (hear calls with the screen locked).
  bool backgroundAudio = true;

  /// Loudspeaker (true) or earpiece / phone mode (false); headsets always win.
  bool speakerOut = true;
  /// 'system', 'light' or 'dark'.
  String appearance = 'system';
  /// iOS: show the radio on the Lock Screen and in the Dynamic Island.
  bool liveActivity = true;
  /// PTT button: false = hold to talk, true = tap to start and tap to stop.
  bool pttToggle = false;
  /// Tap-to-talk (toggle mode and the Live Activity button) stops by itself
  /// after this many seconds; 0 = off.
  int pttAutoStopSeconds = 60;

  // LIP
  bool lipEnabled = false;
  int lipDestination = 0;
  int lipIntervalSeconds = 60;
  bool lipOnPtt = true;

  // Bluetooth PTT headset (Savox BTH-101)
  bool headsetEnabled = false;
  /// MAC like 00:15:BE:0F:12:26; empty = first paired "Savox…" device.
  String headsetAddress = '';

  bool get isConfigured => active.isConfigured;

  List<int> get affiliatedGroups => talkgroups.where((t) => t.scan || t.gssi == selectedGssi).map((t) => t.gssi).toList();

  /// Groups whose network differs from the home network.
  List<Talkgroup> get groupsOfOtherNetworks => talkgroups.where((t) => t.otherNetwork && !(t.mcc == homeMcc && t.mnc == homeMnc)).toList();

  /// A new, unused profile id.
  String newProfileId() {
    var n = profiles.length + 1;
    while (profiles.any((p) => p.id == 'p$n')) {
      n++;
    }
    return 'p$n';
  }

  /// Removes a profile and its password. The last profile stays.
  Future<void> removeProfile(ConnectionProfile p) async {
    if (profiles.length <= 1) return;
    profiles.remove(p);
    if (activeId == p.id) activeId = profiles.first.id;
    try {
      await secrets.delete(p.secretKey);
      await secrets.delete(p.controlSecretKey);
    } catch (_) {}
  }

  static const _key = 'settings.v1';

  static Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = Settings();
    final raw = prefs.getString(_key);
    if (raw == null) return s;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    s
      ..defaultPriority = j['defaultPriority'] ?? 1
      ..allowPreemption = j['allowPreemption'] ?? true
      ..micGainDb = (j['micGainDb'] as num?)?.toDouble() ?? 0
      ..backgroundAudio = j['backgroundAudio'] ?? true
      ..speakerOut = j['speakerOut'] ?? true
      ..appearance = j['appearance'] ?? 'system'
      ..liveActivity = j['liveActivity'] ?? true
      ..pttToggle = j['pttToggle'] ?? false
      ..pttAutoStopSeconds = j['pttAutoStopSeconds'] ?? 60
      ..lipEnabled = j['lipEnabled'] ?? false
      ..lipDestination = j['lipDestination'] ?? 0
      ..lipIntervalSeconds = j['lipIntervalSeconds'] ?? 60
      ..lipOnPtt = j['lipOnPtt'] ?? true
      ..headsetEnabled = j['headsetEnabled'] ?? false
      ..headsetAddress = j['headsetAddress'] ?? '';
    final list = j['profiles'] as List?;
    // Up to 1.3 there was one login stored flat; it becomes the first profile.
    s.profiles = list == null || list.isEmpty
        ? [ConnectionProfile.fromJson({...j, 'id': 'p1', 'serverUrl': j['serverUrl'] ?? 'https://brew.example.org/brew'})]
        : list.map((e) => ConnectionProfile.fromJson(e as Map<String, dynamic>)).toList();
    s.activeId = j['active'] as String? ?? s.profiles.first.id;
    // Passwords: keychain. Up to 1.3 the password sat in the preferences;
    // move it over once and drop it there.
    final legacy = j['password'] as String?;
    try {
      for (final p in s.profiles) {
        p.password = await secrets.read(p.secretKey) ?? '';
        p.controlPassword = await secrets.read(p.controlSecretKey) ?? '';
      }
      if (legacy != null && legacy.isNotEmpty) {
        s.profiles.first.password = legacy;
        await s.save(); // writes it to the keychain, drops it from the prefs
      }
    } catch (_) {
      s.profiles.first.password = legacy ?? '';
    }
    return s;
  }

  Future<void> save() async {
    final prefs = await SharedPreferences.getInstance();
    for (final p in profiles) {
      await secrets.write(p.secretKey, p.password);
      if (p.controlPassword.isEmpty) {
        await secrets.delete(p.controlSecretKey);
      } else {
        await secrets.write(p.controlSecretKey, p.controlPassword);
      }
    }
    await prefs.setString(
      _key,
      jsonEncode({
        'profiles': profiles.map((p) => p.toJson()).toList(),
        'active': activeId,
        'defaultPriority': defaultPriority,
        'allowPreemption': allowPreemption,
        'micGainDb': micGainDb,
        'backgroundAudio': backgroundAudio,
        'speakerOut': speakerOut,
        'appearance': appearance,
        'liveActivity': liveActivity,
        'pttToggle': pttToggle,
        'pttAutoStopSeconds': pttAutoStopSeconds,
        'lipEnabled': lipEnabled,
        'lipDestination': lipDestination,
        'lipIntervalSeconds': lipIntervalSeconds,
        'lipOnPtt': lipOnPtt,
        'headsetEnabled': headsetEnabled,
        'headsetAddress': headsetAddress,
      }),
    );
  }
}
