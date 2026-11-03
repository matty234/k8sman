import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../actions/actions.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../panels/registry.dart';
import '../state/app_state.dart';
import 'detail/detail_sidebar.dart' show resourceActionsFor;

/// Right-click menu for a table row: Open, the same resource actions the
/// inspector header offers (logs, terminal, port-forward, scale, restart,
/// rollback, sync, …), copy helpers, and destructive actions last.
///
/// The live object is fetched first because several actions depend on its
/// current state (Pause vs Resume, Cordon vs Uncordon, container list…).
Future<void> showRowContextMenu(BuildContext context, Offset globalPosition, ResourceType type, TableRowData row) async {
  final api = context.read<ApiClient>();
  final app = context.read<AppState>();
  final ns = type.namespaced ? row.namespace : null;
  final target = DetailTarget(type: type, name: row.name, namespace: ns);
  // Resolve the menu position before any await (context use across gaps).
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final local = overlay.globalToLocal(globalPosition);
  final theme = Theme.of(context);
  final messenger = ScaffoldMessenger.maybeOf(context);

  Json? object;
  try {
    object = await api.object(type.ref, namespace: ns, name: row.name);
  } catch (_) {
    // Still offer Open/copy if the fetch fails (e.g. object just deleted).
  }
  if (!context.mounted) return;

  final ctx = object == null ? null : PanelContext(object: object, type: type, api: api, app: app);
  final actions = ctx == null ? const <ResourceAction>[] : resourceActionsFor(app, target, panelFor(type), ctx);
  final safe = actions.where((a) => !a.destructive).toList();
  final destructive = actions.where((a) => a.destructive).toList();
  final qualified = ns == null ? row.name : '$ns/${row.name}';

  PopupMenuItem<VoidCallback> item(IconData icon, String label, VoidCallback run, {bool danger = false, String? shortcut}) {
    final color = danger ? theme.colorScheme.error : null;
    return PopupMenuItem<VoidCallback>(
      value: run,
      height: 30,
      child: Row(children: [
        Icon(icon, size: 15, color: color ?? theme.hintColor),
        const SizedBox(width: 10),
        Expanded(child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: color))),
        if (shortcut != null) Text(shortcut, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
      ]),
    );
  }

  void copy(String text, String what) {
    Clipboard.setData(ClipboardData(text: text));
    messenger?.showSnackBar(SnackBar(content: Text('Copied $what'), duration: const Duration(seconds: 1)));
  }

  final entries = <PopupMenuEntry<VoidCallback>>[
    item(Icons.open_in_new, 'Open', () => app.openDetail(target), shortcut: '↵'),
    if (safe.isNotEmpty) const PopupMenuDivider(height: 9),
    for (final a in safe) item(a.icon, a.label, () => a.run(context)),
    const PopupMenuDivider(height: 9),
    item(Icons.content_copy, 'Copy name', () => copy(row.name, 'name')),
    if (ns != null) item(Icons.content_copy, 'Copy namespace/name', () => copy(qualified, qualified)),
    item(Icons.description_outlined, 'Copy YAML', () async {
      try {
        final yaml = await api.objectYaml(type.ref, namespace: ns, name: row.name);
        copy(yaml, 'YAML');
      } catch (e) {
        if (context.mounted) showActionError(context, '$e');
      }
    }),
    if (destructive.isNotEmpty) const PopupMenuDivider(height: 9),
    for (final a in destructive) item(a.icon, a.label, () => a.run(context), danger: true),
  ];

  final chosen = await showMenu<VoidCallback>(
    context: context,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    position: RelativeRect.fromRect(Rect.fromPoints(local, local), Offset.zero & overlay.size),
    constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
    items: entries,
  );
  if (chosen != null && context.mounted) chosen();
}
