import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../keys.dart';
import '../resource_nav.dart' show showSidebarMenu;
import '../theme.dart';
import '../views/saved_views_ui.dart';
import 'settings_widgets.dart';

/// Settings ▸ Views: the saved views (reorder, rename, delete, …) and
/// importing or exporting them.
List<SettingItem> viewSettings() => [
      SettingItem.row(
        key: const ValueKey('settings-views-list'),
        label: 'Saved views',
        description: 'Drag to reorder (the sidebar follows). Right-click or use ⋯ to rename, duplicate, export or delete a view.',
        keywords: const ['reorder', 'order', 'rename', 'delete', 'duplicate', 'bookmark', 'context'],
        child: (_) => const SavedViewsEditor(),
      ),
      SettingItem.row(
        label: 'Import and export',
        description: 'Views are YAML documents: share them, or keep them with your code.',
        keywords: const ['yaml', 'file', 'copy', 'paste', 'share'],
        child: (context) {
          final any = context.select<AppState, bool>((a) => a.savedViews.isNotEmpty);
          return Wrap(spacing: 8, runSpacing: 6, children: [
            FilledButton.tonal(onPressed: () => showImportViewsDialog(context), child: const Text('Import YAML…')),
            FilledButton.tonal(onPressed: () => importViewsFromFile(context), child: const Text('Import from File…')),
            FilledButton.tonal(onPressed: any ? () => exportAllViewsToFile(context) : null, child: const Text('Export All to File…')),
            FilledButton.tonal(onPressed: any ? () => exportAllViews(context) : null, child: const Text('Copy All as YAML')),
          ]);
        },
      ),
    ];

/// The saved views in order, each with its kind and context. Drag to
/// reorder (saved at once); ⋯ or right-click for the view's menu.
class SavedViewsEditor extends StatelessWidget {
  const SavedViewsEditor({super.key});

  static const _rowHeight = 34.0;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final views = app.savedViews;
    if (views.isEmpty) return SettingsEmpty('No saved views yet. Save a table with ${shortcutLabel('S')} or :view save <name>.');
    final messenger = ScaffoldMessenger.maybeOf(context);
    void reorder(int a, int b) {
      final ids = [for (final v in views) v.id];
      ids.insert(b, ids.removeAt(a));
      app.setViewOrder(ids).catchError((Object e) {
        messenger?.showSnackBar(SnackBar(content: Text('Could not save the order of the views: $e')));
      });
    }

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
        itemCount: views.length,
        onReorderItem: reorder,
        itemBuilder: (context, i) => _ViewRow(key: ValueKey('view-${views[i].id}'), view: views[i], index: i, launch: app.launchViewId == views[i].id),
      ),
    );
  }
}

class _ViewRow extends StatelessWidget {
  final SavedView view;
  final int index;
  final bool launch;
  const _ViewRow({super.key, required this.view, required this.index, required this.launch});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final faint = theme.textTheme.bodySmall?.copyWith(color: colors.faint);
    void menu(Offset pos) => showSidebarMenu(context, pos, viewMenuItems(context, view));
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (d) => menu(d.globalPosition),
      child: SizedBox(
        height: SavedViewsEditor._rowHeight,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(children: [
            ReorderableDragStartListener(
              index: index,
              child: MouseRegion(
                cursor: SystemMouseCursors.grab,
                child: SizedBox(width: 22, height: SavedViewsEditor._rowHeight, child: Icon(Icons.drag_indicator, size: 16, color: colors.faint)),
              ),
            ),
            Icon(Icons.bookmark_outline, size: 15, color: theme.hintColor),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: view.name),
                  TextSpan(text: '   ${view.kind} · ${viewContextLabel(view)}', style: faint),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            if (launch) ...[
              const SizedBox(width: 6),
              Tooltip(message: 'Opens at launch', child: Icon(Icons.rocket_launch_outlined, size: 14, color: theme.hintColor)),
            ],
            Builder(
              builder: (anchor) => IconButton(
                tooltip: 'More',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.more_horiz),
                onPressed: () {
                  final box = anchor.findRenderObject()! as RenderBox;
                  menu(box.localToGlobal(Offset(0, box.size.height)));
                },
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
