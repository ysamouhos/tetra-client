import 'dart:math' as math;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/terminal_model.dart';
import '../src/rust/api.dart';
import '../ui/adaptive.dart';
import '../ui/theme.dart';
import '../model/contacts.dart';
import 'contacts_screen.dart';
import 'home_screen.dart';
import 'messages_screen.dart';

/// Individual calls: a phone-style keypad, call options in a sheet, and the
/// in-call screen.
class CallsScreen extends StatefulWidget {
  const CallsScreen({super.key});
  @override
  State<CallsScreen> createState() => CallsScreenState();
}

class CallsScreenState extends State<CallsScreen> {
  bool _recents = true;
  String _number = '';

  /// Shows the keypad with [issi] filled in (from Recents or Contacts).
  void openKeypad(int issi) => setState(() {
        _recents = false;
        _external = false;
        _number = '$issi';
      });
  bool _external = false; // false = TETRA (ISSI), true = phone / PBX via SIP gateway
  bool _duplex = true;
  bool _hook = true;
  int _priority = 1;

  void _key(String k) {
    final max = _external ? 31 : 8;
    if (!_external && !RegExp(r'[0-9]').hasMatch(k)) return;
    if (_number.length >= max) return;
    Haptics.select();
    setState(() => _number += k);
  }

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final call = m.privateCall;
    if (call != null) return _ActiveCall(call: call);
    final online = m.link == LinkState.online;
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final prefix = m.settings.externalPrefix;
    final options = _external
        ? 'Phone via the server\'s SIP gateway · P$_priority'
        : '${_duplex ? 'Full duplex' : 'Half duplex'} · ${_hook ? 'rings' : 'direct'} · P$_priority${_priority >= 15 ? ' emergency' : ''}';

    return SafeArea(
      child: LayoutBuilder(builder: (context, box) {
        // Fit both the width and the height (shorter screens, taller nav bars):
        // about 260 pt go to the controls above, the number and the margins.
        final byWidth = (box.maxWidth - 2 * 40 - 2 * 24) / 3;
        final byHeight = (box.maxHeight - 260) / 5 - 14;
        final keySize = math.min(byWidth, byHeight).clamp(48.0, 80.0);
        final top = Padding(
          padding: const EdgeInsets.fromLTRB(Tokens.gutter, 12, Tokens.gutter, 0),
          child: Row(children: [
            Expanded(child: Segments<bool>(items: const {true: 'Recents', false: 'Keypad'}, value: _recents, onChanged: (v) => setState(() => _recents = v))),
            const SizedBox(width: 8),
            const LinkPill(),
          ]),
        );
        if (_recents) return Column(children: [top, Expanded(child: RecentsList(onCall: openKeypad))]);
        return Column(children: [
          top,
          const SizedBox(height: 10),
          SizedBox(
            width: 200,
            child: Segments<bool>(items: const {false: 'TETRA', true: 'Phone'}, value: _external, onChanged: (v) => setState(() {
              _external = v;
              _number = '';
            })),
          ),
          const Spacer(),
          Text(
            _number.isEmpty ? (_external ? 'Phone number' : 'ISSI') : '${_external && prefix.isNotEmpty ? '$prefix ' : ''}$_number',
            style: text.displaySmall?.copyWith(
              fontWeight: FontWeight.w400,
              letterSpacing: 1.5,
              color: _number.isEmpty ? scheme.outline : scheme.onSurface,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(height: 6),
          TextButton.icon(
            onPressed: _options,
            icon: Icon(CupertinoIcons.slider_horizontal_3, size: 18, color: scheme.primary),
            label: Text(options),
          ),
          const Spacer(),
          for (final row in const [['1', '2', '3'], ['4', '5', '6'], ['7', '8', '9'], ['*', '0', '#']])
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                for (final k in row)
                  Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: _Key(k, size: keySize, enabled: _external || RegExp(r'[0-9]').hasMatch(k), onTap: () => _key(k))),
              ]),
            ),
          const SizedBox(height: 10),
          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
            SizedBox(width: keySize + 24),
            _RoundButton(
              size: keySize,
              color: Tokens.online,
              icon: CupertinoIcons.phone_fill,
              label: 'Call',
              onTap: !online || _number.isEmpty ? null : () => _dial(m),
            ),
            SizedBox(
              width: keySize + 24,
              child: _number.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Delete',
                      onPressed: () => setState(() => _number = _number.substring(0, _number.length - 1)),
                      icon: Icon(CupertinoIcons.delete_left, color: scheme.onSurfaceVariant),
                    ),
            ),
          ]),
          const SizedBox(height: 20),
        ]);
      }),
    );
  }

  void _dial(TerminalModel m) {
    Haptics.press();
    if (_external) {
      m.dialExternal(_number, priority: _priority);
      return;
    }
    final issi = int.tryParse(_number);
    if (issi == null || issi <= 0) return;
    m.dial(issi, duplex: _duplex, hook: _hook, priority: _priority);
  }

  Future<void> _options() async {
    await showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (ctx) => StatefulBuilder(builder: (ctx, set) {
        void update(VoidCallback f) {
          set(f);
          setState(() {});
        }

        return SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            if (!_external)
              Section(header: 'Call type', children: [
                SwitchRow(title: 'Full duplex', subtitle: _duplex ? 'Both talk at once, like a phone' : 'Press PTT to talk', value: _duplex, onChanged: (v) => update(() => _duplex = v)),
                SwitchRow(title: 'Ring the other party', subtitle: _hook ? 'They must answer' : 'Connects immediately', value: _hook, onChanged: (v) => update(() => _hook = v)),
              ]),
            Section(
              header: 'Priority',
              footer: '12–14 can interrupt lower calls, 15 is an emergency call.',
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Tokens.gutter, vertical: 8),
                  child: Row(children: [
                    SizedBox(width: 48, child: Text('P$_priority', style: Theme.of(ctx).textTheme.titleMedium)),
                    Expanded(child: Slider.adaptive(value: _priority.toDouble(), min: 0, max: 15, divisions: 15, onChanged: (v) => update(() => _priority = v.round()))),
                  ]),
                ),
              ],
            ),
            const SizedBox(height: 12),
          ]),
        );
      }),
    );
  }
}

class _Key extends StatelessWidget {
  const _Key(this.k, {required this.size, required this.onTap, this.enabled = true});
  final String k;
  final double size;
  final VoidCallback onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerHigh.withValues(alpha: enabled ? 1 : .4),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: enabled ? onTap : null,
        child: SizedBox(
          width: size,
          height: size,
          child: Center(child: Text(k, style: TextStyle(fontSize: size * .42, fontWeight: FontWeight.w400, color: scheme.onSurface.withValues(alpha: enabled ? 1 : .35)))),
        ),
      ),
    );
  }
}

class _RoundButton extends StatelessWidget {
  const _RoundButton({required this.size, required this.color, required this.icon, required this.label, required this.onTap});
  final double size;
  final Color color;
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: label,
        child: Material(
          color: onTap == null ? color.withValues(alpha: .4) : color,
          shape: const CircleBorder(),
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox(width: size, height: size, child: Icon(icon, color: Colors.white, size: size * .42)),
          ),
        ),
      );
}

class _ActiveCall extends StatefulWidget {
  const _ActiveCall({required this.call});
  final PrivateCallInfo call;
  @override
  State<_ActiveCall> createState() => _ActiveCallState();
}

class _ActiveCallState extends State<_ActiveCall> {
  bool _keypad = false;
  DateTime? _connectedAt;

  @override
  Widget build(BuildContext context) {
    final call = widget.call;
    final m = context.read<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    if (call.state == 'connected') _connectedAt ??= DateTime.now();
    final name = call.number != null ? (call.peerName ?? 'Phone') : m.nameOf(call.peer, sentName: call.peerName);
    final sub = call.number ?? (name != 'ISSI ${call.peer}' ? 'ISSI ${call.peer}' : null);
    final status = switch (call.state) {
      'setup' || 'proceeding' => 'Calling…',
      'alerting' => 'Ringing…',
      'ringing' => 'Incoming ${call.duplex ? 'call' : 'half-duplex call'}',
      'connecting' => 'Connecting…',
      'connected' => call.duplex ? null : (call.floor == 'peer' ? 'Other party is talking' : 'Hold PTT to talk'),
      _ => call.state,
    };
    final initials = name.trim().isEmpty ? '?' : name.trim().split(RegExp(r'\s+')).take(2).map((w) => w[0].toUpperCase()).join();

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        child: Column(children: [
          if (call.priority >= 15)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(color: Tokens.emergency, borderRadius: BorderRadius.circular(999)),
              child: const Text('EMERGENCY', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            ),
          const SizedBox(height: 32),
          CircleAvatar(radius: 48, backgroundColor: scheme.surfaceContainerHigh, child: Text(initials, style: text.headlineMedium?.copyWith(color: scheme.onSurface))),
          const SizedBox(height: 16),
          Text(name, textAlign: TextAlign.center, style: text.headlineMedium?.copyWith(fontWeight: FontWeight.w600)),
          if (sub != null) Text(sub, style: text.titleMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const SizedBox(height: 8),
          if (call.state == 'connected' && _connectedAt != null && status == null)
            Elapsed(_connectedAt!, style: text.titleMedium?.copyWith(color: scheme.onSurfaceVariant))
          else
            Text(status ?? '', style: text.titleMedium?.copyWith(color: scheme.onSurfaceVariant)),
          const Spacer(),
          if (call.state == 'connected' && !call.duplex) const PttButton(compact: true),
          if (call.state == 'connected' && call.duplex && _keypad) _Dtmf(onDigit: m.dtmf),
          const SizedBox(height: 24),
          Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
            if (call.state == 'connected' && call.duplex)
              _RoundButton(
                size: 64,
                color: _keypad ? scheme.primary : scheme.surfaceContainerHighest,
                icon: CupertinoIcons.circle_grid_3x3_fill,
                label: 'Keypad',
                onTap: () => setState(() => _keypad = !_keypad),
              ),
            if (call.state == 'ringing')
              _RoundButton(size: 72, color: Tokens.online, icon: CupertinoIcons.phone_fill, label: 'Answer', onTap: () {
                Haptics.press();
                m.answer();
              }),
            _RoundButton(size: 72, color: Tokens.emergency, icon: CupertinoIcons.phone_down_fill, label: 'Hang up', onTap: () {
              Haptics.release();
              m.hangup();
            }),
          ]),
          const SizedBox(height: 16),
        ]),
      ),
    );
  }
}

class _Dtmf extends StatelessWidget {
  const _Dtmf({required this.onDigit});
  final void Function(String) onDigit;

  @override
  Widget build(BuildContext context) {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
    return Wrap(
      alignment: WrapAlignment.center,
      spacing: 18,
      runSpacing: 12,
      children: [
        for (final k in keys)
          _Key(k, size: 58, onTap: () {
            Haptics.select();
            onDigit(k);
          }),
      ],
    );
  }
}

/// Call log: time, callsign, group (or call type) and how long they talked.
class RecentsList extends StatelessWidget {
  const RecentsList({super.key, required this.onCall});
  final void Function(int issi) onCall;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final entries = m.callLog.entries;
    if (entries.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(CupertinoIcons.clock, size: 44, color: scheme.outline),
            const SizedBox(height: 12),
            Text('No recent calls', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text('Who talked on your groups, and your own calls, show up here.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
          ]),
        ),
      );
    }
    final now = DateTime.now();
    String day(DateTime t) {
      final d = DateTime(t.year, t.month, t.day);
      final diff = DateTime(now.year, now.month, now.day).difference(d).inDays;
      if (diff == 0) return 'Today';
      if (diff == 1) return 'Yesterday';
      const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
      return '${t.day} ${months[t.month - 1]}';
    }

    final rows = <Widget>[];
    String? lastDay;
    for (final e in entries) {
      final d = day(e.time);
      if (d != lastDay) {
        rows.add(Padding(
          padding: EdgeInsets.fromLTRB(Tokens.gutter, rows.isEmpty ? 8 : 20, Tokens.gutter, 6),
          child: Row(children: [
            Text(d.toUpperCase(), style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant, letterSpacing: .3)),
            const Spacer(),
            if (rows.isEmpty)
              GestureDetector(
                onTap: () async {
                  final ok = await showActions<bool>(context, title: 'Clear recents?', actions: const [SheetAction('Clear recents', true, destructive: true)]);
                  if (ok == true) {
                    await m.callLog.clear();
                    m.refresh();
                  }
                },
                child: Text('Clear', style: TextStyle(fontSize: 15, color: scheme.primary)),
              ),
          ]),
        ));
        lastDay = d;
      }
      rows.add(_LogRow(e, onTap: () => _actions(context, m, e)));
    }
    return ListView(
      padding: EdgeInsets.only(bottom: 16 + MediaQuery.of(context).padding.bottom),
      children: rows,
    );
  }

  Future<void> _actions(BuildContext context, TerminalModel m, CallLogEntry e) async {
    if (e.kind == CallKind.groupTalked) return;
    final name = m.nameOf(e.issi, sentName: e.sentName);
    final contact = m.contacts.contactOf(e.issi);
    final a = await showActions<String>(context, title: name, message: 'ISSI ${e.issi}', actions: [
      const SheetAction('Call', 'call'),
      const SheetAction('Message', 'message'),
      SheetAction(contact == null ? 'Add to contacts' : 'Edit contact', 'contact'),
    ]);
    if (!context.mounted) return;
    switch (a) {
      case 'call':
        onCall(e.issi);
      case 'message':
        await Navigator.push(context, CupertinoPageRoute(builder: (_) => ConversationScreen(peer: e.issi, title: name)));
      case 'contact':
        await editContact(context, m, contact, issi: e.issi);
    }
  }
}

class _LogRow extends StatelessWidget {
  const _LogRow(this.e, {required this.onTap});
  final CallLogEntry e;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final m = context.read<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final missed = e.kind == CallKind.privateMissed;
    final name = e.kind == CallKind.groupTalked ? 'You' : m.nameOf(e.issi, sentName: e.sentName);
    final (IconData icon, String what) = switch (e.kind) {
      CallKind.groupHeard => (CupertinoIcons.person_3_fill, e.groupName ?? 'TG ${e.gssi}'),
      CallKind.groupTalked => (CupertinoIcons.mic_fill, e.groupName ?? 'TG ${e.gssi}'),
      CallKind.privateIn => (CupertinoIcons.phone_arrow_down_left, 'Incoming call'),
      CallKind.privateOut => (CupertinoIcons.phone_arrow_up_right, 'Outgoing call'),
      CallKind.privateMissed => (CupertinoIcons.phone_arrow_down_left, 'Missed call'),
    };
    final hh = e.time.hour.toString().padLeft(2, '0'), mm = e.time.minute.toString().padLeft(2, '0');
    final secs = e.duration.inSeconds;
    final duration = secs <= 0 ? '' : '${secs ~/ 60}:${(secs % 60).toString().padLeft(2, '0')}';
    final red = missed || e.emergency;
    const tabular = [FontFeature.tabularFigures()];

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(Tokens.gutter, 9, Tokens.gutter, 9),
        child: Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(
            width: 50,
            child: Text('$hh:$mm', style: TextStyle(fontSize: 15, color: scheme.onSurfaceVariant, fontFeatures: tabular)),
          ),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, letterSpacing: -.2, color: red ? Tokens.emergency : scheme.onSurface)),
              const SizedBox(height: 2),
              Row(children: [
                Icon(icon, size: 13, color: scheme.onSurfaceVariant),
                const SizedBox(width: 5),
                Flexible(
                  child: Text('${e.emergency ? 'Emergency · ' : ''}$what', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 14, color: scheme.onSurfaceVariant)),
                ),
              ]),
            ]),
          ),
          const SizedBox(width: 8),
          Text(duration, style: TextStyle(fontSize: 17, color: scheme.onSurfaceVariant, fontFeatures: tabular)),
        ]),
      ),
    );
  }
}
