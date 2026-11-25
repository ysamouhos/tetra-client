import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:tetra_terminal/model/contacts.dart';
import 'package:tetra_terminal/model/settings.dart';
import 'package:tetra_terminal/model/terminal_model.dart';
import 'package:tetra_terminal/src/rust/api.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(const MethodChannel('com.llfbandit.record/messages'), (_) async => null);

  test('RadioID CSV: columns by header, quoted fields, bad rows skipped', () {
    const csv = 'RADIO_ID,CALLSIGN,FIRST_NAME,LAST_NAME,CITY,STATE,COUNTRY\n'
        '2320972,OE1ABC,Anna,Muster,Wien,,Austria\n'
        '2629001,DL2XY,"Max, Jr.",X,Berlin,,Germany\n'
        'x,BAD,,,,,\n'
        '99999999,TOOBIG,,,,,\n'
        '2320973,,NoCall,,,,\n';
    final db = parseRadioIdCsv(csv);
    expect(db.keys, [2320972, 2629001]);
    expect(db[2629001], (callsign: 'DL2XY', firstName: 'Max, Jr.'));
    expect(parseRadioIdCsv('FOO,BAR\n1,2'), isEmpty, reason: 'unknown header');
    final tsv = db.entries.map((e) => '${e.key}\t${e.value.callsign}\t${e.value.firstName}').join('\n');
    expect(parseRadioIdTsv(tsv), db);
  });

  test('own contacts win over the radio\'s name and RadioID', () {
    final book = ContactBook()..radioIdForTest = {2320972: (callsign: 'OE1ABC', firstName: 'Anna')};
    expect(book.display(2320972), 'OE1ABC');
    expect(book.display(2320972, sentName: 'Mobile 1'), 'Mobile 1');
    book.contacts.add(Contact(2320972, 'Anna Kahlenberg'));
    expect(book.display(2320972, sentName: 'Mobile 1'), 'Anna Kahlenberg');
    expect(book.display(5), 'ISSI 5');
  });

  test('call log: group calls heard with group and duration, missed private calls', () async {
    SharedPreferences.setMockInitialValues({});
    final m = TerminalModel(Settings()..talkgroups = [Talkgroup(91, 'Austria')]);
    m.handleEvent(const AppEvent.groupTxStarted(gssi: 91, talker: 2320972, talkerName: 'OE1ABC', priority: 1, emergency: false, callId: 'c1'));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    m.handleEvent(const AppEvent.groupTxEnded(gssi: 91, callId: 'c1', cause: 0));
    final e = m.callLog.entries.single;
    expect((e.kind, e.issi, e.groupName, e.sentName), (CallKind.groupHeard, 2320972, 'Austria', 'OE1ABC'));
    expect(e.duration.inMilliseconds, greaterThanOrEqualTo(20));

    const ring = PrivateCallInfo(id: 'p1', peer: 2629001, incoming: true, state: 'ringing', duplex: true, hook: true, priority: 1, floor: 'idle');
    m.handleEvent(const AppEvent.privateCall(call: ring));
    m.handleEvent(const AppEvent.privateCallEnded(callId: 'p1', peer: 2629001, cause: 0));
    expect(m.callLog.entries.first.kind, CallKind.privateMissed);

    final back = CallLogEntry.fromJson(e.toJson());
    expect((back.kind, back.issi, back.gssi, back.duration.inMilliseconds), (e.kind, e.issi, e.gssi, e.duration.inMilliseconds));
  });

  test('a garbled sent name falls back to RadioID', () {
    final b = ContactBook()..radioIdForTest = {2321109: (callsign: 'OE1GKS', firstName: 'G')};
    expect(b.display(2321109, sentName: 'O\nE94i'), 'OE1GKS');
    expect(b.display(2321109, sentName: 'OE1GKS-M'), 'OE1GKS-M');
  });
}
