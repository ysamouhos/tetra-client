import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../model/terminal_model.dart';
import '../src/rust/api.dart';
import 'home_screen.dart';

class CallsScreen extends StatefulWidget {
  const CallsScreen({super.key});
  @override
  State<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends State<CallsScreen> {
  final _issi = TextEditingController();
  bool _external = false; // false = TETRA (ISSI), true = phone / PBX via SIP gateway
  bool _duplex = true;
  bool _hook = true;
  double _priority = 1;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final call = m.privateCall;
    if (call != null) return _ActiveCall(call: call);
    final online = m.link == LinkState.online;
    final prefix = m.settings.externalPrefix;
    return ListView(padding: const EdgeInsets.all(16), children: [
      SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: false, label: Text('TETRA'), icon: Icon(Icons.cell_tower)),
          ButtonSegment(value: true, label: Text('Phone'), icon: Icon(Icons.phone)),
        ],
        selected: {_external},
        onSelectionChanged: (s) => setState(() => _external = s.first),
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _issi,
        keyboardType: _external ? TextInputType.phone : TextInputType.number,
        inputFormatters: [
          _external ? FilteringTextInputFormatter.allow(RegExp(r'[0-9*#+]')) : FilteringTextInputFormatter.digitsOnly,
          LengthLimitingTextInputFormatter(_external ? 31 : 8),
        ],
        style: const TextStyle(fontSize: 28, letterSpacing: 2),
        decoration: InputDecoration(
          labelText: _external ? 'Phone number' : 'ISSI to call',
          prefixText: _external && prefix.isNotEmpty ? '$prefix ' : null,
          helperText: _external ? 'Outside TETRA via the server\'s SIP gateway' : null,
          border: const OutlineInputBorder(),
        ),
      ),
      const SizedBox(height: 12),
      if (!_external) SegmentedButton<bool>(
        segments: const [
          ButtonSegment(value: true, label: Text('Full duplex'), icon: Icon(Icons.phone_in_talk)),
          ButtonSegment(value: false, label: Text('Half duplex'), icon: Icon(Icons.record_voice_over)),
        ],
        selected: {_duplex},
        onSelectionChanged: (s) => setState(() => _duplex = s.first),
      ),
      if (!_external) SwitchListTile(
        title: const Text('Ring the other party'),
        subtitle: Text(_hook ? 'Hook signalling: they must answer' : 'Direct call: connects immediately'),
        value: _hook,
        onChanged: (v) => setState(() => _hook = v),
      ),
      ListTile(
        title: Text('Priority ${_priority.round()}${_priority >= 15 ? ' (emergency)' : _priority >= 12 ? ' (pre-emptive)' : ''}'),
        subtitle: Slider(value: _priority, min: 0, max: 15, divisions: 15, onChanged: (v) => setState(() => _priority = v)),
      ),
      const SizedBox(height: 12),
      FilledButton.icon(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(56)),
        onPressed: !online
            ? null
            : () {
                if (_external) {
                  final n = _issi.text.trim();
                  if (n.isEmpty) return;
                  m.dialExternal(n, priority: _priority.round());
                  return;
                }
                final issi = int.tryParse(_issi.text);
                if (issi == null || issi <= 0) return;
                m.dial(issi, duplex: _duplex, hook: _hook, priority: _priority.round());
              },
        icon: const Icon(Icons.call),
        label: const Text('Call'),
      ),
    ]);
  }
}

class _ActiveCall extends StatelessWidget {
  const _ActiveCall({required this.call});
  final PrivateCallInfo call;

  @override
  Widget build(BuildContext context) {
    final m = context.read<TerminalModel>();
    final who = call.number != null
        ? '${call.peerName ?? 'Phone'}\n${call.number}'
        : (call.peerName != null ? '${call.peerName}\n${call.peer}' : '${call.peer}');
    final status = switch (call.state) {
      'setup' || 'proceeding' => 'Calling…',
      'alerting' => 'Ringing…',
      'ringing' => 'Incoming ${call.duplex ? 'call' : 'half-duplex call'}',
      'connecting' => 'Connecting…',
      'connected' => call.duplex ? 'Connected · full duplex' : (call.floor == 'peer' ? 'Other party talking' : 'Connected · press PTT to talk'),
      _ => call.state,
    };
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(children: [
        const Spacer(),
        if (call.priority >= 15) const Chip(label: Text('EMERGENCY'), backgroundColor: Colors.red, labelStyle: TextStyle(color: Colors.white)),
        Text(who, textAlign: TextAlign.center, style: Theme.of(context).textTheme.headlineMedium),
        const SizedBox(height: 8),
        Text(status, style: Theme.of(context).textTheme.titleMedium),
        const Spacer(),
        if (call.state == 'connected' && !call.duplex) const PttButton(),
        if (call.state == 'connected' && call.duplex) _Dtmf(onDigit: m.dtmf),
        const SizedBox(height: 24),
        Row(mainAxisAlignment: MainAxisAlignment.spaceEvenly, children: [
          if (call.state == 'ringing')
            FloatingActionButton.large(heroTag: 'answer', backgroundColor: Colors.green, onPressed: m.answer, child: const Icon(Icons.call, color: Colors.white)),
          FloatingActionButton.large(heroTag: 'hangup', backgroundColor: Colors.red, onPressed: m.hangup, child: const Icon(Icons.call_end, color: Colors.white)),
        ]),
      ]),
    );
  }
}

class _Dtmf extends StatelessWidget {
  const _Dtmf({required this.onDigit});
  final void Function(String) onDigit;

  @override
  Widget build(BuildContext context) {
    const keys = ['1', '2', '3', '4', '5', '6', '7', '8', '9', '*', '0', '#'];
    return SizedBox(
      width: 260,
      child: GridView.count(
        shrinkWrap: true,
        crossAxisCount: 3,
        childAspectRatio: 1.8,
        children: [for (final k in keys) TextButton(onPressed: () => onDigit(k), child: Text(k, style: const TextStyle(fontSize: 22)))],
      ),
    );
  }
}
