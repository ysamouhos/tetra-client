import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/terminal_model.dart';
import 'calls_screen.dart';
import 'messages_screen.dart';
import 'settings_screen.dart';
import 'talkgroups_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final toast = m.toast;
    if (toast != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(toast)));
        m.clearToast();
      });
    }
    // An incoming private call always surfaces the Calls tab.
    final ringing = m.privateCall?.incoming == true && m.privateCall?.state == 'ringing';
    final tab = ringing ? 1 : _tab;

    return Scaffold(
      appBar: AppBar(
        title: Text(m.settings.name.isNotEmpty ? m.settings.name : 'ISSI ${m.settings.issi}'),
        actions: [_LinkChip(m.link, m.lastError)],
      ),
      body: Column(children: [
        const StatusBanner(),
        Expanded(
          child: IndexedStack(index: tab, children: const [
            TalkgroupsScreen(),
            CallsScreen(),
            MessagesScreen(),
            SettingsScreen(),
          ]),
        ),
      ]),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.groups_outlined), selectedIcon: Icon(Icons.groups), label: 'Talkgroups'),
          NavigationDestination(icon: Icon(Icons.call_outlined), selectedIcon: Icon(Icons.call), label: 'Calls'),
          NavigationDestination(icon: Icon(Icons.message_outlined), selectedIcon: Icon(Icons.message), label: 'Messages'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

class _LinkChip extends StatelessWidget {
  const _LinkChip(this.link, this.error);
  final LinkState link;
  final String? error;

  @override
  Widget build(BuildContext context) {
    final (label, color) = switch (link) {
      LinkState.online => ('Online', Colors.green),
      LinkState.connecting => ('Connecting', Colors.orange),
      LinkState.offline => ('Offline', Colors.grey),
    };
    return Tooltip(
      message: error ?? label,
      child: Padding(
        padding: const EdgeInsets.only(right: 12),
        child: Row(children: [Icon(Icons.circle, size: 10, color: color), const SizedBox(width: 6), Text(label)]),
      ),
    );
  }
}

/// Who is talking right now; red for emergency (priority 15).
class StatusBanner extends StatelessWidget {
  const StatusBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    String? text;
    Color? bg;
    if (m.transmitting) {
      text = m.privateCall != null ? 'Transmitting to ${m.privateCall!.peer}' : 'Transmitting on TG ${m.selectedGssi}';
      bg = scheme.primary;
    } else if (m.heard case final g?) {
      final who = g.talkerName != null ? '${g.talkerName} (${g.talker})' : '${g.talker}';
      text = '${g.emergency ? 'EMERGENCY  ' : ''}$who on TG ${g.gssi}${g.priority > 0 && !g.emergency ? '  · P${g.priority}' : ''}';
      bg = g.emergency ? Colors.red.shade700 : scheme.tertiary;
    }
    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      height: text == null ? 0 : 44,
      width: double.infinity,
      color: bg,
      alignment: Alignment.center,
      child: text == null ? null : Text(text, style: TextStyle(color: scheme.onPrimary, fontWeight: FontWeight.w600)),
    );
  }
}

/// Press-and-hold PTT. Long press on the emergency button sends an
/// emergency (priority 15) transmission.
class PttButton extends StatelessWidget {
  const PttButton({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final enabled = m.link == LinkState.online;
    return Row(mainAxisAlignment: MainAxisAlignment.center, children: [
      Listener(
        onPointerDown: enabled ? (_) => m.pttDown() : null,
        onPointerUp: enabled ? (_) => m.pttUp() : null,
        onPointerCancel: enabled ? (_) => m.pttUp() : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 100),
          width: 140,
          height: 140,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: !enabled ? scheme.surfaceContainerHighest : (m.transmitting ? scheme.error : scheme.primary),
            boxShadow: [if (m.transmitting) BoxShadow(color: scheme.error.withValues(alpha: .5), blurRadius: 24, spreadRadius: 4)],
          ),
          alignment: Alignment.center,
          child: Text(m.transmitting ? 'TALK' : 'PTT', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: scheme.onPrimary)),
        ),
      ),
      const SizedBox(width: 24),
      Tooltip(
        message: 'Hold for emergency call',
        child: GestureDetector(
          onLongPressStart: enabled ? (_) => m.pttDown(emergency: true) : null,
          onLongPressEnd: enabled ? (_) => m.pttUp() : null,
          child: CircleAvatar(radius: 32, backgroundColor: Colors.red.shade700, child: const Icon(Icons.sos, color: Colors.white, size: 32)),
        ),
      ),
    ]);
  }
}
