import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../actions/actions.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../panels/registry.dart';
import '../state/app_state.dart';
import 'detail/detail_sidebar.dart' show resourceActionsFor;
import 'kubectl_menu.dart';
import 'logs/open_logs.dart' show hasWorkloadLogs, openWorkloadLogs;
import 'links_ui.dart';
import 'widgets/common.dart' show copyToClipboard;
import 'widgets/context_menu.dart';

/// Right-click menu for a table row: Open, the same resource actions the
/// inspector header offers (logs, terminal, port-forward, scale, restart,
/// rollback, sync, …), copy helpers, and destructive actions last.
///
/// The live object is fetched first because several actions depend on its
/// current state (Pause vs Resume, Cordon vs Uncordon, container list…).
/// A right-clicked table cell's value, and adding it to the filter.
class CellFilter {
  final String column;
  final String value;
  final VoidCallback include;
  final VoidCallback exclude;
  const CellFilter({required this.column, required this.value, required this.include, required this.exclude});
}

Future<void> showRowContextMenu(BuildContext context, Offset globalPosition, ResourceType type, TableRowData row, {CellFilter? cellFilter}) async {
  final api = context.read<ApiClient>();
  final app = context.read<AppState>();
  final ns = type.namespaced ? row.namespace : null;
  final target = DetailTarget(type: type, name: row.name, namespace: ns);

  Json? object;
  try {
    object = await api.object(type.ref, namespace: ns, name: row.name);
  } catch (_) {
    // Still offer Open/copy if the fetch fails (e.g. object just deleted).
  }
  if (!context.mounted) return;

  final ctx = object == null ? null : PanelContext(object: object, type: type, api: api, app: app);
  final actions = ctx == null ? const <ResourceAction>[] : resourceActionsFor(app, target, panelFor(type, app), ctx);
  final safe = actions.where((a) => !a.destructive).toList();
  final destructive = actions.where((a) => a.destructive).toList();
  final qualified = ns == null ? row.name : '$ns/${row.name}';

  PopupMenuItem<VoidCallback> item(IconData icon, String label, VoidCallback run, {bool danger = false, String? shortcut}) =>
      menuItem(run, icon, label, danger: danger, shortcut: shortcut);

  void copy(String text, String what) => copyToClipboard(context, text, label: what);

  final entries = <PopupMenuEntry<VoidCallback>>[
    item(Icons.open_in_new, 'Open', () => app.openDetail(target), shortcut: '↩'),
    if (cellFilter != null) ...[
      const PopupMenuDivider(height: 9),
      item(Icons.filter_alt_outlined, 'Filter by ${cellFilter.column} = ${_short(cellFilter.value)}', cellFilter.include),
      item(Icons.filter_alt_off_outlined, 'Exclude ${cellFilter.column} = ${_short(cellFilter.value)}', cellFilter.exclude),
    ],
    if (safe.isNotEmpty) const PopupMenuDivider(height: 9),
    for (final a in safe) item(a.icon, a.label, () => a.run(context)),
    if (ctx != null && hasWorkloadLogs(type.kind) && ctx.spec['selector'] != null)
      item(Icons.stream, 'Stream all logs', () => openWorkloadLogs(context, ctx, allContainers: true)),
    const PopupMenuDivider(height: 9),
    item(Icons.content_copy, 'Copy name', () => copy(row.name, 'name')),
    if (ns != null) item(Icons.content_copy, 'Copy namespace/name', () => copy(qualified, qualified)),
    // ⌥ while choosing: the k8sman:// form.
    item(Icons.link, 'Copy link', () => copyLink(context, app, objectLink(app, target))),
    item(Icons.description_outlined, 'Copy YAML', () async {
      try {
        final yaml = await api.objectYaml(type.ref, namespace: ns, name: row.name);
        copy(yaml, 'YAML');
      } catch (e) {
        if (context.mounted) showActionError(context, '$e');
      }
    }),
    item(Icons.terminal, 'Copy kubectl command…', () {
      showKubectlMenu(context, globalPosition, app: app, type: type, refs: [(namespace: ns, name: row.name)], pod: object);
    }),
    if (destructive.isNotEmpty) const PopupMenuDivider(height: 9),
    for (final a in destructive) item(a.icon, a.label, () => a.run(context), danger: true),
  ];

  final chosen = await showContextMenuAt<VoidCallback>(context, globalPosition, entries, constraints: const BoxConstraints(minWidth: 220, maxWidth: 320));
  if (chosen != null && context.mounted) chosen();
}

/// Long values keep both ends (a pod's hash suffix is what tells it apart).
String _short(String v) => v.length > 24 ? '${v.substring(0, 12)}…${v.substring(v.length - 10)}' : v;
