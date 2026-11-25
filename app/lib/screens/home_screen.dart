import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../model/terminal_model.dart';
import '../ui/adaptive.dart';
import '../ui/glass.dart';
import '../ui/theme.dart';
import 'calls_screen.dart';
import 'contacts_screen.dart';
import 'messages_screen.dart';
import 'settings_screen.dart';
import 'talkgroups_screen.dart';

/// App shell: five tabs. iOS uses the Cupertino tab bar (translucent, SF-style
/// glyphs), Android the Material navigation bar.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, this.initialTab = 0});
  final int initialTab;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  late int _tab = widget.initialTab;
  final _calls = GlobalKey<CallsScreenState>();

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
    final unread = m.messages.where((x) => !x.outgoing && x.status == MsgStatus.received).isNotEmpty;

    final items = [
      (pick(context, Icons.cell_tower, CupertinoIcons.antenna_radiowaves_left_right), 'Radio'),
      (pick(context, Icons.call_outlined, CupertinoIcons.phone), 'Calls'),
      (pick(context, Icons.person_outline, CupertinoIcons.person_crop_circle), 'Contacts'),
      (pick(context, Icons.chat_bubble_outline, CupertinoIcons.chat_bubble_2), 'Messages'),
      (pick(context, Icons.settings_outlined, CupertinoIcons.gear), 'Settings'),
    ];
    const filled = [CupertinoIcons.antenna_radiowaves_left_right, CupertinoIcons.phone_fill, CupertinoIcons.person_crop_circle_fill, CupertinoIcons.chat_bubble_2_fill, CupertinoIcons.gear_solid];
    void select(int i) {
      Haptics.select();
      setState(() => _tab = i);
    }

    return Scaffold(
      // iOS: content runs beneath the floating glass tab bar.
      extendBody: isApple(context),
      body: IndexedStack(index: tab, children: [
        const TalkgroupsScreen(),
        CallsScreen(key: _calls),
        ContactsScreen(onCall: (issi) {
          setState(() => _tab = 1);
          _calls.currentState?.openKeypad(issi);
        }),
        const MessagesScreen(),
        const SettingsScreen(),
      ]),
      bottomNavigationBar: isApple(context)
          ? GlassTabBar(
              index: tab,
              onTap: select,
              badges: {if (unread) 3},
              items: [for (final (i, it) in items.indexed) (it.$1, filled[i], it.$2)],
            )
          : NavigationBar(
              selectedIndex: tab,
              onDestinationSelected: select,
              destinations: [
                for (final (i, it) in items.indexed)
                  NavigationDestination(icon: Badge(isLabelVisible: i == 3 && unread, smallSize: 8, child: Icon(it.$1)), label: it.$2),
              ],
            ),
    );
  }
}

/// Connection pill: state colour + label, tap to connect / disconnect.
class LinkPill extends StatelessWidget {
  const LinkPill({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final (label, color) = switch (m.link) {
      LinkState.online => ('Online', Tokens.online),
      LinkState.connecting => ('Connecting', Tokens.connecting),
      LinkState.offline => ('Offline', Theme.of(context).colorScheme.outline),
    };
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: '$label. ${m.link == LinkState.offline ? 'Tap to connect' : 'Tap to disconnect'}',
      child: GestureDetector(
        onTap: () async {
          if (m.link != LinkState.offline) {
            final go = await showActions<bool>(context,
                title: 'Disconnect from the server?', message: 'You will not hear calls until you connect again.', actions: const [
              SheetAction('Disconnect', true, destructive: true),
            ]);
            if (go == true) await m.goOffline();
          } else if (!m.settings.isConfigured) {
            ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Fill in server, username and ISSI in Settings first')));
          } else {
            await m.connect();
          }
        },
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(999)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
            const SizedBox(width: 6),
            Text(label, style: Theme.of(context).textTheme.labelLarge),
          ]),
        ),
      ),
    );
  }
}

/// Seconds since [since] as m:ss, ticking once a second.
class Elapsed extends StatefulWidget {
  const Elapsed(this.since, {super.key, this.style});
  final DateTime since;
  final TextStyle? style;
  @override
  State<Elapsed> createState() => _ElapsedState();
}

class _ElapsedState extends State<Elapsed> {
  Timer? _t;
  @override
  void initState() {
    super.initState();
    _t = Timer.periodic(const Duration(seconds: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _t?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final d = DateTime.now().difference(widget.since);
    final s = d.inSeconds.clamp(0, 359999);
    return Text('${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}',
        style: (widget.style ?? const TextStyle()).copyWith(fontFeatures: const [FontFeature.tabularFigures()]));
  }
}

/// The selected group and who is on air: the one thing a radio user looks at.
class NowCard extends StatelessWidget {
  const NowCard({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;
    final tg = m.settings.talkgroups.where((t) => t.gssi == m.selectedGssi).firstOrNull;
    final heard = m.heard;
    final emergency = heard?.emergency == true;

    final (Color bg, Color fg, String status, DateTime? since, IconData icon) = switch (()) {
      _ when m.transmitting => (Tokens.talk, Colors.white, 'You are talking', m.myTxSince, CupertinoIcons.mic_fill),
      _ when heard != null => (
          emergency ? Tokens.emergency : scheme.primary,
          Colors.white,
          '${emergency ? 'EMERGENCY · ' : ''}${m.nameOf(heard.talker, sentName: heard.talkerName)}${m.nameOf(heard.talker, sentName: heard.talkerName) != 'ISSI ${heard.talker}' ? ' · ${heard.talker}' : ''}',
          heard.since,
          CupertinoIcons.waveform,
        ),
      _ => (scheme.surfaceContainerLow, scheme.onSurface, m.link == LinkState.online ? 'Channel free' : 'Not connected', null, CupertinoIcons.circle),
    };
    final heardOther = heard != null && heard.gssi != m.selectedGssi;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOut,
      margin: const EdgeInsets.symmetric(horizontal: Tokens.gutter),
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(Tokens.radiusLarge)),
      child: DefaultTextStyle.merge(
        style: TextStyle(color: fg),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(
                tg?.name ?? 'No talkgroup selected',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.headlineSmall?.copyWith(color: fg, fontWeight: FontWeight.w700, letterSpacing: -.3),
              ),
            ),
            if (tg != null)
              Text('TG ${tg.gssi}', style: text.labelLarge?.copyWith(color: fg.withValues(alpha: .75), fontFeatures: const [FontFeature.tabularFigures()])),
          ]),
          if (tg != null && tg.otherNetwork)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(m.networkName(tg.mcc, tg.mnc), style: text.bodySmall?.copyWith(color: fg.withValues(alpha: .75))),
            ),
          const SizedBox(height: 12),
          Row(children: [
            Icon(icon, size: 18, color: fg),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                heardOther ? '$status on TG ${heard.gssi}' : status,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: text.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w600),
              ),
            ),
            if (since != null) Elapsed(since, style: text.titleMedium?.copyWith(color: fg, fontWeight: FontWeight.w600)),
          ]),
        ]),
      ),
    );
  }
}

/// Hold to talk. Feedback on touch-down (scale + colour), haptic on grant.
/// The SOS button needs a long press so it is never sent by accident.
class PttButton extends StatefulWidget {
  const PttButton({super.key, this.compact = false});
  final bool compact;
  @override
  State<PttButton> createState() => _PttButtonState();
}

class _PttButtonState extends State<PttButton> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final online = m.link == LinkState.online;
    // Listen-only or refused group (server group access): no PTT, SOS still works.
    final listenOnly = online && m.privateCall == null && !m.mayTalkOnSelected;
    final enabled = online && !listenOnly;
    final tx = m.transmitting;
    final size = widget.compact ? 96.0 : 132.0;
    final color = !enabled ? scheme.surfaceContainerHigh : (tx ? Tokens.talk : scheme.primary);

    final toggle = m.settings.pttToggle;
    final apple = isApple(context);

    void up() {
      if (!_down) return;
      setState(() => _down = false);
      if (toggle) return;
      Haptics.release();
      m.pttUp();
    }

    return Row(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.center, children: [
      const SizedBox(width: 64, child: SpeakerButton()),
      const Spacer(),
      Semantics(
        button: true,
        label: toggle
            ? (tx || m.pttLatched ? 'Talking. Tap to stop' : 'Push to talk. Tap to start talking')
            : (tx ? 'Talking. Release to stop' : 'Push to talk. Hold to talk'),
        enabled: enabled,
        child: Listener(
          onPointerDown: enabled
              ? (_) {
                  setState(() => _down = true);
                  if (toggle) {
                    final stopping = tx || m.pttLatched;
                    stopping ? Haptics.release() : Haptics.press();
                    m.togglePtt();
                  } else {
                    Haptics.press();
                    m.pttDown();
                  }
                }
              : null,
          onPointerUp: enabled ? (_) => up() : null,
          onPointerCancel: enabled ? (_) => up() : null,
          child: AnimatedScale(
            scale: _down ? .95 : 1,
            duration: const Duration(milliseconds: 90),
            curve: Curves.easeOut,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              width: size,
              height: size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: color,
                boxShadow: [
                  BoxShadow(color: (tx ? Tokens.talk : Colors.black).withValues(alpha: tx ? .40 : (apple ? .10 : .08)), blurRadius: tx ? 28 : 16, spreadRadius: tx ? 4 : 0, offset: const Offset(0, 6)),
                ],
              ),
              alignment: Alignment.center,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Icon(tx ? CupertinoIcons.mic_fill : (listenOnly ? CupertinoIcons.speaker_2 : CupertinoIcons.mic), size: widget.compact ? 30 : 38, color: enabled ? Colors.white : scheme.outline),
                const SizedBox(height: 4),
                Text(tx ? 'TALK' : (listenOnly ? 'LISTEN' : 'PTT'),
                    style: TextStyle(fontSize: widget.compact ? 15 : 17, fontWeight: FontWeight.w700, letterSpacing: 1.2, color: enabled ? Colors.white : scheme.outline)),
              ]),
            ),
          ),
        ),
      ),
      const Spacer(),
      SizedBox(width: 64, child: _SosButton(enabled: online)),
    ]);
  }
}

/// Loudspeaker / earpiece (phone mode). A headset or Bluetooth device always
/// wins; the choice is saved.
class SpeakerButton extends StatelessWidget {
  const SpeakerButton({super.key});

  @override
  Widget build(BuildContext context) {
    final m = context.watch<TerminalModel>();
    final scheme = Theme.of(context).colorScheme;
    final on = m.settings.speakerOut;
    return Semantics(
      button: true,
      toggled: on,
      label: on ? 'Loudspeaker on. Tap for earpiece' : 'Earpiece. Tap for loudspeaker',
      child: Tooltip(
        message: on ? 'Loudspeaker' : 'Earpiece',
        child: GestureDetector(
          onTap: () {
            Haptics.select();
            m.setSpeakerOut(!on);
          },
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 56,
              height: 56,
              decoration: BoxDecoration(shape: BoxShape.circle, color: on ? scheme.primaryContainer : scheme.surfaceContainerHigh),
              alignment: Alignment.center,
              child: Icon(on ? CupertinoIcons.speaker_3_fill : CupertinoIcons.phone_fill, size: 24, color: on ? scheme.onPrimaryContainer : scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 4),
            Text(on ? 'Speaker' : 'Earpiece', style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
          ]),
        ),
      ),
    );
  }
}

class _SosButton extends StatelessWidget {
  const _SosButton({required this.enabled});
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final m = context.read<TerminalModel>();
    return Semantics(
      button: true,
      label: 'Emergency. Long press to talk with emergency priority',
      child: GestureDetector(
        onLongPressStart: enabled
            ? (_) {
                Haptics.warn();
                m.pttDown(emergency: true);
              }
            : null,
        onLongPressEnd: enabled ? (_) => m.pttUp() : null,
        onTap: enabled
            ? () => ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Hold the SOS button to talk with emergency priority')))
            : null,
        child: Container(
          width: 56,
          height: 56,
          decoration: BoxDecoration(shape: BoxShape.circle, color: enabled ? Tokens.emergency : Theme.of(context).colorScheme.surfaceContainerHigh),
          alignment: Alignment.center,
          child: const Text('SOS', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 15, letterSpacing: .5)),
        ),
      ),
    );
  }
}

/// Large-title page scaffold used by every tab: title, optional trailing
/// actions, then content.
class TabPage extends StatelessWidget {
  const TabPage({super.key, required this.title, this.actions = const [], required this.slivers, this.bottom});
  final String title;
  final List<Widget> actions;
  final List<Widget> slivers;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final apple = isApple(context);
    // Bottom inset: the floating tab bar (Scaffold.extendBody puts it in the padding).
    final barInset = MediaQuery.of(context).padding.bottom;
    const dockHeight = 150.0;
    final scroll = CustomScrollView(slivers: [
      if (isApple(context))
        CupertinoSliverNavigationBar(
          largeTitle: Text(title),
          backgroundColor: scheme.surface.withValues(alpha: .9),
          border: null,
          trailing: actions.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, children: actions),
        )
      else
        SliverAppBar.large(title: Text(title), actions: [...actions, const SizedBox(width: 8)]),
      ...slivers,
      SliverToBoxAdapter(child: SizedBox(height: 16 + barInset + (apple && bottom != null ? dockHeight : 0))),
    ]);
    if (bottom == null) return scroll;
    if (!apple) return Column(children: [Expanded(child: scroll), bottom!]);
    // iOS: the PTT dock floats on glass above the tab bar, content scrolls beneath.
    return Stack(children: [
      Positioned.fill(child: scroll),
      Positioned(left: 20, right: 20, bottom: barInset + 14, child: bottom!),
    ]);
  }
}
