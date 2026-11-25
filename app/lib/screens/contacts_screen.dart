import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/contacts.dart';
import '../model/terminal_model.dart';
import '../ui/adaptive.dart';
import '../ui/theme.dart';
import 'home_screen.dart';
import 'messages_screen.dart';

/// Own contacts (ISSI and name). The RadioID.net database is not listed here;
/// it only fills in names elsewhere (Settings shows how many are loaded).
class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key, this.onCall});
  /// Opens the keypad with this ISSI.
  final void Function(int issi)? onCall;
  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final q = _query.trim().toLowerCase();
    final list = m.contacts.contacts.where((c) => q.isEmpty || c.name.toLowerCase().contains(q) || '${c.issi}'.contains(q)).toList();

    return TabPage(
      title: 'Contacts',
      actions: [
        IconButton(
          tooltip: 'Add contact',
          icon: Icon(pick(context, Icons.person_add_alt, CupertinoIcons.add)),
          onPressed: () => editContact(context, m, null),
        ),
      ],
      slivers: [
        if (m.contacts.contacts.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(Tokens.gutter, 4, Tokens.gutter, 4),
              child: isApple(context)
                  ? CupertinoSearchTextField(placeholder: 'Name or ISSI', onChanged: (v) => setState(() => _query = v))
                  : TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Name or ISSI'), onChanged: (v) => setState(() => _query = v)),
            ),
          ),
        if (m.contacts.contacts.isEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(children: [
                Icon(CupertinoIcons.person_crop_circle, size: 48, color: scheme.outline),
                const SizedBox(height: 12),
                Text('No contacts yet', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('Save ISSIs with a name. Your names are shown instead of the ones from RadioID.net.',
                    textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
                const SizedBox(height: 12),
                FilledButton(onPressed: () => editContact(context, m, null), child: const Text('Add contact')),
              ]),
            ),
          )
        else
          SliverToBoxAdapter(
            child: Section(children: [
              for (final c in list)
                Tile(
                  key: ValueKey(c.issi),
                  leading: Avatar(c.name, size: 36),
                  title: c.name,
                  subtitle: [
                    'ISSI ${c.issi}',
                    if (m.contacts.radioIdOf(c.issi) case final r? when r.callsign != c.name) r.callsign,
                    if (c.note.isNotEmpty) c.note,
                  ].join(' · '),
                  onTap: () => _actions(context, m, c),
                ),
            ]),
          ),
      ],
    );
  }

  Future<void> _actions(BuildContext context, TerminalModel m, Contact c) async {
    final a = await showActions<String>(context, title: c.name, message: 'ISSI ${c.issi}', actions: const [
      SheetAction('Call', 'call'),
      SheetAction('Message', 'message'),
      SheetAction('Edit', 'edit'),
      SheetAction('Delete', 'delete', destructive: true),
    ]);
    if (!context.mounted) return;
    switch (a) {
      case 'call':
        widget.onCall?.call(c.issi);
      case 'message':
        await Navigator.push(context, CupertinoPageRoute(builder: (_) => ConversationScreen(peer: c.issi, title: c.name)));
      case 'edit':
        await editContact(context, m, c);
      case 'delete':
        await m.contacts.remove(c);
    }
  }
}

/// Add or edit a contact. An empty name takes the RadioID callsign.
Future<void> editContact(BuildContext context, TerminalModel m, Contact? existing, {int? issi}) async {
  var number = existing?.issi.toString() ?? (issi?.toString() ?? '');
  var name = existing?.name ?? '';
  var note = existing?.note ?? '';
  final hint = issi != null ? m.contacts.radioIdOf(issi) : null;
  final ok = await showFormSheet(context, title: existing == null ? 'New contact' : 'Edit contact', action: existing == null ? 'Add' : 'Save', fields: [
    if (existing == null) FieldRow(label: 'ISSI', initial: number, number: true, hint: 'e.g. 2320972', onChanged: (v) => number = v),
    FieldRow(label: 'Name', initial: name, hint: hint != null ? '${hint.callsign} ${hint.firstName}'.trim() : 'Callsign or name', onChanged: (v) => name = v),
    FieldRow(label: 'Note', initial: note, hint: 'Optional', onChanged: (v) => note = v),
  ]);
  if (!ok) return;
  final n = int.tryParse(number.trim());
  if (n == null || n <= 0 || n > 0xFFFFFF) return;
  final r = m.contacts.radioIdOf(n);
  final label = name.trim().isNotEmpty ? name.trim() : (r != null ? '${r.callsign} ${r.firstName}'.trim() : 'ISSI $n');
  await m.contacts.put(Contact(n, label, note: note.trim()));
}

/// Round initials, as in Messages and Phone.
class Avatar extends StatelessWidget {
  const Avatar(this.name, {super.key, this.size = 40});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final words = name.replaceAll(RegExp(r'[^\p{L}\p{N}]+', unicode: true), ' ').trim().split(' ').where((w) => w.isNotEmpty);
    final initials = words.isEmpty ? '?' : words.take(2).map((w) => w[0].toUpperCase()).join();
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [scheme.outline.withValues(alpha: .55), scheme.outline.withValues(alpha: .8)]),
      ),
      child: Text(initials, style: TextStyle(color: Colors.white, fontSize: size * .38, fontWeight: FontWeight.w600)),
    );
  }
}
