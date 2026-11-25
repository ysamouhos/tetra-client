import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../model/settings.dart';
import '../model/terminal_model.dart';
import '../ui/adaptive.dart';
import '../ui/theme.dart';

/// Add or edit a connection profile in a sheet (Cancel · Title · Save).
/// Edits a copy, so Cancel leaves the profile as it was.
Future<void> editProfile(BuildContext context, TerminalModel m, ConnectionProfile? existing) async {
  final isNew = existing == null;
  final p = existing?.copy() ?? ConnectionProfile(id: m.settings.newProfileId(), serverUrl: 'https://');
  final form = GlobalKey<FormState>();
  String? number(String? v) => (v ?? '').isEmpty || int.tryParse(v!) != null ? null : 'Number';

  final saved = await showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: !isApple(context),
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Tokens.radiusLarge))),
    builder: (ctx) => StatefulBuilder(builder: (ctx, setState) {
      final text = Theme.of(ctx).textTheme;
      return Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
        child: Form(
          key: form,
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: Row(children: [
                TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                Expanded(
                  child: Text(isNew ? 'New connection' : 'Edit connection',
                      textAlign: TextAlign.center, style: text.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
                ),
                TextButton(
                  onPressed: () {
                    if (form.currentState!.validate()) Navigator.pop(ctx, 'save');
                  },
                  child: const Text('Save', style: TextStyle(fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
            Flexible(
              child: SingleChildScrollView(
                child: Column(children: [
                  Section(children: [
                    FieldRow(label: 'Name', initial: p.label, hint: 'e.g. TMO Austria', onChanged: (v) => p.label = v),
                  ]),
                  Section(header: 'Server', children: [
                    FieldRow(label: 'URL', initial: p.serverUrl, keyboard: TextInputType.url, hint: 'https://host:9000/brew/', onChanged: (v) => p.serverUrl = v.trim()),
                    FieldRow(label: 'Username', initial: p.username, hint: 'as in [auth.users]', onChanged: (v) => p.username = v.trim()),
                    FieldRow(label: 'Password', initial: p.password, obscure: true, hint: 'Stored in the keychain', onChanged: (v) => p.password = v),
                    SwitchRow(title: 'Accept self-signed certificate', subtitle: 'Lab servers only', value: p.insecureTls, onChanged: (v) => setState(() => p.insecureTls = v)),
                  ]),
                  Section(
                    footer: p.basestation
                        ? 'Logs in like a FlowStation. Only if the server\'s operator lets this app in as a station.'
                        : 'Logs in as an app. Works on every Brew server, TetraPack included.',
                    children: [
                      LabeledSegments<bool>(
                        key: const Key('login-mode'),
                        label: 'Login mode',
                        items: const {false: 'Terminal', true: 'Basestation'},
                        value: p.basestation,
                        onChanged: (v) => setState(() => p.basestation = v),
                      ),
                    ],
                  ),
                  if (p.basestation)
                    Section(
                      header: 'Control channel',
                      footer: 'For DGNA, as a FlowStation gets it. Empty fields use the Brew host on port 9002 and the Brew login; '
                          'the login must be in the server\'s [control.users].',
                      children: [
                        FieldRow(label: 'Host', initial: p.controlUrl, keyboard: TextInputType.url, hint: 'Brew host:9002', onChanged: (v) => p.controlUrl = v.trim()),
                        SwitchRow(title: 'TLS', subtitle: 'wss:// instead of ws://', value: p.controlTls, onChanged: (v) => setState(() => p.controlTls = v)),
                        FieldRow(label: 'Username', initial: p.controlUsername, hint: 'Brew username', onChanged: (v) => p.controlUsername = v.trim()),
                        FieldRow(label: 'Password', initial: p.controlPassword, obscure: true, hint: 'Brew password', onChanged: (v) => p.controlPassword = v),
                      ],
                    ),
                  Section(header: 'Radio', children: [
                    FieldRow(label: 'ISSI', initial: p.issi == 0 ? '' : '${p.issi}', number: true, validator: number, onChanged: (v) => p.issi = int.tryParse(v) ?? 0),
                    FieldRow(label: 'Talker name', initial: p.name, hint: 'Shown to others', onChanged: (v) => p.name = v.trim()),
                    FieldRow(label: 'Outside line', initial: p.externalPrefix, keyboard: TextInputType.phone, hint: 'Prefix for phone calls', onChanged: (v) => p.externalPrefix = v.trim()),
                  ]),
                  Section(
                    header: 'Multi Network',
                    footer: 'Only used when the server offers it. Leave on "This server\'s network" unless your ISSI belongs to another network.',
                    children: [
                      Tile(
                        title: 'Home network',
                        subtitle: p.homeMcc == 0 && p.homeMnc == 0 ? 'This server\'s network' : '${m.networkName(p.homeMcc, p.homeMnc)} · ${p.homeMcc}-${p.homeMnc}',
                        onTap: () async {
                          final picked = await pickHomeNetwork(ctx, m, (p.homeMcc, p.homeMnc));
                          if (picked != null) {
                            setState(() {
                              p.homeMcc = picked.$1;
                              p.homeMnc = picked.$2;
                            });
                          }
                        },
                      ),
                    ],
                  ),
                  if (!isNew && m.settings.profiles.length > 1)
                    Section(children: [
                      Tile(title: 'Delete connection', destructive: true, onTap: () => Navigator.pop(ctx, 'delete')),
                    ]),
                  const SizedBox(height: 12),
                ]),
              ),
            ),
          ]),
        ),
      );
    }),
  );

  if (!context.mounted) return;
  if (saved == 'save') {
    await m.saveProfile(p);
  } else if (saved == 'delete' && existing != null) {
    final ok = await showActions<bool>(context,
        title: 'Delete "${existing.displayName}"?', message: 'Its talkgroups and stored password are removed.', actions: const [
      SheetAction('Delete connection', true, destructive: true),
    ]);
    if (ok == true) await m.deleteProfile(existing);
  }
}

/// Home network picker: this server, a linked network, or MCC/MNC by hand.
Future<(int, int)?> pickHomeNetwork(BuildContext context, TerminalModel m, (int, int) current) async {
  final picked = await showActions<(int, int)>(context, title: 'Home network', message: 'The network your ISSI belongs to.', actions: [
    const SheetAction('This server\'s network', (0, 0)),
    for (final n in m.networks.where((n) => !n.own)) SheetAction('${n.name} (${n.mni})', (n.mcc, n.mnc)),
    const SheetAction('Enter MCC / MNC…', (-1, -1)),
  ]);
  if (picked != (-1, -1) || !context.mounted) return picked;
  var mcc = '${current.$1}', mnc = '${current.$2}';
  final ok = await showFormSheet(context, title: 'Home network', action: 'Done', fields: [
    FieldRow(label: 'MCC', initial: mcc, number: true, onChanged: (v) => mcc = v),
    FieldRow(label: 'MNC', initial: mnc, number: true, onChanged: (v) => mnc = v),
  ]);
  if (!ok) return null;
  return ((int.tryParse(mcc) ?? 0).clamp(0, 1023), (int.tryParse(mnc) ?? 0).clamp(0, 16383));
}

/// One row per profile: tap switches, the info button opens the editor.
class ProfileRow extends StatelessWidget {
  const ProfileRow({super.key, required this.m, required this.p});
  final TerminalModel m;
  final ConnectionProfile p;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final active = p.id == m.settings.activeId;
    return Tile(
      leading: Icon(active ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle, color: active ? scheme.primary : scheme.outline),
      title: p.displayName,
      subtitle: [if (p.issi > 0) 'ISSI ${p.issi}', if (p.talkgroups.isNotEmpty) '${p.talkgroups.length} groups'].join(' · '),
      trailing: IconButton(
        tooltip: 'Edit ${p.displayName}',
        icon: Icon(CupertinoIcons.info_circle, color: scheme.primary),
        onPressed: () => editProfile(context, m, p),
      ),
      onTap: active
          ? () => editProfile(context, m, p)
          : () {
              Haptics.select();
              m.switchProfile(p.id);
            },
    );
  }
}
