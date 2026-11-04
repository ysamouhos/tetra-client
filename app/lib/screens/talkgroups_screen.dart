import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/settings.dart';
import '../model/terminal_model.dart';
import 'home_screen.dart';

class TalkgroupsScreen extends StatelessWidget {
  const TalkgroupsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final tgs = m.settings.talkgroups;
    return Column(children: [
      Expanded(
        child: tgs.isEmpty
            ? const Center(child: Text('No talkgroups yet. Add one with +'))
            : ListView.builder(
                itemCount: tgs.length,
                itemBuilder: (_, i) {
                  final t = tgs[i];
                  final active = m.groupActivity[t.gssi];
                  final selected = t.gssi == m.selectedGssi;
                  return ListTile(
                    selected: selected,
                    leading: Icon(selected ? Icons.radio_button_checked : Icons.radio_button_unchecked),
                    title: Text(t.name),
                    subtitle: Text(active == null
                        ? 'GSSI ${t.gssi}${t.scan ? ' · scan' : ''}'
                        : '${active.emergency ? 'EMERGENCY · ' : ''}${active.talkerName ?? active.talker} talking'),
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (active != null) Icon(Icons.graphic_eq, color: active.emergency ? Colors.red : null),
                      IconButton(
                        tooltip: t.scan ? 'Stop scanning' : 'Scan',
                        icon: Icon(t.scan ? Icons.hearing : Icons.hearing_disabled),
                        onPressed: () {
                          t.scan = !t.scan;
                          m.saveTalkgroups();
                        },
                      ),
                    ]),
                    onTap: () => m.selectGroup(t.gssi),
                    onLongPress: () => _edit(context, m, t),
                  );
                },
              ),
      ),
      const Padding(padding: EdgeInsets.symmetric(vertical: 24), child: PttButton()),
      Align(
        alignment: Alignment.centerRight,
        child: Padding(
          padding: const EdgeInsets.only(right: 16, bottom: 8),
          child: FloatingActionButton.small(onPressed: () => _edit(context, m, null), child: const Icon(Icons.add)),
        ),
      ),
    ]);
  }

  Future<void> _edit(BuildContext context, TerminalModel m, Talkgroup? existing) async {
    final gssi = TextEditingController(text: existing?.gssi.toString() ?? '');
    final name = TextEditingController(text: existing?.name ?? '');
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(existing == null ? 'Add talkgroup' : 'Edit talkgroup'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(controller: gssi, enabled: existing == null, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'GSSI')),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
        ]),
        actions: [
          if (existing != null) TextButton(onPressed: () => Navigator.pop(ctx, 'delete'), child: const Text('Remove')),
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, 'save'), child: const Text('Save')),
        ],
      ),
    );
    if (result == 'delete' && existing != null) {
      m.settings.talkgroups.remove(existing);
    } else if (result == 'save') {
      final g = int.tryParse(gssi.text.trim());
      if (g == null || g <= 0 || g > 0xFFFFFF) return;
      if (existing != null) {
        existing.name = name.text.trim().isEmpty ? 'TG $g' : name.text.trim();
      } else if (!m.settings.talkgroups.any((t) => t.gssi == g)) {
        m.settings.talkgroups.add(Talkgroup(g, name.text.trim().isEmpty ? 'TG $g' : name.text.trim()));
      }
    } else {
      return;
    }
    await m.saveTalkgroups();
  }
}
