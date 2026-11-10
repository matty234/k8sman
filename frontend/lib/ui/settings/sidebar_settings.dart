import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../modules/modules.dart' show kindHomes, pageEnabled, pageFor;
import '../../state/app_state.dart';
import '../resource_nav.dart' show kindIconWidget, sectionTitles;
import '../theme.dart';
import '../widgets/searchable_picker.dart';
import 'settings_widgets.dart';

/// Settings ▸ Sidebar.
List<SettingItem> sidebarSettings() => [
      SettingItem.row(
        key: const ValueKey('settings-sidebar-layout'),
        label: 'Pages and pinned kinds',
        description: 'Ticked pages show at the top of the sidebar; unticked ones fold under More. Drag to reorder.',
        keywords: const ['pin', 'pinned', 'unpin', 'hide', 'hidden', 'show', 'more', 'reorder', 'order', 'customise', 'customize', 'layout'],
        trailing: (context) => TextButton(
          onPressed: context.select<AppState, bool>((a) => a.sidebar.isDefault) ? null : () => context.read<AppState>().setSidebar(SidebarConfig.defaults),
          child: const Text('Restore Defaults'),
        ),
        child: (_) => const SidebarLayoutEditor(),
      ),
      SettingItem.row(
        key: const ValueKey('settings-sidebar-sections'),
        label: 'Kinds list order',
        description: 'Drag the sections of the kinds list into any order. Custom Resources and Other always come last.',
        keywords: const ['sections', 'order', 'reorder', 'integrations', 'kinds', 'groups', 'sort'],
        trailing: (context) => TextButton(
          onPressed: context.select<AppState, bool>((a) => a.sidebar.sectionOrder.isEmpty) ? null : () => context.read<AppState>().setSidebar(context.read<AppState>().sidebar.withSectionOrder(const [])),
          child: const Text('Reset order'),
        ),
        child: (_) => const SectionOrderEditor(),
      ),
    ];

/// The kinds list's sections as a draggable list (same look as the pages).
class SectionOrderEditor extends StatelessWidget {
  const SectionOrderEditor({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final titles = sectionTitles(app);
    return Container(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        border: Border.all(color: colors.separator),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ReorderableListView.builder(
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(vertical: 4),
        buildDefaultDragHandles: false,
        itemCount: titles.length,
        onReorderItem: (a, b) => app.setSidebar(app.sidebar.withSectionOrder(titles..insert(b, titles.removeAt(a)))),
        itemBuilder: (context, i) => SizedBox(
          key: ValueKey('section-${titles[i]}'),
          height: SidebarLayoutEditor._rowHeight,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Row(children: [
              ReorderableDragStartListener(
                index: i,
                child: MouseRegion(
                  cursor: SystemMouseCursors.grab,
                  child: SizedBox(width: 22, height: SidebarLayoutEditor._rowHeight, child: Icon(Icons.drag_indicator, size: 16, color: colors.faint)),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(titles[i], maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium)),
            ]),
          ),
        ),
      ),
    );
  }
}

/// The sidebar's top section as an editable list: tick pages to show them,
/// drag to reorder, unpin kinds or pin new ones. Every change saves at once.
class SidebarLayoutEditor extends StatelessWidget {
  const SidebarLayoutEditor({super.key});

  static const _rowHeight = 32.0;

  static String _keyOf(SidebarEntry e) => e.view != null ? 'view-${e.view!.name}' : 'pin-${e.pin!.gk}@${e.pin!.namespace ?? ''}';

  Future<void> _pickKind(BuildContext anchor) async {
    final app = anchor.read<AppState>();
    final pinned = {for (final e in app.sidebar.entries) if (e.pin != null && e.pin!.namespace == null) e.pin!.gk};
    // Kinds with a page of their own (Node) are pinned as that page.
    final homes = kindHomes(app);
    final types = [for (final t in app.types) if (!pinned.contains(t.gk) && !homes.containsKey(t.gk)) t]..sort((a, b) => a.kind.compareTo(b.kind));
    final picked = await showSearchablePicker<ResourceType>(
      anchor,
      hint: 'Find kind',
      width: 300,
      items: [for (final t in types) PickerOption(t, t.kind, detail: t.group.isEmpty ? 'core' : t.group)],
    );
    if (picked == null) return;
    app.setSidebar(app.sidebar.pin(SidebarPin(group: picked.value.group, kind: picked.value.kind)));
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final entries = [...app.sidebar.entries];
    void save(List<SidebarEntry> next) => app.setSidebar(SidebarConfig(next));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Container(
        decoration: BoxDecoration(
          color: theme.colorScheme.surface,
          border: Border.all(color: colors.separator),
          borderRadius: BorderRadius.circular(6),
        ),
        child: ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: 4),
          buildDefaultDragHandles: false,
          itemCount: entries.length,
          onReorderItem: (a, b) => save(entries..insert(b, entries.removeAt(a))),
          itemBuilder: (context, i) => _row(context, app, entries, i, save),
        ),
      ),
      const SizedBox(height: 6),
      Row(children: [
        Builder(
          builder: (anchor) => TextButton.icon(
            key: const ValueKey('sidebar-pin-kind'),
            onPressed: () => _pickKind(anchor),
            icon: const Icon(Icons.push_pin_outlined, size: 15),
            label: const Text('Pin a Kind…'),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text('or right-click a kind in the sidebar',
              maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: colors.faint)),
        ),
      ]),
    ]);
  }

  Widget _row(BuildContext context, AppState app, List<SidebarEntry> entries, int i, void Function(List<SidebarEntry>) save) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final e = entries[i];
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
        onChanged: (v) => save([...entries]..[i] = e.withHidden(v != true)),
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
        onPressed: () => save([...entries]..removeAt(i)),
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
