import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../app/updates/update_controller.dart';
import '../../app/updates/update_ui.dart';
import '../../modules/modules.dart';
import '../../state/app_state.dart';
import '../../state/log_dock.dart';
import '../../state/table_controller.dart';
import '../integrations_dialog.dart';
import '../keys.dart';
import '../editor/resource_editor_screen.dart';
import '../resource_nav.dart';
import '../resource_table.dart';
import '../sidebar_editor.dart';
import '../terminal/open_terminal.dart';
import 'palette_items.dart';
import '../views/saved_views_ui.dart';

Widget Function(Color) _icon(IconData i) => (c) => Icon(i, size: 15, color: c);

/// Pages, kinds, namespaces, contexts and actions, built from [context]
/// (the shell's, so actions like Customise Sidebar can use it).
List<PaletteItem> paletteItems(BuildContext context) {
  final app = context.read<AppState>();
  final dock = context.read<LogDock?>();
  final updates = context.read<UpdateController?>();
  return [
    // Every saved view; one bound to another context names it (⇄: opening
    // it switches cluster).
    for (final v in app.savedViews) viewPaletteItem(context, app, v),
    for (final p in enabledPages(app))
      PaletteItem(
        group: PaletteGroup.pages,
        title: p.label,
        typeLabel: 'Page',
        icon: _icon(p.icon),
        current: app.view == p.view,
        run: () => app.showView(p.view),
      ),
    for (final t in app.types)
      // events.k8s.io/Event duplicates core Event (the sidebar hides it too).
      if (t.gk != 'events.k8s.io/Event')
        PaletteItem(
          group: PaletteGroup.kinds,
          title: t.kind,
          detail: t.group.isEmpty ? t.version : t.group,
          typeLabel: t.custom ? 'Custom Kind' : 'Kind',
          icon: (c) => kindIconWidget(t, size: 15, color: c),
          aliases: [t.resource],
          exactAliases: t.shortNames,
          current: app.view == MainView.resources && app.selectedType == t,
          run: () => app.selectType(t),
        ),
    PaletteItem(
      group: PaletteGroup.namespaces,
      title: 'All namespaces',
      typeLabel: 'Namespace',
      icon: _icon(Icons.folder_copy_outlined),
      current: app.namespaceScope.isAll,
      run: () => app.setNamespace(null),
    ),
    // Recently used sets of several namespaces, then namespaces (recent
    // ones first: they lead the list before you type).
    for (final s in app.recentNamespaces.where((s) => s.isMulti))
      PaletteItem(
        group: PaletteGroup.namespaces,
        title: s.namespaces.join(', '),
        typeLabel: 'Namespaces',
        icon: _icon(Icons.folder_copy_outlined),
        current: app.namespaceScope == s,
        run: () => app.setNamespaceScope(s),
      ),
    for (final ns in [
      ...app.recentNamespaces.map((s) => s.single).whereType<String>().where(app.namespaces.contains),
      ...app.namespaces.where((n) => !app.recentNamespaces.contains(NamespaceScope.single(n))),
    ])
      PaletteItem(
        group: PaletteGroup.namespaces,
        title: ns,
        typeLabel: 'Namespace',
        icon: _icon(Icons.folder_outlined),
        current: app.namespace == ns,
        run: () => app.setNamespace(ns),
      ),
    for (final c in app.contexts)
      PaletteItem(
        group: PaletteGroup.contexts,
        title: c.name,
        detail: c.cluster != c.name ? c.cluster : null,
        typeLabel: 'Context',
        icon: _icon(Icons.cloud_outlined),
        current: c.name == app.currentContext,
        run: () => c.name == app.currentContext ? null : app.switchContext(c.name),
      ),
    if (dock != null)
      PaletteItem(
        group: PaletteGroup.actions,
        title: 'Toggle Bottom Dock',
        typeLabel: 'Action',
        icon: _icon(Icons.vertical_split_outlined),
        aliases: const ['logs', 'terminal'],
        shortcut: shortcutLabel('J'),
        run: dock.toggle,
      ),
    if (dock != null && localShellSupported)
      PaletteItem(
        group: PaletteGroup.actions,
        title: 'New Local Shell',
        typeLabel: 'Action',
        icon: _icon(Icons.laptop_mac),
        aliases: const ['terminal', 'kubectl', 'zsh', 'bash'],
        run: () => openLocalShell(context),
      ),
    if (app.detail != null)
      PaletteItem(
        group: PaletteGroup.actions,
        title: 'Toggle Inspector',
        typeLabel: 'Action',
        icon: _icon(Icons.view_sidebar_outlined),
        shortcut: shortcutLabel('I'),
        run: app.toggleInspector,
      ),
    if (app.view == MainView.resources && app.selectedType != null)
      PaletteItem(
        group: PaletteGroup.actions,
        title: 'Save Current Table as View…',
        typeLabel: 'Action',
        icon: _icon(Icons.bookmark_add_outlined),
        aliases: const ['view', 'bookmark'],
        run: () => _saveTableAsView(context),
      ),
    PaletteItem(
      group: PaletteGroup.actions,
      title: 'Import Views…',
      typeLabel: 'Action',
      icon: _icon(Icons.download_outlined),
      aliases: const ['view', 'yaml'],
      run: () => showImportViewsDialog(context),
    ),
    if (!app.readOnly)
      PaletteItem(
        group: PaletteGroup.actions,
        title: 'New Resource…',
        typeLabel: 'Action',
        icon: _icon(Icons.add),
        aliases: const ['create', 'apply', 'manifest', 'yaml'],
        run: () => openCreateResource(context, kind: app.view == MainView.resources ? app.selectedType : null, namespace: app.namespace),
      ),
    if (app.detail case final d?)
      PaletteItem(
        group: PaletteGroup.actions,
        title: 'Open in Editor',
        detail: d.name,
        typeLabel: 'Action',
        icon: _icon(Icons.edit_note),
        aliases: const ['edit', 'yaml'],
        run: () => openResourceEditor(context, d),
      ),
    PaletteItem(
      group: PaletteGroup.actions,
      title: 'Customise Sidebar…',
      typeLabel: 'Action',
      icon: _icon(Icons.tune),
      run: () => showSidebarEditor(context),
    ),
    PaletteItem(
      group: PaletteGroup.actions,
      title: 'Integrations…',
      typeLabel: 'Action',
      icon: _icon(Icons.extension_outlined),
      aliases: const ['modules', 'plugins', 'settings'],
      run: () => showIntegrationsDialog(context),
    ),
    PaletteItem(
      group: PaletteGroup.actions,
      title: 'Rediscover API Resources',
      typeLabel: 'Action',
      icon: _icon(Icons.refresh),
      aliases: const ['reload', 'refresh kinds'],
      run: () => app.refreshTypes(),
    ),
    if (updates != null)
      PaletteItem(
        group: PaletteGroup.actions,
        title: 'Check for Updates…',
        typeLabel: 'Action',
        icon: _icon(Icons.system_update_alt),
        run: updates.checkNow,
      ),
    PaletteItem(
      group: PaletteGroup.actions,
      title: 'About k8sman',
      typeLabel: 'Action',
      icon: _icon(Icons.info_outline),
      run: () => showAboutPanel(context),
    ),
  ];
}

PaletteItem objectItem(AppState app, ResourceType type, TableRowData row) => PaletteItem(
      group: PaletteGroup.objects,
      title: row.name,
      detail: type.namespaced ? row.namespace : null,
      typeLabel: type.kind,
      icon: (c) => kindIconWidget(type, size: 15, color: c),
      current: app.detail?.type == type && app.detail?.name == row.name && app.detail?.namespace == (type.namespaced ? row.namespace : null),
      // Same as clicking the row in its table.
      run: () => app.openDetail(DetailTarget(type: type, name: row.name, namespace: type.namespaced ? row.namespace : null)),
    );

/// The table currently on screen under [root] (its rows are already
/// loaded), or null. Found by walking down to the [ResourceTableView] and
/// reading the [TableController] it provides.
TableController? visibleTable(BuildContext root) {
  TableController? found;
  void inside(Element e) {
    if (found != null) return;
    try {
      found = Provider.of<TableController>(e, listen: false);
    } on ProviderNotFoundException {
      e.visitChildren(inside);
    }
  }

  void visit(Element e) {
    if (found != null) return;
    if (e.widget is ResourceTableView) {
      e.visitChildren(inside);
    } else {
      e.visitChildren(visit);
    }
  }

  (root as Element).visitChildren(visit);
  return found;
}

/// Kinds the palette looks up by name besides the visible table.
const paletteLookupKinds = [
  '/Pod',
  'apps/Deployment',
  'apps/StatefulSet',
  'apps/DaemonSet',
  'batch/Job',
  'batch/CronJob',
  '/Service',
  'networking.k8s.io/Ingress',
  '/ConfigMap',
  '/PersistentVolumeClaim',
  '/Node',
];

/// Names of [paletteLookupKinds] objects in the selected namespace, from
/// one table list per kind (served from the backend's warm watch when the
/// kind's table is open). Kept briefly so reopening the palette is instant.
/// A saved view as a palette item (also used by `:view`).
PaletteItem viewPaletteItem(BuildContext context, AppState app, SavedView v) {
  final elsewhere = v.context != null && !app.isCurrentContext(v.context!);
  return PaletteItem(
    group: PaletteGroup.views,
    title: v.name,
    detail: v.context == null ? 'any context' : (elsewhere ? '${v.context!.name} ⇄' : v.context!.name),
    typeLabel: 'View',
    icon: _icon(Icons.bookmark_outline),
    aliases: [v.kind, ...v.namespaces],
    current: app.activeView?.id == v.id,
    run: () => openSavedView(context, v),
  );
}

/// Save Current Table as View: the open table's controller holds what to
/// save (filter, sort, columns).
void _saveTableAsView(BuildContext context) {
  final tc = visibleTable(context);
  if (tc != null) showSaveViewDialog(context, tc);
}

class PaletteObjectCache {
  PaletteObjectCache._();

  static const ttl = Duration(seconds: 30);
  static final Map<String, (DateTime, List<TableRowData>)> _cache = {};

  static void clear() => _cache.clear();

  /// Calls [onRows] once per kind as each list arrives (cached ones right
  /// away). Failures (RBAC, timeouts) are skipped quietly.
  static Future<void> load(
    ApiClient api,
    AppState app, {
    ResourceType? skip,
    required void Function(ResourceType type, List<TableRowData> rows) onRows,
  }) async {
    final now = DateTime.now();
    final pending = <Future<void>>[];
    for (final gk in paletteLookupKinds) {
      final i = gk.indexOf('/');
      final t = app.typeFor(gk.substring(0, i), gk.substring(i + 1));
      if (t == null || t == skip || (t.verbs.isNotEmpty && !t.verbs.contains('list'))) continue;
      final scope = t.namespaced ? app.namespaceScope : NamespaceScope.all;
      final key = '${app.currentContext}|$scope|$gk';
      final hit = _cache[key];
      if (hit != null && now.difference(hit.$1) < ttl) {
        onRows(t, hit.$2);
        continue;
      }
      pending.add(() async {
        try {
          final table = await (scope.isMulti ? api.table(t.ref, scope: scope) : api.table(t.ref, namespace: scope.single))
              .timeout(const Duration(seconds: 8));
          _cache[key] = (DateTime.now(), table.rows);
          onRows(t, table.rows);
        } catch (_) {
          // Not listable here; the palette just doesn't offer these.
        }
      }());
    }
    await Future.wait(pending);
  }
}
