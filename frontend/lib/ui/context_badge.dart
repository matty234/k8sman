import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/context_appearance.dart';
import 'theme.dart';
import 'widgets/common.dart' show Hoverable;

/// The curated icon set, by stable id (never by codepoint). An id this
/// version doesn't know (written by a newer one) shows the default icon.
const contextIcons = <(String, IconData, String)>[
  ('hub', Icons.hub_outlined, 'Hub'),
  ('cloud', Icons.cloud_outlined, 'Cloud'),
  ('dns', Icons.dns_outlined, 'Server'),
  ('storage', Icons.storage_outlined, 'Storage'),
  ('science', Icons.science_outlined, 'Lab'),
  ('rocket', Icons.rocket_launch_outlined, 'Production'),
  ('shield', Icons.shield_outlined, 'Shield'),
  ('bug', Icons.bug_report_outlined, 'Dev'),
  ('home', Icons.home_outlined, 'Home'),
  ('factory', Icons.factory_outlined, 'Factory'),
  ('school', Icons.school_outlined, 'School'),
  ('flask', Icons.biotech_outlined, 'Flask'),
  ('public', Icons.public, 'Public'),
  ('lan', Icons.lan_outlined, 'Network'),
  ('memory', Icons.memory, 'Chip'),
  ('bolt', Icons.bolt_outlined, 'Bolt'),
  ('star', Icons.star_outline, 'Star'),
  ('favorite', Icons.favorite_outline, 'Favourite'),
  ('eco', Icons.eco_outlined, 'Eco'),
  ('pets', Icons.pets_outlined, 'Pets'),
  ('sailing', Icons.sailing_outlined, 'Sailing'),
  ('terrain', Icons.terrain, 'Terrain'),
  ('account_balance', Icons.account_balance_outlined, 'Bank'),
  ('apartment', Icons.apartment_outlined, 'Office'),
  ('work', Icons.work_outline, 'Work'),
  ('build', Icons.build_outlined, 'Build'),
  ('fire', Icons.local_fire_department_outlined, 'Fire'),
  ('psychology', Icons.psychology_outlined, 'Brain'),
  ('games', Icons.sports_esports_outlined, 'Games'),
  ('flight', Icons.flight_outlined, 'Flight'),
  ('diamond', Icons.diamond_outlined, 'Diamond'),
  ('anchor', Icons.anchor, 'Anchor'),
];

/// Named colours that read well behind a white glyph in light and dark.
const contextColors = <(String, Color, String)>[
  ('blue', Color(0xFF3B82F6), 'Blue'),
  ('indigo', Color(0xFF6366F1), 'Indigo'),
  ('purple', Color(0xFF9B59D0), 'Purple'),
  ('pink', Color(0xFFE0488F), 'Pink'),
  ('red', Color(0xFFE5484D), 'Red'),
  ('orange', Color(0xFFF26B1D), 'Orange'),
  ('amber', Color(0xFFD48806), 'Amber'),
  ('green', Color(0xFF30A46C), 'Green'),
  ('teal', Color(0xFF14A3A3), 'Teal'),
  ('graphite', Color(0xFF6B7280), 'Graphite'),
];

IconData? contextIconData(String id) {
  for (final i in contextIcons) {
    if (i.$1 == id) return i.$2;
  }
  return null;
}

/// The colour for an id or `#rrggbb`; null for default or unknown.
Color? contextColorValue(String id) {
  for (final c in contextColors) {
    if (c.$1 == id) return c.$2;
  }
  final m = RegExp(r'^#([0-9a-fA-F]{6})$').firstMatch(id);
  return m == null ? null : Color(0xFF000000 | int.parse(m.group(1)!, radix: 16));
}

/// The badge for kube context [name], following the user's choice.
class NamedContextBadge extends StatelessWidget {
  final String name;
  final double size;
  const NamedContextBadge(this.name, {super.key, this.size = 20});

  @override
  Widget build(BuildContext context) =>
      ContextBadge(appearance: context.select<AppState, ContextAppearance>((a) => a.contextAppearance[name] ?? const ContextAppearance()), size: size);
}

/// A small rounded square: the context's glyph (or monogram) in its colour.
/// With nothing chosen it is the default hub badge in the primary colour.
class ContextBadge extends StatelessWidget {
  final ContextAppearance appearance;
  final double size;
  const ContextBadge({super.key, this.appearance = const ContextAppearance(), this.size = 20});

  @override
  Widget build(BuildContext context) {
    final bg = contextColorValue(appearance.color) ?? Theme.of(context).colorScheme.primary;
    final mono = appearance.monogram;
    final glyph = mono != null
        ? FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              mono,
              style: TextStyle(color: Colors.white, fontSize: size * 0.5, fontWeight: FontWeight.w700, height: 1, letterSpacing: -0.2),
            ),
          )
        : Icon(contextIconData(appearance.icon) ?? Icons.hub, size: size * 0.65, color: Colors.white);
    return Container(
      key: ValueKey('context-badge-${appearance.icon}-${appearance.color}'),
      width: size,
      height: size,
      alignment: Alignment.center,
      padding: EdgeInsets.all(size * 0.1),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(size * 0.25)),
      child: glyph,
    );
  }
}

/// Opens the icon and colour picker for kube context [name].
Future<void> showContextAppearanceDialog(BuildContext context, String name) {
  final app = context.read<AppState>();
  return showDialog<void>(
    context: context,
    builder: (_) => _AppearanceDialog(name: name, initial: app.contextAppearance[name] ?? const ContextAppearance(), app: app),
  );
}

class _AppearanceDialog extends StatefulWidget {
  final String name;
  final ContextAppearance initial;
  final AppState app;
  const _AppearanceDialog({required this.name, required this.initial, required this.app});

  @override
  State<_AppearanceDialog> createState() => _AppearanceDialogState();
}

class _AppearanceDialogState extends State<_AppearanceDialog> {
  late ContextAppearance draft = widget.initial;
  late final mono = TextEditingController(text: widget.initial.monogram ?? '');
  bool saving = false;

  @override
  void dispose() {
    mono.dispose();
    super.dispose();
  }

  void _icon(String id) {
    mono.clear();
    setState(() => draft = ContextAppearance(icon: draft.icon == id ? '' : id, color: draft.color));
  }

  void _color(String id) => setState(() => draft = ContextAppearance(icon: draft.icon, color: id));

  void _monogram(String v) {
    final t = v.trim();
    setState(() => draft = ContextAppearance(icon: t.isEmpty ? '' : 'text:$t', color: draft.color));
  }

  Future<void> _done() async {
    setState(() => saving = true);
    try {
      await widget.app.setContextAppearance(widget.name, draft);
      if (mounted) Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() => saving = false);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Could not save: $e')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    return AlertDialog(
      scrollable: true,
      title: Row(
        children: [
          ContextBadge(appearance: draft, size: 28),
          const SizedBox(width: 10),
          Expanded(child: Text(widget.name, overflow: TextOverflow.ellipsis)),
        ],
      ),
      content: SizedBox(
        width: 400,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Icon', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 4,
              runSpacing: 4,
              children: [
                for (final i in contextIcons)
                  Tooltip(
                    message: i.$3,
                    waitDuration: const Duration(milliseconds: 300),
                    child: Hoverable(
                      key: ValueKey('context-icon-${i.$1}'),
                      onTap: () => _icon(i.$1),
                      builder: (h) => Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: draft.icon == i.$1 ? theme.colorScheme.primary.withValues(alpha: 0.16) : (h ? colors.hover : null),
                          border: Border.all(color: draft.icon == i.$1 ? theme.colorScheme.primary : Colors.transparent),
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: Icon(i.$2, size: 18, color: draft.icon == i.$1 ? theme.colorScheme.primary : theme.colorScheme.onSurface),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Text('Or letters', style: theme.textTheme.labelLarge),
                const SizedBox(width: 10),
                SizedBox(
                  width: 64,
                  child: TextField(
                    key: const ValueKey('context-monogram'),
                    controller: mono,
                    maxLength: 2,
                    textCapitalization: TextCapitalization.characters,
                    decoration: const InputDecoration(isDense: true, counterText: '', hintText: 'PR'),
                    onChanged: _monogram,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text('Colour', style: theme.textTheme.labelLarge),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final c in [('', theme.colorScheme.primary, 'Default'), ...contextColors])
                  Tooltip(
                    message: c.$3,
                    waitDuration: const Duration(milliseconds: 300),
                    child: Hoverable(
                      key: ValueKey('context-color-${c.$1.isEmpty ? 'default' : c.$1}'),
                      onTap: () => _color(c.$1),
                      builder: (h) => Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: c.$2,
                          shape: BoxShape.circle,
                          border: Border.all(color: draft.color == c.$1 ? theme.colorScheme.onSurface : Colors.transparent, width: 2),
                        ),
                        child: draft.color == c.$1 ? const Icon(Icons.check, size: 14, color: Colors.white) : null,
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const ValueKey('context-appearance-reset'),
          onPressed: draft.isDefault
              ? null
              : () {
                  mono.clear();
                  setState(() => draft = const ContextAppearance());
                },
          child: const Text('Reset'),
        ),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(key: const ValueKey('context-appearance-done'), onPressed: saving ? null : _done, child: const Text('Done')),
      ],
    );
  }
}
