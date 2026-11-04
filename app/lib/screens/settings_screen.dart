import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/settings.dart';
import '../model/terminal_model.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});
  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _form = GlobalKey<FormState>();
  late Settings s;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      s = context.read<TerminalModel>().settings;
      _loaded = true;
    }
  }

  Widget _text(String label, String initial, void Function(String) save, {bool number = false, bool obscure = false, String? hint}) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: TextFormField(
          initialValue: initial,
          obscureText: obscure,
          keyboardType: number ? TextInputType.number : TextInputType.text,
          decoration: InputDecoration(labelText: label, hintText: hint, border: const OutlineInputBorder()),
          validator: number ? (v) => int.tryParse(v ?? '') == null ? 'Number required' : null : null,
          // Store on every keystroke: fields scrolled off screen must not lose input.
          onChanged: (v) {
            if (!number || int.tryParse(v) != null) save(v);
          },
          onSaved: (v) => save(v ?? ''),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    return Form(
      key: _form,
      // A Column inside a scroll view keeps every field alive (ListView disposes off-screen ones).
      child: SingleChildScrollView(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('Server', style: Theme.of(context).textTheme.titleMedium),
        _text('Brew server URL', s.serverUrl, (v) => s.serverUrl = v.trim(), hint: 'http://host:9000/brew/  or  https://…'),
        _text('Username', s.username, (v) => s.username = v.trim(), hint: 'as in [auth.users]'),
        _text('Password', s.password, (v) => s.password = v, obscure: true),
        SwitchListTile(
          title: const Text('Accept self-signed certificate'),
          subtitle: const Text('Lab servers only'),
          value: s.insecureTls,
          onChanged: (v) => setState(() => s.insecureTls = v),
        ),
        _text('Outside-line prefix (phone calls)', s.externalPrefix, (v) => s.externalPrefix = v.trim(),
            hint: 'e.g. 9, as in your server\'s SIP voice route; leave empty if none'),
        const Divider(),
        Text('Terminal', style: Theme.of(context).textTheme.titleMedium),
        _text('ISSI', s.issi == 0 ? '' : '${s.issi}', (v) => s.issi = int.parse(v), number: true),
        _text('Talker name (shown to others)', s.name, (v) => s.name = v.trim()),
        ListTile(
          title: Text('Default call priority: ${s.defaultPriority}'),
          subtitle: Slider(value: s.defaultPriority.toDouble(), min: 0, max: 11, divisions: 11, onChanged: (v) => setState(() => s.defaultPriority = v.round())),
        ),
        SwitchListTile(
          title: const Text('Allow pre-emption'),
          subtitle: const Text('Calls of priority 12–15 may interrupt lower calls here'),
          value: s.allowPreemption,
          onChanged: (v) => setState(() => s.allowPreemption = v),
        ),
        ListTile(
          title: Text('Microphone gain: ${s.micGainDb >= 0 ? '+' : ''}${s.micGainDb.round()} dB'),
          subtitle: Slider(
            value: s.micGainDb,
            min: -12,
            max: 12,
            divisions: 24,
            onChanged: (v) {
              setState(() => s.micGainDb = v);
              m.audio.micGainDb = v; // live: takes effect on the next transmission
            },
          ),
        ),
        const Divider(),
        Text('Location (LIP)', style: Theme.of(context).textTheme.titleMedium),
        SwitchListTile(title: const Text('Send location reports'), value: s.lipEnabled, onChanged: (v) => setState(() => s.lipEnabled = v)),
        if (s.lipEnabled) ...[
          _text('LIP destination ISSI', s.lipDestination == 0 ? '' : '${s.lipDestination}', (v) => s.lipDestination = int.parse(v), number: true),
          _text('Interval (seconds)', '${s.lipIntervalSeconds}', (v) => s.lipIntervalSeconds = int.parse(v).clamp(10, 3600), number: true),
          SwitchListTile(title: const Text('Also send on PTT'), value: s.lipOnPtt, onChanged: (v) => setState(() => s.lipOnPtt = v)),
          TextButton.icon(onPressed: m.sendLocationNow, icon: const Icon(Icons.my_location), label: const Text('Send position now')),
        ],
        const SizedBox(height: 16),
        FilledButton(
          onPressed: () async {
            if (!_form.currentState!.validate()) return;
            _form.currentState!.save();
            await m.applySettings(s);
            if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved, reconnecting…')));
          },
          child: const Text('Save and connect'),
        ),
      ])),
    );
  }
}
