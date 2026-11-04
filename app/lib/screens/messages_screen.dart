import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/terminal_model.dart';

class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final peers = <int>[];
    for (final msg in m.messages.reversed) {
      if (!peers.contains(msg.peer)) peers.add(msg.peer);
    }
    String label(int peer) {
      final tg = m.settings.talkgroups.where((t) => t.gssi == peer).firstOrNull;
      return tg != null ? '${tg.name} (group)' : 'ISSI $peer';
    }

    return Scaffold(
      body: peers.isEmpty
          ? const Center(child: Text('No messages'))
          : ListView(children: [
              for (final p in peers)
                ListTile(
                  leading: const Icon(Icons.forum_outlined),
                  title: Text(label(p)),
                  subtitle: Text(m.messages.lastWhere((x) => x.peer == p).text, maxLines: 1, overflow: TextOverflow.ellipsis),
                  trailing: m.locations[p] != null ? const Icon(Icons.location_on_outlined) : null,
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => ConversationScreen(peer: p, title: label(p)))),
                ),
            ]),
      floatingActionButton: FloatingActionButton(
        onPressed: () async {
          final c = TextEditingController();
          final to = await showDialog<int>(
            context: context,
            builder: (ctx) => AlertDialog(
              title: const Text('New message'),
              content: TextField(controller: c, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'ISSI or GSSI')),
              actions: [FilledButton(onPressed: () => Navigator.pop(ctx, int.tryParse(c.text)), child: const Text('Open'))],
            ),
          );
          if (to != null && context.mounted) {
            Navigator.push(context, MaterialPageRoute(builder: (_) => ConversationScreen(peer: to, title: label(to))));
          }
        },
        child: const Icon(Icons.edit),
      ),
    );
  }
}

class ConversationScreen extends StatefulWidget {
  const ConversationScreen({super.key, required this.peer, required this.title});
  final int peer;
  final String title;
  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final _text = TextEditingController();
  bool _flash = false;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final msgs = m.messages.where((x) => x.peer == widget.peer).toList();
    final loc = m.locations[widget.peer];
    return Scaffold(
      appBar: AppBar(title: Text(widget.title)),
      body: Column(children: [
        if (loc != null)
          ListTile(
            dense: true,
            leading: const Icon(Icons.location_on),
            title: Text('${loc.location.latitude.toStringAsFixed(5)}, ${loc.location.longitude.toStringAsFixed(5)}'),
            subtitle: Text('LIP · ${TimeOfDay.fromDateTime(loc.time).format(context)}'
                '${loc.location.speedKmh != null ? ' · ${loc.location.speedKmh!.round()} km/h' : ''}'),
          ),
        Expanded(
          child: ListView.builder(
            reverse: true,
            itemCount: msgs.length,
            itemBuilder: (_, i) {
              final msg = msgs[msgs.length - 1 - i];
              final scheme = Theme.of(context).colorScheme;
              return Align(
                alignment: msg.outgoing ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  constraints: const BoxConstraints(maxWidth: 300),
                  decoration: BoxDecoration(
                    color: msg.outgoing ? scheme.primaryContainer : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(12),
                    border: msg.immediate ? Border.all(color: scheme.error) : null,
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    Text(msg.text),
                    const SizedBox(height: 2),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(TimeOfDay.fromDateTime(msg.time).format(context), style: Theme.of(context).textTheme.labelSmall),
                      if (msg.outgoing) ...[const SizedBox(width: 4), _StatusIcon(msg.status)],
                    ]),
                  ]),
                ),
              );
            },
          ),
        ),
        SafeArea(
          child: Row(children: [
            IconButton(
              tooltip: 'Flash (immediate) message',
              icon: Icon(Icons.bolt, color: _flash ? Theme.of(context).colorScheme.error : null),
              onPressed: () => setState(() => _flash = !_flash),
            ),
            Expanded(
              child: TextField(controller: _text, maxLength: 120, decoration: const InputDecoration(hintText: 'Message', counterText: '')),
            ),
            IconButton(
              icon: const Icon(Icons.send),
              onPressed: m.link != LinkState.online
                  ? null
                  : () {
                      final t = _text.text.trim();
                      if (t.isEmpty) return;
                      m.sendText(widget.peer, t, immediate: _flash);
                      _text.clear();
                    },
            ),
          ]),
        ),
      ]),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon(this.status);
  final MsgStatus status;
  @override
  Widget build(BuildContext context) => Icon(
        switch (status) {
          MsgStatus.sending => Icons.schedule,
          MsgStatus.sent || MsgStatus.networkAccepted => Icons.done,
          MsgStatus.delivered => Icons.done_all,
          MsgStatus.failed => Icons.error_outline,
          MsgStatus.received => Icons.done,
        },
        size: 14,
        color: status == MsgStatus.failed ? Theme.of(context).colorScheme.error : null,
      );
}
