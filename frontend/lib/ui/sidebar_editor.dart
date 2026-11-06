import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../modules/modules.dart' show pageEnabled, pageFor;
import 'integrations_dialog.dart';
import '../state/app_state.dart';
import 'resource_nav.dart' show kindIconWidget;
import 'theme.dart';
import 'widgets/searchable_picker.dart';

/// Opens the "Customise Sidebar" sheet: tick the pages to show (unticked
/// ones stay under More), drag to reorder, unpin kinds or pin new ones.
/// Changes apply on Done.
Future<void> showSidebarEditor(BuildContext context) {
  final app = context.read<AppState>();
  return showDialog<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider<AppState>.value(value: app, child: const SidebarEditorDialog()),
  );
}

class SidebarEditorDialog extends StatefulWidget {
  const SidebarEditorDialog({super.key});

  @override
  State<SidebarEditorDialog> createState() => _SidebarEditorDialogState();
}

class _SidebarEditorDialogState extends State<SidebarEditorDialog> {
  late List<SidebarEntry> _entries = [...context.read<AppState>().sidebar.entries];

  static const _rowHeight = 32.0;

  String _keyOf(SidebarEntry e) => e.view != null ? 'view-${e.view!.name}' : 'pin-${e.pin!.gk}@${e.pin!.namespace ?? ''}';

  void _done() {
    final app = context.read<AppState>();
    final next = SidebarConfig(_entries);
    if (!listEquals(next.entries, app.sidebar.entries)) app.setSidebar(next);
    Navigator.of(context).pop();
  }

  Future<void> _pickKind(BuildContext anchor) async {
    final app = context.read<AppState>();
    final pinned = {for (final e in _entries) if (e.pin != null && e.pin!.namespace == null) e.pin!.gk};
    final types = [for (final t in app.types) if (!pinned.contains(t.gk)) t]..sort((a, b) => a.kind.compareTo(b.kind));
    final picked = await showSearchablePicker<ResourceType>(
      anchor,
      hint: 'Find kind',
      width: 300,
      items: [for (final t in types) PickerOption(t, t.kind, detail: t.group.isEmpty ? 'core' : t.group)],
    );
    if (picked == null || !mounted) return;
    setState(() => _entries = SidebarConfig(_entries).pin(SidebarPin(group: picked.value.group, kind: picked.value.kind)).entries.toList());
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final listHeight = math.min(_entries.length * _rowHeight + 8, 420.0);
    return Dialog(
      key: const ValueKey('sidebar-editor'),
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: 380,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
            child: Text('Customise Sidebar', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 10),
            child: Text('Choose what appears at the top of the sidebar and drag to reorder. Unticked pages stay under More.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ),
          Container(
            height: listHeight,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(border: Border.all(color: colors.separator), borderRadius: BorderRadius.circular(6)),
            child: ReorderableListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 4),
              buildDefaultDragHandles: false,
              itemCount: _entries.length,
              onReorderItem: (a, b) => setState(() => _entries.insert(b, _entries.removeAt(a))),
              itemBuilder: (context, i) => _row(context, i),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 16, 0),
            child: Row(children: [
              Builder(
                builder: (anchor) => TextButton.icon(
                  key: const ValueKey('sidebar-pin-kind'),
                  onPressed: () => _pickKind(anchor),
                  icon: const Icon(Icons.push_pin_outlined, size: 15),
                  label: const Text('Pin a Kind…'),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('sidebar-integrations'),
                onPressed: () async {
                  await showIntegrationsDialog(context);
                  if (mounted) setState(() {});
                },
                icon: const Icon(Icons.extension_outlined, size: 15),
                label: const Text('Integrations…'),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text('or right-click a kind',
                    textAlign: TextAlign.end,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: colors.faint)),
              ),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 16, 14),
            child: Row(children: [
              TextButton(
                onPressed: () => setState(() => _entries = [...SidebarConfig.defaults.entries]),
                child: const Text('Restore Defaults'),
              ),
              const Spacer(),
              OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _done, child: const Text('Done')),
            ]),
          ),
        ]),
      ),
    );
  }

  Widget _row(BuildContext context, int i) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final app = context.read<AppState>();
    final e = _entries[i];
    final muted = theme.textTheme.bodySmall?.copyWith(color: colors.faint);

    Widget glyph;
    String label;
    String? note;
    Widget lead;
    Widget? end;
    if (e.view != null) {
      final page = pageFor(e.view!)!;
      label = page.label;
      glyph = Icon(page.icon, size: 15, color: theme.hintColor);
      note = pageEnabled(app, e.view!) ? page.navNote : 'Integration turned off';
      lead = Checkbox(
        key: ValueKey('sidebar-show-${e.view!.name}'),
        value: !e.hidden,
        visualDensity: VisualDensity.compact,
        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        onChanged: (v) => setState(() => _entries[i] = e.withHidden(v != true)),
      );
    } else {
      final pin = e.pin!;
      final type = app.typeForPin(pin);
      label = pin.kind;
      glyph = type != null ? kindIconWidget(type, color: theme.hintColor) : Icon(Icons.article_outlined, size: 15, color: colors.faint);
      note = [if (pin.namespace != null) 'in ${pin.namespace}', if (type == null) 'not on this cluster'].join(' · ');
      lead = Tooltip(message: 'Pinned', child: Icon(Icons.push_pin_outlined, size: 14, color: theme.hintColor));
      end = IconButton(
        key: ValueKey('sidebar-unpin-${pin.gk}@${pin.namespace ?? ''}'),
        tooltip: 'Unpin',
        visualDensity: VisualDensity.compact,
        iconSize: 15,
        icon: const Icon(Icons.remove_circle_outline),
        onPressed: () => setState(() => _entries.removeAt(i)),
      );
    }
    return SizedBox(
      key: ValueKey(_keyOf(e)),
      height: _rowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: Row(children: [
          ReorderableDragStartListener(
            index: i,
            child: MouseRegion(
              cursor: SystemMouseCursors.grab,
              child: SizedBox(width: 22, height: _rowHeight, child: Icon(Icons.drag_indicator, size: 16, color: colors.faint)),
            ),
          ),
          SizedBox(width: 30, child: Center(child: lead)),
          const SizedBox(width: 4),
          SizedBox(width: 15, child: Center(child: glyph)),
          const SizedBox(width: 8),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: label),
                if (note != null && note.isNotEmpty) TextSpan(text: '   $note', style: muted),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          ?end,
        ]),
      ),
    );
  }
}
