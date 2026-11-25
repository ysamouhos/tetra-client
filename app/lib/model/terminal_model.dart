import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/audio_io.dart';
import '../services/live_status.dart';
import '../services/location_service.dart';
import '../services/ptt_input.dart';
import '../src/rust/api.dart';
import 'contacts.dart';
import 'settings.dart';

enum LinkState { offline, connecting, online }

class GroupCallState {
  GroupCallState(this.gssi, this.talker, this.talkerName, this.priority, this.callId, {DateTime? since}) : since = since ?? DateTime.now();
  final int gssi;
  /// When the talker started (for the "talking for 0:12" timer).
  final DateTime since;
  final int talker;
  final String? talkerName;
  final int priority;
  final String callId;
  bool get emergency => priority >= 15;
}

/// What the server lets this terminal do on a group (`group-access`).
enum GroupAccess { open, listen, refused }

enum MsgStatus { sending, sent, networkAccepted, delivered, failed, received }

class ChatMessage {
  ChatMessage({required this.peer, required this.outgoing, required this.text, required this.status, this.localId, this.immediate = false})
      : time = DateTime.now();
  final int peer; // ISSI or GSSI of the conversation
  final bool outgoing;
  final String text;
  final bool immediate;
  final int? localId;
  MsgStatus status;
  final DateTime time;
}

/// A network the server links to (Multi Network, `SERVICE_NETWORKS`).
class LinkedNetwork {
  const LinkedNetwork(this.mcc, this.mnc, this.name, {this.up = true, this.own = false});
  final int mcc;
  final int mnc;
  final String name;
  final bool up;
  /// The server's own network.
  final bool own;
  String get mni => '$mcc-$mnc';
}

class RemoteLocation {
  RemoteLocation(this.issi, this.location, this.reason) : time = DateTime.now();
  final int issi;
  final LocationInfo location;
  final int? reason;
  final DateTime time;
}

/// App-wide state over the Rust `TetraClient`.
class TerminalModel extends ChangeNotifier with WidgetsBindingObserver {
  TerminalModel(this.settings);

  Settings settings;
  final audio = AudioIO();
  final live = LiveStatus();
  final contacts = ContactBook();
  final callLog = CallLog();
  /// Open call log entries by call id, to set the duration when they end.
  final Map<String, CallLogEntry> _openLog = {};
  DateTime? _privateConnectedAt;

  /// Name to show for an ISSI (own contact, name sent by the radio, RadioID).
  String nameOf(int issi, {String? sentName}) => contacts.display(issi, sentName: sentName);
  late final location = LocationService((loc, reason) => _client?.sendLocation(to: settings.lipDestination, location: loc, reason: reason));

  TetraClient? _client;

  /// Basestation control channel (Basestation login mode only): DGNA.
  TetraControl? _control;
  bool controlOnline = false;
  String? controlError;
  LinkState link = LinkState.offline;
  String? lastError;

  /// The user wants to be online (connected and not disconnected by hand).
  bool _wantOnline = false;

  /// Brew extensions the server offered on the current connection.
  List<String> extensions = const [];
  bool get multiNetwork => extensions.contains('mni');

  /// Group access from the server (`group-access`): groups that are not open
  /// to us, and with managed talkgroups the listed ones (null = not managed).
  Map<int, GroupAccess> groupAccess = const {};
  Set<int>? managedGroups;

  GroupAccess accessOf(Talkgroup t) {
    final a = groupAccess[t.gssi];
    if (a != null) return a;
    // Managed talkgroups: groups of another network are not checked against the list.
    if (managedGroups != null && !t.otherNetwork && !managedGroups!.contains(t.gssi)) return GroupAccess.refused;
    return GroupAccess.open;
  }

  /// May we talk on the selected group (PTT)? Emergency calls always pass.
  bool get mayTalkOnSelected {
    final t = settings.talkgroups.where((t) => t.gssi == settings.selectedGssi).firstOrNull;
    return t == null || accessOf(t) == GroupAccess.open;
  }

  /// Multi Network: the server's own network first, then the linked ones.
  List<LinkedNetwork> networks = const [];

  String networkName(int mcc, int mnc) {
    if (mcc == 0 && mnc == 0) return 'Home network';
    return networks.where((n) => n.mcc == mcc && n.mnc == mnc).firstOrNull?.name ?? '$mcc-$mnc';
  }

  /// Active transmissions per talkgroup.
  final Map<int, GroupCallState> groupActivity = {};
  String? myTxCallId;
  DateTime? myTxSince;
  PrivateCallInfo? privateCall;
  String? focusCallId;
  final List<ChatMessage> messages = [];
  final Map<int, RemoteLocation> locations = {};
  int _nextLocalId = 1;
  String? toast;

  PttInput? _pttInput;
  StreamSubscription<PttInputEvent>? _pttSub;
  /// Hardware PTT device status for the UI (null = none configured).
  String? pttDeviceStatus;
  bool pttDeviceConnected = false;
  int? _headsetVolume;
  bool _swallowRelease = false;

  bool get transmitting => myTxCallId != null;

  @override
  void notifyListeners() {
    super.notifyListeners();
    // The widget always gets the status; the Live Activity runs while `live`.
    live.update(liveStatus());
  }

  String? _lastTalker;
  DateTime? _lastTalkerAt;

  /// What the Live Activity and the home screen widget show. Times are
  /// milliseconds since the epoch; `live` says whether the Live Activity runs.
  Map<String, Object?> liveStatus() {
    final selected = settings.talkgroups.where((t) => t.gssi == settings.selectedGssi).firstOrNull;
    final call = transmitting
        ? null
        : heard ?? groupActivity[settings.selectedGssi] ?? groupActivity.values.firstOrNull;
    final talker = transmitting ? 'You' : (call == null ? null : nameOf(call.talker, sentName: call.talkerName));
    final since = transmitting ? myTxSince : call?.since;
    if (talker != null && !transmitting) {
      _lastTalker = talker;
      _lastTalkerAt = since;
    }
    return {
      'live': _wantOnline && settings.liveActivity,
      'online': link == LinkState.online,
      'profile': settings.active.displayName,
      'server': settings.active.displayName,
      'group': call != null ? _groupName(call.gssi) : (selected?.name ?? (settings.selectedGssi != null ? 'TG ${settings.selectedGssi}' : 'No talkgroup')),
      'talker': talker,
      'talkerSince': talker == null ? null : since?.millisecondsSinceEpoch,
      'transmitting': transmitting,
      'emergency': call?.emergency ?? false,
      'lastTalker': _lastTalker,
      'lastTalkerAt': _lastTalkerAt?.millisecondsSinceEpoch,
      'ownName': settings.name.trim().isEmpty ? null : settings.name.trim(),
      'ownIssi': settings.issi > 0 ? settings.issi : null,
      'canTalk': link == LinkState.online && (privateCall != null || (settings.selectedGssi != null && mayTalkOnSelected)),
      'txEndsAt': latchedTxEndsAt?.millisecondsSinceEpoch,
    };
  }
  int? get selectedGssi => settings.selectedGssi;

  /// The talker currently heard, for the status banner.
  GroupCallState? get heard => groupActivity.values.where((g) => g.callId == focusCallId).firstOrNull;

  Future<void> start() async {
    WidgetsBinding.instance.addObserver(this);
    live.onTogglePtt(togglePtt);
    // Android 13+: the ongoing notification needs the notification permission.
    if (!kIsWeb && Platform.isAndroid && settings.liveActivity) unawaited(Permission.notification.request());
    contacts.addListener(notifyListeners);
    await contacts.load();
    await callLog.load();
    unawaited(contacts.startRadioId());
    audio.speaker = settings.speakerOut;
    await audio.init();
    audio.micGainDb = settings.micGainDb;
    await _startPttInput();
    if (settings.isConfigured) await connect();
  }

  Future<void> _startPttInput() async {
    await _stopPttInput();
    if (!settings.headsetEnabled) return;
    final input = BluetoothHeadsetPtt(address: settings.headsetAddress);
    _pttInput = input;
    pttDeviceStatus = 'Headset connecting…';
    _pttSub = input.events.listen(_onPttInput);
    await input.start();
    notifyListeners();
  }

  Future<void> _stopPttInput() async {
    await _pttSub?.cancel();
    _pttSub = null;
    final input = _pttInput;
    _pttInput = null;
    if (input != null) {
      await input.stop();
      if (transmitting || _releaseTimer != null) pttUp();
    }
    pttDeviceStatus = null;
    pttDeviceConnected = false;
  }

  void _onPttInput(PttInputEvent e) {
    switch (e) {
      case PttPressed():
        if (link != LinkState.online) return;
        // Ringing incoming call: the press answers it instead of keying up.
        if (privateCall?.state == 'ringing') {
          _swallowRelease = true;
          answer();
          return;
        }
        pttDown();
        return;
      case PttReleased():
        if (_swallowRelease) {
          _swallowRelease = false;
          return;
        }
        pttUp();
        return;
      case PttVolume(:final level, :final max):
        if (_headsetVolume != null && _headsetVolume != level) toast = 'Volume $level/$max';
        _headsetVolume = level;
      case PttDeviceStatus(:final connected, :final text):
        // Announce changes, not every retry.
        if (connected != pttDeviceConnected) toast = text;
        pttDeviceConnected = connected;
        pttDeviceStatus = text;
    }
    notifyListeners();
  }

  /// iOS suspends the app in the background unless audio keeps it alive; the
  /// socket then dies quietly. In the background we keep the audio session
  /// playing (if enabled); back in front we reconnect if the link was lost.
  /// When the app is closed for good: deregister.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        audio.keepAlive(false);
        if (_wantOnline && link == LinkState.offline && settings.isConfigured) connect();
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        // Stay reachable in the background while connected (see AudioIO.keepAlive).
        // Starts already on inactive: by the time the app is paused iOS no
        // longer lets it start playback.
        audio.keepAlive(_wantOnline && settings.backgroundAudio);
      case AppLifecycleState.detached:
        live.end();
        if (_client != null) _client!.shutdown();
    }
  }

  List<GroupNetwork> get _groupNetworks =>
      [for (final t in settings.groupsOfOtherNetworks) GroupNetwork(gssi: t.gssi, mcc: t.mcc, mnc: t.mnc)];

  Future<void> connect() async {
    await disconnect();
    _wantOnline = true;
    final c = await TetraClient.connect(
      config: TerminalConfig(
        serverUrl: settings.serverUrl,
        username: settings.username,
        password: settings.password,
        issi: settings.issi,
        name: settings.name.isEmpty ? null : settings.name,
        groups: Uint32List.fromList(settings.affiliatedGroups),
        selectedGroup: settings.selectedGssi,
        defaultPriority: settings.defaultPriority,
        allowPreemption: settings.allowPreemption,
        insecureTls: settings.insecureTls,
        basestation: settings.basestation,
        homeMcc: settings.homeMcc,
        homeMnc: settings.homeMnc,
        groupNetworks: _groupNetworks,
      ),
    );
    _client = c;
    unawaited(_pump(c));
    if (settings.basestation) await _startControl();
    if (settings.lipEnabled && settings.lipDestination > 0) {
      await location.start(Duration(seconds: settings.lipIntervalSeconds));
    }
    await WakelockPlus.enable();
  }

  /// Disconnect by hand: stays offline until connected again.
  Future<void> goOffline() async {
    _wantOnline = false;
    await disconnect();
  }

  Future<void> disconnect() async {
    final c = _client;
    _client = null;
    final ctl = _control;
    _control = null;
    controlOnline = false;
    controlError = null;
    if (ctl != null) await ctl.shutdown();
    await location.stop();
    await audio.stopMic();
    if (c != null) await c.shutdown();
    link = LinkState.offline;
    groupActivity.clear();
    _closeLog();
    groupAccess = const {};
    managedGroups = null;
    privateCall = null;
    myTxCallId = null;
    await WakelockPlus.disable();
    notifyListeners();
  }

  Future<void> _startControl() async {
    final p = settings.active;
    final TetraControl ctl;
    try {
      ctl = await TetraControl.connect(
        config: ControlConfig(
          brewUrl: p.serverUrl,
          controlUrl: p.controlUrl,
          tls: p.controlTls,
          insecureTls: p.insecureTls,
          username: p.controlUsername.isEmpty ? p.username : p.controlUsername,
          password: p.controlUsername.isEmpty && p.controlPassword.isEmpty ? p.password : p.controlPassword,
          issi: p.issi,
          groups: [for (final t in p.talkgroups.where((t) => t.dgna)) DgnaGroupInfo(gssi: t.gssi, mnemonic: t.name, attachmentMode: t.dgnaMode)],
        ),
      );
    } catch (e) {
      controlError = '$e';
      notifyListeners();
      return;
    }
    _control = ctl;
    unawaited(() async {
      while (identical(_control, ctl)) {
        final e = await ctl.nextEvent();
        if (e == null || !identical(_control, ctl)) break;
        switch (e) {
          case ControlAppEvent_Connected():
            controlOnline = true;
            controlError = null;
          case ControlAppEvent_Disconnected(:final error):
            controlOnline = false;
            controlError = error;
          case ControlAppEvent_Dgna(:final group, :final attach):
            await applyDgna(group.gssi, group.mnemonic, group.attachmentMode, attach: attach);
        }
        notifyListeners();
      }
    }());
  }

  /// SS-DGNA from the control channel: an assigned group is added (and
  /// scanned, so it is affiliated); a deassigned one is removed if DGNA gave it.
  /// A group the user had already keeps being theirs.
  Future<void> applyDgna(int gssi, String? mnemonic, int attachmentMode, {required bool attach}) async {
    final i = settings.talkgroups.indexWhere((t) => t.gssi == gssi);
    if (attach) {
      if (i < 0) {
        settings.talkgroups.add(Talkgroup(gssi, mnemonic ?? 'TG $gssi', dgna: true, dgnaMode: attachmentMode));
      } else {
        final t = settings.talkgroups[i];
        t.scan = true;
        if (t.dgna) {
          t.dgnaMode = attachmentMode;
          if (mnemonic != null) t.name = mnemonic;
        }
      }
    } else if (i >= 0 && settings.talkgroups[i].dgna) {
      settings.talkgroups.removeAt(i);
    } else {
      return;
    }
    await saveTalkgroups();
  }

  Future<void> _pump(TetraClient c) async {
    while (identical(_client, c)) {
      final e = await c.nextEvent();
      if (e == null) break;
      _handle(e);
    }
  }

  @visibleForTesting
  void handleEvent(AppEvent e) => _handle(e);

  void _handle(AppEvent e) {
    switch (e) {
      case AppEvent_Audio(:final callId, :final pcm):
        if (callId == focusCallId) audio.play(pcm);
        return; // no rebuild per audio frame
      case AppEvent_Connecting():
        link = LinkState.connecting;
      case AppEvent_Connected():
        link = LinkState.online;
        lastError = null;
      case AppEvent_Disconnected(:final reason):
        link = LinkState.offline;
        lastError = reason;
        groupActivity.clear();
        _closeLog();
      case AppEvent_GroupTxStarted(:final gssi, :final talker, :final talkerName, :final priority, :final callId):
        groupActivity[gssi] = GroupCallState(gssi, talker, talkerName, priority, callId);
        _logStart(callId, CallLogEntry(time: DateTime.now(), issi: talker, kind: CallKind.groupHeard, gssi: gssi, groupName: _groupName(gssi), sentName: talkerName, emergency: priority >= 15));
      case AppEvent_GroupTxEnded(:final gssi, :final callId):
        if (groupActivity[gssi]?.callId == callId) groupActivity.remove(gssi);
        _logEnd(callId);
      case AppEvent_TxGranted(:final callId):
        myTxCallId = callId;
        myTxSince = DateTime.now();
        final g = settings.selectedGssi;
        if (privateCall == null && g != null) {
          _logStart('tx:$callId', CallLogEntry(time: myTxSince!, issi: settings.issi, kind: CallKind.groupTalked, gssi: g, groupName: _groupName(g)));
        }
        HapticFeedback.heavyImpact();
        _startMic();
      case AppEvent_TxDenied(:final reason):
        _clearLatch();
        HapticFeedback.vibrate();
        toast = 'PTT denied: $reason';
      case AppEvent_TxEnded(:final callId, :final preempted):
        if (myTxCallId == callId) {
          myTxCallId = null;
          _clearLatch();
        }
        _logEnd('tx:$callId');
        if (preempted) toast = 'Transmission pre-empted by a higher priority call';
        _updateMic();
      case AppEvent_PrivateCall(:final call):
        if (!_openLog.containsKey('pc:${call.id}')) {
          _privateConnectedAt = null;
          _logStart('pc:${call.id}', CallLogEntry(
              time: DateTime.now(), issi: call.peer, kind: call.incoming ? CallKind.privateMissed : CallKind.privateOut,
              sentName: call.number ?? call.peerName, emergency: call.priority >= 15));
        }
        if (call.state == 'connected' && _privateConnectedAt == null) {
          _privateConnectedAt = DateTime.now();
          if (call.incoming) _openLog['pc:${call.id}']?.kind = CallKind.privateIn;
        }
        privateCall = call;
        _updateMic();
      case AppEvent_PrivateCallEnded(:final callId):
        if (privateCall?.id == callId) privateCall = null;
        final e = _openLog.remove('pc:$callId');
        if (e != null && _privateConnectedAt != null) e.duration = DateTime.now().difference(_privateConnectedAt!);
        callLog.changed();
        _updateMic();
      case AppEvent_AudioFocus(:final callId):
        focusCallId = callId;
      case AppEvent_TextReceived(:final from, :final to, :final text, :final immediate):
        // Group messages are filed under the group, private ones under the sender.
        final peer = to == settings.issi ? from : to;
        messages.add(ChatMessage(peer: peer, outgoing: false, text: text, status: MsgStatus.received, immediate: immediate));
        if (immediate) toast = 'Flash message from $from: $text';
      case AppEvent_MessageStatus(:final localId, :final status):
        final m = messages.where((m) => m.localId == localId).firstOrNull;
        if (m != null) {
          final next = switch (status) {
            'sent' => MsgStatus.sent,
            'network_accepted' => MsgStatus.networkAccepted,
            'delivered' => MsgStatus.delivered,
            _ => MsgStatus.failed,
          };
          // Never downgrade (a late network report after delivery).
          if (m.status != MsgStatus.delivered) m.status = next;
        }
      case AppEvent_LocationReceived(:final from, :final location, :final reason):
        locations[from] = RemoteLocation(from, location, reason);
      case AppEvent_ServerError(:final kind):
        toast = kind == 1
            ? 'Not allowed by the server (group blocked or receive only)'
            : 'The server could not read a message from this app';
      case AppEvent_Extensions(:final offered):
        extensions = offered;
        if (!multiNetwork) networks = const [];
      case AppEvent_Networks(:final json):
        networks = parseNetworks(json);
      case AppEvent_GroupAccess(:final json):
        final (groups, listed) = parseGroupAccess(json);
        groupAccess = groups;
        managedGroups = listed;
      case AppEvent_SubscriberProfiles():
        break;
    }
    notifyListeners();
  }

  /// Rebuild after a change made outside the model (e.g. the call log).
  void refresh() => notifyListeners();

  String _groupName(int gssi) => settings.talkgroups.where((t) => t.gssi == gssi).firstOrNull?.name ?? 'TG $gssi';

  void _logStart(String key, CallLogEntry e) {
    _openLog[key] = e;
    callLog.add(e);
  }

  void _closeLog() {
    for (final k in _openLog.keys.toList()) {
      _logEnd(k);
    }
  }

  void _logEnd(String key) {
    final e = _openLog.remove(key);
    if (e == null) return;
    e.duration = DateTime.now().difference(e.time);
    callLog.changed();
  }

  bool get _micWanted => myTxCallId != null || (privateCall?.state == 'connected' && privateCall!.duplex);

  void _startMic() {
    if (audio.micRunning) return;
    final duplex = privateCall?.state == 'connected' && privateCall!.duplex;
    audio.startMic((pcm) => _client?.pushMicPcm(pcm: pcm), voiceProcessing: duplex).catchError((Object err) {
      toast = err.toString();
      notifyListeners();
    });
  }

  void _updateMic() {
    if (_micWanted) {
      _startMic();
    } else {
      audio.stopMic();
    }
  }

  void clearToast() => toast = null;

  // ───────── actions ─────────

  void pttDown({bool emergency = false}) {
    // Pressed again during the hang-over: just keep transmitting.
    if (_releaseTimer != null) {
      _releaseTimer!.cancel();
      _releaseTimer = null;
      if (myTxCallId != null) return;
    }
    _client?.ptt(pressed: true, group: privateCall == null ? settings.selectedGssi : null, emergency: emergency);
    if (settings.lipEnabled && (settings.lipOnPtt || emergency)) {
      location.sendNow(emergency ? LipReason.emergency : LipReason.ptt);
    }
  }

  Timer? _releaseTimer;

  /// Keeps the mic live for a moment after release so the end of the last word
  /// is captured and sent instead of being cut off mid-syllable.
  static const _hangover = Duration(milliseconds: 120);

  void pttUp() {
    _releaseTimer?.cancel();
    _releaseTimer = Timer(_hangover, () {
      _releaseTimer = null;
      _client?.ptt(pressed: false, group: null, emergency: false);
    });
  }

  Timer? _autoStop;
  bool _latched = false;

  /// When the Live Activity PTT stops by itself (null = no auto-stop or not latched).
  DateTime? latchedTxEndsAt;

  /// Tap-to-talk (the PTT button in toggle mode and the Live Activity, whose
  /// buttons only take taps): the first tap keys up, the next one releases.
  /// Stops by itself after [Settings.pttAutoStopSeconds] unless that is 0.
  void togglePtt() {
    if (transmitting || _latched) {
      _clearLatch();
      pttUp();
    } else {
      if (link != LinkState.online || (privateCall == null && !mayTalkOnSelected)) return;
      _latched = true;
      pttDown();
      final secs = settings.pttAutoStopSeconds;
      if (secs > 0) {
        latchedTxEndsAt = DateTime.now().add(Duration(seconds: secs));
        _autoStop = Timer(Duration(seconds: secs), () {
          _clearLatch();
          pttUp();
          notifyListeners();
        });
      }
    }
    notifyListeners();
  }

  void _clearLatch() {
    _autoStop?.cancel();
    _autoStop = null;
    _latched = false;
    latchedTxEndsAt = null;
  }

  /// Whether tap-to-talk is keyed up (waiting for the grant or transmitting).
  bool get pttLatched => _latched;

  Future<void> setPttToggle(bool on) async {
    settings.pttToggle = on;
    notifyListeners();
    await settings.save();
  }

  Future<void> setPttAutoStop(int seconds) async {
    settings.pttAutoStopSeconds = seconds;
    notifyListeners();
    await settings.save();
  }

  Future<void> selectGroup(int gssi) async {
    settings.selectedGssi = gssi;
    await settings.save();
    await _client?.setGroups(groups: Uint32List.fromList(settings.affiliatedGroups), selected: gssi);
    await _client?.selectGroup(gssi: gssi);
    notifyListeners();
  }

  Future<void> saveTalkgroups() async {
    if (settings.selectedGssi != null && !settings.talkgroups.any((t) => t.gssi == settings.selectedGssi)) {
      settings.selectedGssi = settings.talkgroups.firstOrNull?.gssi;
    }
    settings.selectedGssi ??= settings.talkgroups.firstOrNull?.gssi;
    await settings.save();
    await _client?.setGroupNetworks(networks: _groupNetworks);
    await _client?.setGroups(groups: Uint32List.fromList(settings.affiliatedGroups), selected: settings.selectedGssi);
    notifyListeners();
  }

  void dial(int issi, {required bool duplex, required bool hook, int? priority}) =>
      _client?.dial(issi: issi, duplex: duplex, hook: hook, priority: priority);
  /// Phone/PBX call through the server's SIP gateway. The configured outside-line
  /// prefix (shown fixed in front of the number field) is always prepended.
  void dialExternal(String number, {int? priority}) =>
      _client?.dialExternal(number: '${settings.externalPrefix}$number', priority: priority);

  void answer() => _client?.answer();
  void hangup() => _client?.hangup();
  void dtmf(String d) => _client?.sendDtmf(digit: d);

  void sendText(int to, String text, {bool immediate = false}) {
    final id = _nextLocalId++;
    final isGroup = settings.talkgroups.any((t) => t.gssi == to);
    messages.add(ChatMessage(peer: to, outgoing: true, text: text, status: MsgStatus.sending, localId: id, immediate: immediate));
    // No SDS-TL report for group-addressed messages: every member would answer.
    _client?.sendText(localId: id, to: to, text: text, immediate: immediate, requestReport: !isGroup);
    notifyListeners();
  }

  /// Loudspeaker or earpiece (phone mode), applied at once and saved.
  Future<void> setSpeakerOut(bool on) async {
    settings.speakerOut = on;
    notifyListeners();
    await audio.setSpeaker(on);
    await settings.save();
  }

  void sendLocationNow() => location.sendNow(LipReason.user);

  /// Switches to another connection profile and connects with it.
  Future<void> switchProfile(String id) async {
    if (id == settings.activeId) return;
    settings.activeId = id;
    networks = const [];
    extensions = const [];
    messages.clear();
    locations.clear();
    await settings.save();
    if (settings.isConfigured) {
      await connect();
    } else {
      await goOffline();
    }
    notifyListeners();
  }

  /// Adds or updates a profile (from the edit sheet). Reconnects when the
  /// active profile changed.
  Future<void> saveProfile(ConnectionProfile p) async {
    final i = settings.profiles.indexWhere((x) => x.id == p.id);
    if (i < 0) {
      settings.profiles.add(p);
    } else {
      settings.profiles[i] = p;
    }
    await settings.save();
    if (p.id == settings.activeId && settings.isConfigured) await connect();
    notifyListeners();
  }

  Future<void> deleteProfile(ConnectionProfile p) async {
    final wasActive = p.id == settings.activeId;
    await settings.removeProfile(p);
    await settings.save();
    if (wasActive) {
      networks = const [];
      settings.isConfigured ? await connect() : await goOffline();
    }
    notifyListeners();
  }

  /// Light, dark or follow the system; applies at once.
  Future<void> setAppearance(String v) async {
    settings.appearance = v;
    notifyListeners();
    await settings.save();
  }

  Future<void> setLiveActivity(bool on) async {
    settings.liveActivity = on;
    notifyListeners();
    await settings.save();
  }

  Future<void> applySettings(Settings s) async {
    settings = s;
    audio.micGainDb = s.micGainDb;
    await s.save();
    await _startPttInput();
    await connect();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopPttInput();
    disconnect();
    audio.dispose();
    super.dispose();
  }
}

/// `SERVICE_NETWORKS` JSON → the server's own network first, then the linked ones.
List<LinkedNetwork> parseNetworks(String json) {
  try {
    final j = jsonDecode(json) as Map<String, dynamic>;
    final own = j['this'] as Map<String, dynamic>?;
    return [
      if (own != null) LinkedNetwork(own['mcc'] as int? ?? 0, own['mnc'] as int? ?? 0, 'This server', own: true),
      for (final n in (j['networks'] as List? ?? []).cast<Map<String, dynamic>>())
        LinkedNetwork(n['mcc'] as int? ?? 0, n['mnc'] as int? ?? 0, n['name'] as String? ?? '?', up: n['up'] as bool? ?? false),
    ];
  } catch (_) {
    return const [];
  }
}

/// `SERVICE_GROUP_ACCESS` for a terminal (docs/Brew-Extensions.md 12.3):
/// `{"groups":[{"gssi":N,"access":"refused"|"listen"}],"managed"?:true,"listed"?:[..]}`.
(Map<int, GroupAccess>, Set<int>?) parseGroupAccess(String json) {
  try {
    final j = jsonDecode(json) as Map<String, dynamic>;
    final groups = <int, GroupAccess>{
      for (final g in (j['groups'] as List? ?? []).cast<Map<String, dynamic>>())
        if (g['gssi'] is int)
          g['gssi'] as int: switch (g['access']) {
            'refused' => GroupAccess.refused,
            'listen' => GroupAccess.listen,
            _ => GroupAccess.open,
          },
    }..removeWhere((_, a) => a == GroupAccess.open);
    final listed = j['managed'] == true ? {...(j['listed'] as List? ?? []).whereType<int>()} : null;
    return (groups, listed);
  } catch (_) {
    return (const <int, GroupAccess>{}, null);
  }
}
