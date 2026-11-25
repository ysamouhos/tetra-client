import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/terminal_model.dart';
import '../ui/adaptive.dart';
import '../ui/theme.dart';
import 'home_screen.dart';

String _time(BuildContext context, DateTime t) {
  final now = DateTime.now();
  if (now.difference(t).inHours < 24 && now.day == t.day) return TimeOfDay.fromDateTime(t).format(context);
  return '${t.day}.${t.month}.';
}

/// SDS conversations: one row per peer (radio or group).
class MessagesScreen extends StatelessWidget {
  const MessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final peers = <int>[];
    for (final msg in m.messages.reversed) {
      if (!peers.contains(msg.peer)) peers.add(msg.peer);
    }
    String label(int peer) {
      final tg = m.settings.talkgroups.where((t) => t.gssi == peer).firstOrNull;
      return tg != null ? tg.name : m.nameOf(peer);
    }

    bool isGroup(int peer) => m.settings.talkgroups.any((t) => t.gssi == peer);

    return TabPage(
      title: 'Messages',
      actions: [
        IconButton(
          tooltip: 'New message',
          icon: Icon(pick(context, Icons.edit_outlined, CupertinoIcons.square_pencil)),
          onPressed: () async {
            var to = '';
            final ok = await showFormSheet(context, title: 'New message', action: 'Open', fields: [
              FieldRow(label: 'To', initial: '', number: true, hint: 'ISSI or GSSI', onChanged: (v) => to = v),
            ]);
            final n = int.tryParse(to);
            if (ok && n != null && n > 0 && context.mounted) {
              Navigator.push(context, CupertinoPageRoute(builder: (_) => ConversationScreen(peer: n, title: label(n))));
            }
          },
        ),
      ],
      slivers: [
        if (peers.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(CupertinoIcons.chat_bubble_2, size: 48, color: scheme.outline),
                const SizedBox(height: 12),
                Text('No messages', style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text('Short data messages (SDS) to radios and groups show up here.', textAlign: TextAlign.center, style: TextStyle(color: scheme.onSurfaceVariant)),
              ]),
            ),
          )
        else
          SliverToBoxAdapter(
            child: Section(children: [
              for (final p in peers)
                Builder(builder: (context) {
                  final last = m.messages.lastWhere((x) => x.peer == p);
                  return Tile(
                    leading: CircleAvatar(
                      radius: 20,
                      backgroundColor: isGroup(p) ? scheme.primary : scheme.surfaceContainerHigh,
                      child: Icon(isGroup(p) ? CupertinoIcons.person_3_fill : CupertinoIcons.person_fill, size: 20, color: isGroup(p) ? Colors.white : scheme.onSurfaceVariant),
                    ),
                    title: label(p),
                    subtitle: '${last.outgoing ? 'You: ' : ''}${last.text}',
                    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                      if (m.locations[p] != null) Icon(CupertinoIcons.location_solid, size: 14, color: scheme.outline),
                      const SizedBox(width: 4),
                      Text(_time(context, last.time), style: TextStyle(color: scheme.outline, fontSize: 13)),
                      if (isApple(context)) const CupertinoListTileChevron(),
                    ]),
                    onTap: () => Navigator.push(context, CupertinoPageRoute(builder: (_) => ConversationScreen(peer: p, title: label(p)))),
                  );
                }),
            ]),
          ),
      ],
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
    final scheme = Theme.of(context).colorScheme;
    final msgs = m.messages.where((x) => x.peer == widget.peer).toList();
    final loc = m.locations[widget.peer];
    final outgoingColor = isApple(context) ? const Color(0xFF0A84FF) : scheme.primary;

    void send() {
      final t = _text.text.trim();
      if (t.isEmpty || m.link != LinkState.online) return;
      Haptics.select();
      m.sendText(widget.peer, t, immediate: _flash);
      _text.clear();
      setState(() => _flash = false);
    }

    return Scaffold(
      appBar: AppBar(title: Text(widget.title), centerTitle: isApple(context)),
      body: Column(children: [
        if (loc != null)
          Container(
            margin: const EdgeInsets.fromLTRB(Tokens.gutter, 4, Tokens.gutter, 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(Tokens.radius)),
            child: Row(children: [
              Icon(CupertinoIcons.location_solid, size: 18, color: scheme.primary),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '${loc.location.latitude.toStringAsFixed(5)}, ${loc.location.longitude.toStringAsFixed(5)}'
                  '${loc.location.speedKmh != null ? ' · ${loc.location.speedKmh!.round()} km/h' : ''}',
                ),
              ),
              Text(TimeOfDay.fromDateTime(loc.time).format(context), style: TextStyle(color: scheme.outline)),
            ]),
          ),
        Expanded(
          child: ListView.builder(
            reverse: true,
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: msgs.length,
            itemBuilder: (_, i) {
              final msg = msgs[msgs.length - 1 - i];
              final fg = msg.outgoing ? Colors.white : scheme.onSurface;
              return Align(
                alignment: msg.outgoing ? Alignment.centerRight : Alignment.centerLeft,
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
                  constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * .75),
                  decoration: BoxDecoration(
                    color: msg.outgoing ? outgoingColor : scheme.surfaceContainerHigh,
                    borderRadius: BorderRadius.circular(18),
                    border: msg.immediate ? Border.all(color: Tokens.emergency, width: 2) : null,
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                    if (msg.immediate) Text('FLASH', style: TextStyle(color: msg.outgoing ? Colors.white : Tokens.emergency, fontSize: 11, fontWeight: FontWeight.w700)),
                    Text(msg.text, style: TextStyle(color: fg, fontSize: 16)),
                    const SizedBox(height: 2),
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Text(TimeOfDay.fromDateTime(msg.time).format(context), style: TextStyle(color: fg.withValues(alpha: .7), fontSize: 11)),
                      if (msg.outgoing) ...[const SizedBox(width: 4), _StatusIcon(msg.status, color: fg.withValues(alpha: .8))],
                    ]),
                  ]),
                ),
              );
            },
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              IconButton(
                tooltip: _flash ? 'Flash message on' : 'Send as flash (immediate) message',
                icon: Icon(_flash ? CupertinoIcons.bolt_fill : CupertinoIcons.bolt, color: _flash ? Tokens.emergency : scheme.outline),
                onPressed: () => setState(() => _flash = !_flash),
              ),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  decoration: BoxDecoration(
                    color: scheme.surfaceContainerLow,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: scheme.outlineVariant),
                  ),
                  child: TextField(
                    controller: _text,
                    maxLength: 120,
                    minLines: 1,
                    maxLines: 4,
                    textInputAction: TextInputAction.send,
                    onSubmitted: (_) => send(),
                    decoration: const InputDecoration(hintText: 'Message', counterText: '', border: InputBorder.none, isDense: true, contentPadding: EdgeInsets.symmetric(vertical: 10)),
                  ),
                ),
              ),
              const SizedBox(width: 6),
              IconButton.filled(
                tooltip: 'Send',
                style: IconButton.styleFrom(backgroundColor: outgoingColor),
                onPressed: m.link != LinkState.online ? null : send,
                icon: const Icon(CupertinoIcons.arrow_up, color: Colors.white),
              ),
            ]),
          ),
        ),
      ]),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon(this.status, {required this.color});
  final MsgStatus status;
  final Color color;
  @override
  Widget build(BuildContext context) => Icon(
        switch (status) {
          MsgStatus.sending => CupertinoIcons.clock,
          MsgStatus.sent || MsgStatus.networkAccepted => CupertinoIcons.checkmark_alt,
          MsgStatus.delivered => CupertinoIcons.checkmark_seal_fill,
          MsgStatus.failed => CupertinoIcons.exclamationmark_circle,
          MsgStatus.received => CupertinoIcons.checkmark_alt,
        },
        size: 13,
        color: status == MsgStatus.failed ? Tokens.emergency : color,
      );
}
