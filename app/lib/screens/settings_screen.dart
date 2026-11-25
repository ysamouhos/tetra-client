import 'dart:io' show Platform;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../model/settings.dart';
import '../model/terminal_model.dart';
import '../services/version.dart';
import '../ui/adaptive.dart';
import '../ui/theme.dart';
import 'home_screen.dart';
import 'profile_sheet.dart';

/// Auto-stop of the Live Activity PTT (seconds; 0 = off).
const pttAutoStopChoices = {0: 'Off', 30: '30 s', 60: '1 min', 120: '2 min', 300: '5 min'};

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

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;

    return Form(
      key: _form,
      child: TabPage(
        title: 'Settings',
        actions: [
          TextButton(
            onPressed: () async {
              if (!_form.currentState!.validate()) return;
              _form.currentState!.save();
              await m.applySettings(s);
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved')));
            },
            child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w600)),
          ),
        ],
        slivers: [
          SliverToBoxAdapter(
            // A Column keeps every field alive (a lazy list disposes off-screen ones).
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Section(
                header: 'Connections',
                footer: m.lastError ?? 'Tap a connection to switch to it. Server, ISSI and home network are set per connection.',
                children: [
                  for (final p in s.profiles) ProfileRow(key: ValueKey(p.id), m: m, p: p),
                  Tile(
                    title: 'Add connection',
                    leading: Icon(CupertinoIcons.add_circled_solid, color: scheme.primary),
                    onTap: () => editProfile(context, m, null),
                  ),
                ],
              ),
              const Section(children: [Tile(title: 'Status', trailing: LinkPill())]),
              Section(header: 'Radio', children: [
                SliderRow(
                  title: 'Default priority',
                  valueLabel: 'P${s.defaultPriority}',
                  value: s.defaultPriority.toDouble(),
                  min: 0,
                  max: 11,
                  divisions: 11,
                  onChanged: (v) => setState(() => s.defaultPriority = v.round()),
                ),
                LabeledSegments<bool>(
                  label: 'PTT button',
                  items: const {false: 'Hold to talk', true: 'Toggle'},
                  value: s.pttToggle,
                  onChanged: m.setPttToggle,
                ),
                LabeledSegments<int>(
                  label: isApple(context) ? 'Toggle and Live Activity stop after' : 'Toggle and notification stop after',
                  items: pttAutoStopChoices,
                  value: pttAutoStopChoices.containsKey(s.pttAutoStopSeconds) ? s.pttAutoStopSeconds : 60,
                  onChanged: m.setPttAutoStop,
                ),
                SwitchRow(title: 'Allow pre-emption', subtitle: 'Calls of priority 12–15 may interrupt lower calls', value: s.allowPreemption, onChanged: (v) => setState(() => s.allowPreemption = v)),
              ]),
              if (m.multiNetwork)
                Section(
                  header: 'Linked networks',
                  footer: 'This server links networks (Multi Network). Groups of other networks are set per talkgroup.',
                  children: [
                    for (final n in m.networks)
                      Tile(
                        title: n.name,
                        subtitle: n.mni,
                        trailing: n.own ? null : Text(n.up ? 'linked' : 'offline', style: TextStyle(color: n.up ? Tokens.online : scheme.outline)),
                      ),
                  ],
                ),
              Section(
                header: 'Contacts database',
                footer: m.contacts.radioIdError ??
                    'Callsigns for ISSIs from RadioID.net (DMR IDs, as used on ham TETRA networks). Your own contacts always come first.',
                children: [
                  Tile(
                    title: 'RadioID.net',
                    subtitle: _radioIdStatus(m),
                    trailing: m.contacts.updating
                        ? const Padding(padding: EdgeInsets.only(right: 8), child: CupertinoActivityIndicator())
                        : TextButton(onPressed: m.contacts.updateRadioId, child: const Text('Update now')),
                  ),
                  SwitchRow(title: 'Update weekly', subtitle: 'In the background, when the app starts', value: m.contacts.radioIdAuto, onChanged: m.contacts.setRadioIdAuto),
                ],
              ),
              Section(header: 'Appearance', children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: Tokens.gutter, vertical: 10),
                  child: SizedBox(
                    width: double.infinity,
                    child: Segments<String>(
                      items: const {'system': 'Automatic', 'light': 'Light', 'dark': 'Dark'},
                      value: s.appearance,
                      onChanged: m.setAppearance,
                    ),
                  ),
                ),
                if (isApple(context))
                  SwitchRow(
                    title: 'Live Activity',
                    subtitle: 'Group, talker and time on the Lock Screen and in the Dynamic Island, with a tap-to-talk button',
                    value: s.liveActivity,
                    onChanged: m.setLiveActivity,
                  )
                else if (Platform.isAndroid)
                  SwitchRow(
                    title: 'Live notification',
                    subtitle: 'Group, talker and time in the status bar and on the lock screen, with a Talk button. Keeps the app running in the background',
                    value: s.liveActivity,
                    onChanged: (v) async {
                      if (v) await Permission.notification.request();
                      await m.setLiveActivity(v);
                    },
                  ),
              ]),
              Section(header: 'Audio', footer: 'In the background the app keeps a silent audio stream open so calls still come in with the screen locked. Uses some battery.', children: [
                SwitchRow(title: 'Run in the background', value: s.backgroundAudio, onChanged: (v) => setState(() => s.backgroundAudio = v)),
                SliderRow(
                  title: 'Mic gain',
                  valueLabel: '${s.micGainDb >= 0 ? '+' : ''}${s.micGainDb.round()} dB',
                  value: s.micGainDb,
                  min: -12,
                  max: 12,
                  divisions: 24,
                  onChanged: (v) {
                    setState(() => s.micGainDb = v);
                    m.audio.micGainDb = v; // live: takes effect on the next transmission
                  },
                ),
              ]),
              if (Platform.isAndroid)
                Section(header: 'Bluetooth PTT headset', children: [
                  SwitchRow(
                    title: 'Use Savox BTH-101 PTT',
                    subtitle: m.pttDeviceStatus ?? 'Pair the headset in Android Bluetooth settings first (PIN 0000)',
                    value: s.headsetEnabled,
                    onChanged: (v) async {
                      if (v) await Permission.bluetoothConnect.request();
                      setState(() => s.headsetEnabled = v);
                    },
                  ),
                  if (s.headsetEnabled)
                    FieldRow(label: 'Address', initial: s.headsetAddress, hint: 'Empty = first paired Savox', onChanged: (v) => s.headsetAddress = v.trim()),
                ]),
              Section(header: 'Location (LIP)', children: [
                SwitchRow(title: 'Send location reports', value: s.lipEnabled, onChanged: (v) => setState(() => s.lipEnabled = v)),
                if (s.lipEnabled) ...[
                  FieldRow(label: 'Send to ISSI', initial: s.lipDestination == 0 ? '' : '${s.lipDestination}', number: true, onChanged: (v) => s.lipDestination = int.tryParse(v) ?? 0),
                  FieldRow(label: 'Every (s)', initial: '${s.lipIntervalSeconds}', number: true, onChanged: (v) => s.lipIntervalSeconds = (int.tryParse(v) ?? 60).clamp(10, 3600)),
                  SwitchRow(title: 'Also send on PTT', value: s.lipOnPtt, onChanged: (v) => setState(() => s.lipOnPtt = v)),
                  Tile(title: 'Send position now', leading: Icon(CupertinoIcons.location_fill, color: scheme.primary), onTap: m.sendLocationNow),
                ],
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(Tokens.gutter, 16, Tokens.gutter, 8),
                child: DefaultTextStyle.merge(
                  textAlign: TextAlign.center,
                  style: TextStyle(color: scheme.outline, fontSize: 12, height: 1.5),
                  child: Column(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(11),
                      child: Image.asset('assets/icon/app_icon_small.png', width: 48, height: 48, semanticLabel: 'TETRA Terminal'),
                    ),
                    const SizedBox(height: 8),
                    Text('TETRA Terminal v$appVersion · © 2026', style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 6),
                    const Credit(role: 'Creator', name: 'ysamouhos', github: 'ysamouhos'),
                    const SizedBox(height: 10),
                    const Credit(role: 'Redesign & advanced features', name: 'sebastianmadl (OE4SXM)', github: 'sebastianmadl'),
                    const SizedBox(height: 6),
                    if (m.extensions.isNotEmpty) Text('Server offers: ${m.extensions.join(', ')}', style: const TextStyle(fontSize: 11)),
                    if (m.settings.basestation && m.link != LinkState.offline)
                      Text('Control channel: ${m.controlOnline ? 'connected' : m.controlError ?? 'connecting'}', style: const TextStyle(fontSize: 11)),
                  ]),
                ),
              ),
            ]),
          ),
        ],
      ),
    );
  }

  String _radioIdStatus(TerminalModel m) {
    final c = m.contacts;
    if (c.updating) return 'Downloading…';
    if (c.radioIdCount == 0) return 'Not loaded';
    final n = c.radioIdCount.toString().replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
    final t = c.radioIdUpdated;
    if (t == null) return '$n IDs';
    const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    return '$n IDs · updated ${t.day} ${months[t.month - 1]}, ${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
  }
}

/// Role, name and the GitHub profile link below. The link keeps the text colour
/// (black in light, white in dark mode) and is only underlined.
class Credit extends StatelessWidget {
  const Credit({super.key, required this.role, required this.name, required this.github});
  final String role;
  final String name;
  final String github;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final url = 'https://github.com/$github';
    return Column(children: [
      Text(role.toUpperCase(), style: TextStyle(color: scheme.outline, fontSize: 10.5, letterSpacing: .6, fontWeight: FontWeight.w600)),
      Text(name, style: TextStyle(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w500)),
      Semantics(
        link: true,
        label: 'GitHub profile of $github',
        child: GestureDetector(
          onTap: () => launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
          child: Text('github.com/$github',
              style: TextStyle(color: scheme.onSurface, decoration: TextDecoration.underline, decorationColor: scheme.onSurface)),
        ),
      ),
    ]);
  }
}
