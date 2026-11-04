import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

class Talkgroup {
  Talkgroup(this.gssi, this.name, {this.scan = true});
  final int gssi;
  String name;

  /// Scanned groups are affiliated, so their calls are heard. The selected
  /// group is always affiliated.
  bool scan;

  Map<String, dynamic> toJson() => {'gssi': gssi, 'name': name, 'scan': scan};
  static Talkgroup fromJson(Map<String, dynamic> j) => Talkgroup(j['gssi'] as int, j['name'] as String, scan: j['scan'] as bool? ?? true);
}

class Settings {
  String serverUrl = 'https://brew.example.org/brew';
  String username = '';
  String password = '';
  int issi = 0;
  String name = '';
  int defaultPriority = 1;
  bool allowPreemption = true;
  bool insecureTls = false;

  /// Microphone trim in dB on top of the built-in level (-12..+12).
  double micGainDb = 0;

  /// Digits the server's SIP route expects before an outside number (e.g. "9"). Empty = none.
  String externalPrefix = '';
  List<Talkgroup> talkgroups = [];
  int? selectedGssi;

  // LIP
  bool lipEnabled = false;
  int lipDestination = 0;
  int lipIntervalSeconds = 60;
  bool lipOnPtt = true;

  bool get isConfigured => issi > 0 && serverUrl.isNotEmpty && username.isNotEmpty;

  List<int> get affiliatedGroups => talkgroups.where((t) => t.scan || t.gssi == selectedGssi).map((t) => t.gssi).toList();

  static const _key = 'settings.v1';

  static Future<Settings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final s = Settings();
    final raw = prefs.getString(_key);
    if (raw == null) return s;
    final j = jsonDecode(raw) as Map<String, dynamic>;
    s
      ..serverUrl = j['serverUrl'] ?? s.serverUrl
      ..username = j['username'] ?? ''
      ..password = j['password'] ?? ''
      ..issi = j['issi'] ?? 0
      ..name = j['name'] ?? ''
      ..defaultPriority = j['defaultPriority'] ?? 1
      ..allowPreemption = j['allowPreemption'] ?? true
      ..insecureTls = j['insecureTls'] ?? false
      ..micGainDb = (j['micGainDb'] as num?)?.toDouble() ?? 0
      ..externalPrefix = j['externalPrefix'] ?? ''
      ..talkgroups = ((j['talkgroups'] as List?) ?? []).map((e) => Talkgroup.fromJson(e as Map<String, dynamic>)).toList()
      ..selectedGssi = j['selectedGssi']
      ..lipEnabled = j['lipEnabled'] ?? false
      ..lipDestination = j['lipDestination'] ?? 0
      ..lipIntervalSeconds = j['lipIntervalSeconds'] ?? 60
      ..lipOnPtt = j['lipOnPtt'] ?? true;
    return s;
  }

  Future<void> save() async {
    // NOTE: for production store the password with flutter_secure_storage.
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
      _key,
      jsonEncode({
        'serverUrl': serverUrl,
        'username': username,
        'password': password,
        'issi': issi,
        'name': name,
        'defaultPriority': defaultPriority,
        'allowPreemption': allowPreemption,
        'insecureTls': insecureTls,
        'micGainDb': micGainDb,
        'externalPrefix': externalPrefix,
        'talkgroups': talkgroups.map((t) => t.toJson()).toList(),
        'selectedGssi': selectedGssi,
        'lipEnabled': lipEnabled,
        'lipDestination': lipDestination,
        'lipIntervalSeconds': lipIntervalSeconds,
        'lipOnPtt': lipOnPtt,
      }),
    );
  }
}
