import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/settings.dart';
import '../model/terminal_model.dart';
import '../ui/adaptive.dart';
import '../ui/theme.dart';
import 'home_screen.dart';

/// The radio: who is on air, the talkgroups, and PTT in the thumb zone.
class TalkgroupsScreen extends StatelessWidget {
  const TalkgroupsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final tgs = m.settings.talkgroups;
    final scheme = Theme.of(context).colorScheme;
    final title = m.settings.name.isNotEmpty ? m.settings.name : (m.settings.issi > 0 ? 'ISSI ${m.settings.issi}' : 'Radio');

    return TabPage(
      title: title,
      actions: [
        const LinkPill(),
        IconButton(
          tooltip: 'Add talkgroup',
          icon: Icon(pick(context, Icons.add, CupertinoIcons.add)),
          onPressed: () => editTalkgroup(context, m, null),
        ),
      ],
      slivers: [
        const SliverToBoxAdapter(child: Padding(padding: EdgeInsets.only(top: 4, bottom: 8), child: NowCard())),
        if (tgs.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(children: [
                Icon(CupertinoIcons.person_3, size: 44, color: scheme.outline),
                const SizedBox(height: 12),
                Text('No talkgroups yet', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('Add the groups (GSSI) you want to talk and listen on.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                FilledButton(onPressed: () => editTalkgroup(context, m, null), child: const Text('Add talkgroup')),
              ]),
            ),
          )
        else
          SliverToBoxAdapter(
            child: Section(
              header: 'Talkgroups',
              footer: 'Tap to select. The ear icon scans a group so you hear it too. Long press to edit.',
              children: [for (final t in tgs) _TalkgroupRow(t)],
            ),
          ),
      ],
      bottom: isApple(context)
          ? const PttButton()
          : Container(
              padding: const EdgeInsets.fromLTRB(Tokens.gutter, 14, Tokens.gutter, 18),
              decoration: BoxDecoration(color: scheme.surface, border: Border(top: BorderSide(color: scheme.outlineVariant.withValues(alpha: .5), width: .5))),
              child: const PttButton(),
            ),
    );
  }
}

class _TalkgroupRow extends StatelessWidget {
  const _TalkgroupRow(this.t);
  final Talkgroup t;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final active = m.groupActivity[t.gssi];
    final selected = t.gssi == m.selectedGssi;
    final access = m.accessOf(t);
    final subtitle = active != null
        ? '${active.emergency ? 'EMERGENCY · ' : ''}${m.nameOf(active.talker, sentName: active.talkerName)} talking'
        : [
            'GSSI ${t.gssi}',
            if (t.otherNetwork) m.networkName(t.mcc, t.mnc),
            if (t.dgna) 'DGNA',
            if (access == GroupAccess.listen) 'listen only',
            if (access == GroupAccess.refused) 'not allowed',
            if (t.scan && !selected) 'scanning',
          ].join(' · ');

    return GestureDetector(
      onLongPress: () => editTalkgroup(context, m, t),
      child: Opacity(
        opacity: access == GroupAccess.refused ? .45 : 1,
        child: Tile(
          title: t.name,
          subtitle: subtitle,
          leading: Icon(
            selected ? CupertinoIcons.checkmark_circle_fill : CupertinoIcons.circle,
            color: selected ? scheme.primary : scheme.outline,
          ),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (active != null) Icon(CupertinoIcons.waveform, color: active.emergency ? Tokens.emergency : scheme.primary),
            IconButton(
              tooltip: t.scan ? 'Stop scanning' : 'Scan this group',
              icon: Icon(t.scan ? CupertinoIcons.ear : CupertinoIcons.ear, color: t.scan ? scheme.primary : scheme.outline.withValues(alpha: .5)),
              onPressed: () {
                Haptics.select();
                t.scan = !t.scan;
                m.saveTalkgroups();
              },
            ),
          ]),
          onTap: () {
            Haptics.select();
            m.selectGroup(t.gssi);
          },
        ),
      ),
    );
  }
}

/// Add or edit a talkgroup in a sheet. With Multi Network the group can be
/// one of a linked network.
Future<void> editTalkgroup(BuildContext context, TerminalModel m, Talkgroup? existing) async {
  var gssi = existing?.gssi.toString() ?? '';
  var name = existing?.name ?? '';
  var net = (existing?.mcc ?? 0, existing?.mnc ?? 0);
  final nets = m.networks;

  if (existing != null) {
    final action = await showActions<String>(context, title: existing.name, message: 'GSSI ${existing.gssi}', actions: const [
      SheetAction('Edit', 'edit'),
      SheetAction('Remove', 'remove', destructive: true),
    ]);
    if (action == null || !context.mounted) return;
    if (action == 'remove') {
      m.settings.talkgroups.remove(existing);
      await m.saveTalkgroups();
      return;
    }
  }

  final ok = await showFormSheet(context, title: existing == null ? 'New talkgroup' : 'Edit talkgroup', action: existing == null ? 'Add' : 'Save', fields: [
    if (existing == null) FieldRow(label: 'GSSI', initial: gssi, number: true, hint: 'e.g. 91', onChanged: (v) => gssi = v),
    FieldRow(label: 'Name', initial: name, hint: 'Optional', onChanged: (v) => name = v),
    if (nets.length > 1)
      StatefulBuilder(
        builder: (ctx, setState) => Tile(
          title: 'Network',
          subtitle: net == (0, 0) ? 'Home network' : m.networkName(net.$1, net.$2),
          onTap: () async {
            final picked = await showActions<(int, int)>(ctx, title: 'Network of this group', actions: [
              const SheetAction('Home network', (0, 0)),
              for (final n in nets.where((n) => !n.own)) SheetAction('${n.name}${n.up ? '' : ' (offline)'}', (n.mcc, n.mnc)),
            ]);
            if (picked != null) setState(() => net = picked);
          },
        ),
      ),
  ]);
  if (!ok) return;
  final g = int.tryParse(gssi.trim());
  if (g == null || g <= 0 || g > 0xFFFFFF) return;
  final label = name.trim().isEmpty ? 'TG $g' : name.trim();
  if (existing != null) {
    existing
      ..name = label
      ..mcc = net.$1
      ..mnc = net.$2;
  } else if (!m.settings.talkgroups.any((t) => t.gssi == g)) {
    m.settings.talkgroups.add(Talkgroup(g, label, mcc: net.$1, mnc: net.$2));
  }
  await m.saveTalkgroups();
}
