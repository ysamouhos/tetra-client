import 'dart:typed_data';

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../services/audio_io.dart';
import '../services/location_service.dart';
import '../src/rust/api.dart';
import 'settings.dart';

enum LinkState { offline, connecting, online }

class GroupCallState {
  GroupCallState(this.gssi, this.talker, this.talkerName, this.priority, this.callId);
  final int gssi;
  final int talker;
  final String? talkerName;
  final int priority;
  final String callId;
  bool get emergency => priority >= 15;
}

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

class RemoteLocation {
  RemoteLocation(this.issi, this.location, this.reason) : time = DateTime.now();
  final int issi;
  final LocationInfo location;
  final int? reason;
  final DateTime time;
}

/// App-wide state over the Rust `TetraClient`.
class TerminalModel extends ChangeNotifier {
  TerminalModel(this.settings);

  Settings settings;
  final audio = AudioIO();
  late final location = LocationService((loc, reason) => _client?.sendLocation(to: settings.lipDestination, location: loc, reason: reason));

  TetraClient? _client;
  LinkState link = LinkState.offline;
  String? lastError;

  /// Active transmissions per talkgroup.
  final Map<int, GroupCallState> groupActivity = {};
  String? myTxCallId;
  PrivateCallInfo? privateCall;
  String? focusCallId;
  final List<ChatMessage> messages = [];
  final Map<int, RemoteLocation> locations = {};
  int _nextLocalId = 1;
  String? toast;

  bool get transmitting => myTxCallId != null;
  int? get selectedGssi => settings.selectedGssi;

  /// The talker currently heard, for the status banner.
  GroupCallState? get heard => groupActivity.values.where((g) => g.callId == focusCallId).firstOrNull;

  Future<void> start() async {
    await audio.init();
    audio.micGainDb = settings.micGainDb;
    if (settings.isConfigured) await connect();
  }

  Future<void> connect() async {
    await disconnect();
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
      ),
    );
    _client = c;
    unawaited(_pump(c));
    if (settings.lipEnabled && settings.lipDestination > 0) {
      await location.start(Duration(seconds: settings.lipIntervalSeconds));
    }
    await WakelockPlus.enable();
  }

  Future<void> disconnect() async {
    final c = _client;
    _client = null;
    await location.stop();
    await audio.stopMic();
    if (c != null) await c.shutdown();
    link = LinkState.offline;
    groupActivity.clear();
    privateCall = null;
    myTxCallId = null;
    await WakelockPlus.disable();
    notifyListeners();
  }

  Future<void> _pump(TetraClient c) async {
    while (identical(_client, c)) {
      final e = await c.nextEvent();
      if (e == null) break;
      _handle(e);
    }
  }

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
      case AppEvent_GroupTxStarted(:final gssi, :final talker, :final talkerName, :final priority, :final callId):
        groupActivity[gssi] = GroupCallState(gssi, talker, talkerName, priority, callId);
      case AppEvent_GroupTxEnded(:final gssi, :final callId):
        if (groupActivity[gssi]?.callId == callId) groupActivity.remove(gssi);
      case AppEvent_TxGranted(:final callId):
        myTxCallId = callId;
        _startMic();
      case AppEvent_TxDenied(:final reason):
        toast = 'PTT denied: $reason';
      case AppEvent_TxEnded(:final callId, :final preempted):
        if (myTxCallId == callId) myTxCallId = null;
        if (preempted) toast = 'Transmission pre-empted by a higher priority call';
        _updateMic();
      case AppEvent_PrivateCall(:final call):
        privateCall = call;
        _updateMic();
      case AppEvent_PrivateCallEnded(:final callId):
        if (privateCall?.id == callId) privateCall = null;
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
      case AppEvent_SubscriberProfiles():
      case AppEvent_ServerError():
        break;
    }
    notifyListeners();
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

  void sendLocationNow() => location.sendNow(LipReason.user);

  Future<void> applySettings(Settings s) async {
    settings = s;
    audio.micGainDb = s.micGainDb;
    await s.save();
    await connect();
  }

  @override
  void dispose() {
    disconnect();
    audio.dispose();
    super.dispose();
  }
}
