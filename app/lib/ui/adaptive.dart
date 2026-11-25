import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'theme.dart';

/// True on iPhone/iPad (and macOS): use Apple controls and conventions there.
bool isApple(BuildContext context) {
  final p = Theme.of(context).platform;
  return p == TargetPlatform.iOS || p == TargetPlatform.macOS;
}

/// One icon name, the platform's glyph.
IconData pick(BuildContext context, IconData material, IconData cupertino) => isApple(context) ? cupertino : material;

/// Haptics, used sparingly: PTT press/release, call answer, errors.
class Haptics {
  static void press() => HapticFeedback.heavyImpact();
  static void release() => HapticFeedback.lightImpact();
  static void select() => HapticFeedback.selectionClick();
  static void warn() => HapticFeedback.vibrate();
}

/// Grouped list section: iOS inset-grouped list, Android a rounded card with a
/// caption, so both read as "settings-like" groups.
class Section extends StatelessWidget {
  const Section({super.key, this.header, this.footer, required this.children});
  final String? header;
  final String? footer;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    if (isApple(context)) {
      return CupertinoListSection.insetGrouped(
        backgroundColor: scheme.surface,
        decoration: BoxDecoration(color: scheme.surfaceContainerLow, borderRadius: BorderRadius.circular(10)),
        header: header == null ? null : Text(header!.toUpperCase(), style: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, letterSpacing: .2, color: scheme.onSurfaceVariant)),
        footer: footer == null ? null : Text(footer!, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w400, color: scheme.onSurfaceVariant)),
        children: children,
      );
    }
    final text = Theme.of(context).textTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(Tokens.gutter, 8, Tokens.gutter, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (header != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
            child: Text(header!, style: text.labelLarge?.copyWith(color: scheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
          ),
        // One calm card per section with hairline dividers, as on iOS.
        Material(
          color: scheme.surfaceContainerLow,
          clipBehavior: Clip.antiAlias,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
          child: Column(children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 1, thickness: 1, indent: Tokens.gutter + 4, color: scheme.outlineVariant),
              children[i],
            ],
          ]),
        ),
        if (footer != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
            child: Text(footer!, style: text.bodySmall?.copyWith(color: scheme.onSurfaceVariant)),
          ),
      ]),
    );
  }
}

/// A row in a [Section].
class Tile extends StatelessWidget {
  const Tile({super.key, required this.title, this.subtitle, this.leading, this.trailing, this.onTap, this.destructive = false});
  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = destructive ? Tokens.emergency : null;
    if (isApple(context)) {
      return CupertinoListTile(
        title: Text(title, style: TextStyle(color: color ?? scheme.onSurface)),
        subtitle: subtitle == null ? null : Text(subtitle!, maxLines: 2),
        leading: leading,
        trailing: trailing ?? (onTap != null && !destructive ? const CupertinoListTileChevron() : null),
        onTap: onTap,
      );
    }
    return ListTile(
      title: Text(title, style: TextStyle(color: color)),
      subtitle: subtitle == null ? null : Text(subtitle!),
      leading: leading,
      trailing: trailing,
      onTap: onTap,
    );
  }
}

/// Label, current value and a slider, in one row.
class SliderRow extends StatelessWidget {
  const SliderRow({super.key, required this.title, required this.valueLabel, required this.value, required this.min, required this.max, required this.divisions, required this.onChanged});
  final String title;
  final String valueLabel;
  final double value;
  final double min;
  final double max;
  final int divisions;
  final ValueChanged<double> onChanged;

  @override
  Widget build(BuildContext context) => Tile(
        title: title,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          Text(valueLabel, style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontFeatures: const [FontFeature.tabularFigures()])),
          SizedBox(width: 150, child: Slider.adaptive(value: value, min: min, max: max, divisions: divisions, onChanged: onChanged)),
        ]),
      );
}

/// On/off row with the platform switch.
class SwitchRow extends StatelessWidget {
  const SwitchRow({super.key, required this.title, this.subtitle, required this.value, required this.onChanged});
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) => Tile(
        title: title,
        subtitle: subtitle,
        trailing: Switch.adaptive(value: value, onChanged: onChanged),
        onTap: onChanged == null ? null : () => onChanged!(!value),
      );
}

/// Text entry row: iOS label left / field right; Android a filled field.
class FieldRow extends StatelessWidget {
  const FieldRow({
    super.key,
    required this.label,
    required this.initial,
    required this.onChanged,
    this.hint,
    this.number = false,
    this.obscure = false,
    this.keyboard,
    this.validator,
  });
  final String label;
  final String initial;
  final ValueChanged<String> onChanged;
  final String? hint;
  final bool number;
  final bool obscure;
  final TextInputType? keyboard;
  final String? Function(String?)? validator;

  @override
  Widget build(BuildContext context) {
    final type = keyboard ?? (number ? TextInputType.number : TextInputType.text);
    final formatters = number ? [FilteringTextInputFormatter.digitsOnly] : null;
    if (isApple(context)) {
      return CupertinoTextFormFieldRow(
        prefix: SizedBox(width: 112, child: Text(label)),
        initialValue: initial,
        placeholder: hint,
        obscureText: obscure,
        keyboardType: type,
        inputFormatters: formatters,
        autocorrect: false,
        textAlign: TextAlign.end,
        validator: validator,
        onChanged: onChanged,
        style: TextStyle(color: Theme.of(context).colorScheme.onSurface),
      );
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(Tokens.gutter, 10, Tokens.gutter, 10),
      child: TextFormField(
        initialValue: initial,
        obscureText: obscure,
        keyboardType: type,
        inputFormatters: formatters,
        autocorrect: false,
        validator: validator,
        onChanged: onChanged,
        decoration: InputDecoration(labelText: label, hintText: hint, border: InputBorder.none, isDense: true),
      ),
    );
  }
}

/// Small segmented control: iOS sliding segments, Android SegmentedButton.
class Segments<T extends Object> extends StatelessWidget {
  const Segments({super.key, required this.items, required this.value, required this.onChanged});
  final Map<T, String> items;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    if (isApple(context)) {
      return CupertinoSlidingSegmentedControl<T>(
        groupValue: value,
        children: {for (final e in items.entries) e.key: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Text(e.value))},
        onValueChanged: (v) {
          if (v != null) {
            Haptics.select();
            onChanged(v);
          }
        },
      );
    }
    return SegmentedButton<T>(
      showSelectedIcon: false,
      segments: [for (final e in items.entries) ButtonSegment(value: e.key, label: Text(e.value))],
      selected: {value},
      onSelectionChanged: (s) => onChanged(s.first),
    );
  }
}

/// A label above full-width segments, as a settings row.
class LabeledSegments<T extends Object> extends StatelessWidget {
  const LabeledSegments({super.key, required this.label, required this.items, required this.value, required this.onChanged});
  final String label;
  final Map<T, String> items;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(Tokens.gutter, 10, Tokens.gutter, 10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(label, style: const TextStyle(fontSize: 16)),
          const SizedBox(height: 8),
          Segments<T>(items: items, value: value, onChanged: onChanged),
        ]),
      );
}

/// Bottom sheet with a list of actions (iOS action sheet / Material sheet).
class SheetAction<T> {
  const SheetAction(this.label, this.value, {this.destructive = false, this.icon});
  final String label;
  final T value;
  final bool destructive;
  final IconData? icon;
}

Future<T?> showActions<T>(BuildContext context, {String? title, String? message, required List<SheetAction<T>> actions}) {
  if (isApple(context)) {
    return showCupertinoModalPopup<T>(
      context: context,
      builder: (ctx) => CupertinoActionSheet(
        title: title == null ? null : Text(title),
        message: message == null ? null : Text(message),
        actions: [
          for (final a in actions)
            CupertinoActionSheetAction(isDestructiveAction: a.destructive, onPressed: () => Navigator.pop(ctx, a.value), child: Text(a.label)),
        ],
        cancelButton: CupertinoActionSheetAction(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      ),
    );
  }
  return showModalBottomSheet<T>(
    context: context,
    showDragHandle: true,
    builder: (ctx) => SafeArea(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (title != null) ListTile(title: Text(title, style: Theme.of(ctx).textTheme.titleMedium), subtitle: message == null ? null : Text(message)),
        for (final a in actions)
          ListTile(
            leading: a.icon == null ? null : Icon(a.icon, color: a.destructive ? Tokens.emergency : null),
            title: Text(a.label, style: TextStyle(color: a.destructive ? Tokens.emergency : null)),
            onTap: () => Navigator.pop(ctx, a.value),
          ),
      ]),
    ),
  );
}

/// A form in a sheet (add talkgroup, new message): returns true on Save.
Future<bool> showFormSheet(BuildContext context, {required String title, required String action, required List<Widget> fields}) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: !isApple(context),
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(Tokens.radiusLarge))),
    builder: (ctx) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(ctx).viewInsets.bottom),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        // iOS sheet header: Cancel · Title · Action.
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
          child: Row(children: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            Expanded(child: Text(title, textAlign: TextAlign.center, style: Theme.of(ctx).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600))),
            TextButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action, style: const TextStyle(fontWeight: FontWeight.w600))),
          ]),
        ),
        Section(children: fields),
        const SizedBox(height: 12),
      ]),
    ),
  );
  return r ?? false;
}
