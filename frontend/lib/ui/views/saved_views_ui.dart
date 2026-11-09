import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'dart:io';

import '../../actions/actions.dart' show showActionError;
import '../../app/kubeconfig_picker.dart' show NativeFiles;
import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../state/table_controller.dart';
import '../widgets/common.dart' show copyToClipboard;
import '../widgets/dialogs.dart';

/// A short default name from the table's state, e.g.
/// "Deployment · team-1, team-2 +2 · back-end".
String defaultViewName(ResourceType t, NamespaceScope scope, String filter) =>
    [t.kind, if (t.namespaced && !scope.isAll) scope.label, if (filter.trim().isNotEmpty) filter.trim()].join(' · ');

/// "any context" or the bound context's name.
String viewContextLabel(SavedView v) => v.context == null ? 'any context' : v.context!.name;

/// Opens [v] and handles what can go wrong: a bound context that isn't in
/// the kubeconfig (offers to re-point it, never falls back silently) and a
/// kind the cluster doesn't serve.
Future<void> openSavedView(BuildContext context, SavedView v) async {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final r = await app.openView(v);
  switch (r) {
    case ViewOpenResult.opened || ViewOpenResult.failed:
      // A failed switch shows the cluster error screen already.
      return;
    case ViewOpenResult.notServed:
      messenger?.showSnackBar(SnackBar(content: Text('${v.kind} isn\'t served by ${app.currentContext}'), duration: const Duration(seconds: 4)));
    case ViewOpenResult.missingContext:
      if (!context.mounted) return;
      final fixed = await showRepointDialog(context, v);
      if (fixed != null && context.mounted) {
        await app.saveView(fixed);
        if (context.mounted) await openSavedView(context, fixed);
      }
  }
}

/// The contexts of the current kubeconfig, those with the same API server
/// URL as [c] first.
List<(ContextInfo, bool)> repointCandidates(AppState app, ViewContext? c) {
  final same = [for (final x in app.contexts) if (c?.server != null && x.server == c!.server) x];
  return [for (final x in same) (x, true), for (final x in app.contexts) if (!same.contains(x)) (x, false)];
}

/// "Context X not found": pick another context (matches by API server URL
/// first) or make the view apply to any context. Returns the changed view,
/// or null when cancelled.
Future<SavedView?> showRepointDialog(BuildContext context, SavedView v, {String? title}) {
  final app = context.read<AppState>();
  final candidates = repointCandidates(app, v.context);
  String? picked = candidates.where((c) => c.$2).firstOrNull?.$1.name;
  return showDialog<SavedView>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final theme = Theme.of(context);
        final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
        ContextInfo? info(String? n) => app.contexts.where((c) => c.name == n).firstOrNull;
        return AlertDialog(
          key: const ValueKey('repoint-dialog'),
          title: Text(title ?? 'Context “${v.context?.name}” not found'),
          content: SizedBox(
            width: 460,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(
                'The view “${v.name}” is bound to ${v.context?.name}${v.context?.kubeconfig.isNotEmpty == true ? ' in ${v.context!.kubeconfig}' : ''}, '
                'which the current kubeconfig doesn\'t have. Point it at another context, or make it apply to any context.',
              ),
              const SizedBox(height: 12),
              ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 260),
                child: ListView(shrinkWrap: true, children: [
                  for (final (c, same) in candidates)
                    ListTile(
                      dense: true,
                      visualDensity: VisualDensity.compact,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
                      selected: picked == c.name,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
                      leading: Icon(picked == c.name ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 16),
                      title: Text(c.name),
                      subtitle: Text([if (same) 'same API server', ?c.server].join(' · '), style: hint),
                      onTap: () => setState(() => picked = c.name),
                    ),
                ]),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            TextButton(
              onPressed: () => Navigator.pop(context, v.copyWith(context: () => null)),
              child: const Text('Make It Apply to Any Context'),
            ),
            FilledButton(
              onPressed: picked == null
                  ? null
                  : () => Navigator.pop(
                        context,
                        v.copyWith(context: () => ViewContext(kubeconfig: app.kubeconfigs.current, name: picked!, server: info(picked)?.server)),
                      ),
              child: const Text('Re-point'),
            ),
          ],
        );
      },
    ),
  );
}

/// A view of [tc]'s table as it is now: kind, namespaces, filter, sort and
/// columns. Applies to any context unless [anyContext] is false.
SavedView viewFromTable(AppState app, TableController tc, {required String name, bool anyContext = true, bool rememberSort = true}) {
  final scope = tc.type.namespaced ? app.namespaceScope : NamespaceScope.all;
  final sort = tc.sortColumn != null && tc.sortColumn! < tc.columns.length ? tc.columns[tc.sortColumn!].name : null;
  final info = app.contexts.where((c) => c.name == app.currentContext).firstOrNull;
  return SavedView(
    id: SavedView.newId(),
    name: name,
    context: anyContext ? null : ViewContext(kubeconfig: app.kubeconfigs.current, name: app.currentContext, server: info?.server),
    group: tc.type.group,
    kind: tc.type.kind,
    namespaces: scope.namespaces,
    filter: tc.filter.trim(),
    sortColumn: rememberSort ? sort : null,
    sortDescending: rememberSort && sort != null && !tc.sortAscending,
    columns: tc.columns,
  );
}

/// `:view save <name>`: saves the table as a view for any context, without
/// the dialog, and opens it.
Future<SavedView?> saveNamedView(BuildContext context, TableController tc, String name) =>
    _saveAndOpen(context, viewFromTable(context.read<AppState>(), tc, name: name));

/// The table toolbar's "Save view…" (and the palette's "Save current table
/// as view"): name, what is saved, and any context (default) or this
/// context only.
Future<SavedView?> showSaveViewDialog(BuildContext context, TableController tc) async {
  final app = context.read<AppState>();
  final saved = await showDialog<SavedView>(
    context: context,
    builder: (_) => ChangeNotifierProvider<AppState>.value(value: app, child: _SaveViewDialog(tc: tc)),
  );
  if (saved == null || !context.mounted) return null;
  return _saveAndOpen(context, saved);
}

Future<SavedView?> _saveAndOpen(BuildContext context, SavedView saved) async {
  final app = context.read<AppState>();
  try {
    await app.saveView(saved);
    // The table now shows the view (same state, as a view session).
    final r = await app.openView(saved);
    if (r != ViewOpenResult.opened && context.mounted) showActionError(context, 'Saved “${saved.name}”, but could not open it.');
  } catch (e) {
    if (context.mounted) showActionError(context, 'Could not save the view: $e');
    return null;
  }
  return saved;
}

class _SaveViewDialog extends StatefulWidget {
  final TableController tc;
  const _SaveViewDialog({required this.tc});

  @override
  State<_SaveViewDialog> createState() => _SaveViewDialogState();
}

class _SaveViewDialogState extends State<_SaveViewDialog> {
  late final AppState app = context.read<AppState>();
  late final TableController tc = widget.tc;
  late final NamespaceScope scope = tc.type.namespaced ? app.namespaceScope : NamespaceScope.all;
  late final _name = TextEditingController(text: defaultViewName(tc.type, scope, tc.filter));
  late bool _sort = tc.sortColumn != null;
  bool _anyContext = true;

  String? get _sortName => tc.sortColumn != null && tc.sortColumn! < tc.columns.length ? tc.columns[tc.sortColumn!].name : null;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _save() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, viewFromTable(app, tc, name: name, anyContext: _anyContext, rememberSort: _sort));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    Widget row(String label, Widget value) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 96, child: Text(label, style: hint)),
            Expanded(child: value),
          ]),
        );
    final cols = tc.columns.map((c) => c.name).toList();
    return AlertDialog(
      key: const ValueKey('save-view-dialog'),
      title: const Text('Save View'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(
            key: const ValueKey('save-view-name'),
            controller: _name,
            autofocus: true,
            decoration: const InputDecoration(labelText: 'Name'),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          row('Kind', Text(tc.type.kind)),
          if (tc.type.namespaced) row('Namespaces', Text(scope.isAll ? 'All namespaces' : scope.namespaces.join(' · '))),
          row('Filter', Text(tc.filter.trim().isEmpty ? 'None' : tc.filter.trim(), style: tc.filter.trim().isEmpty ? hint : null)),
          row('Columns', Text(cols.length <= 5 ? cols.join(', ') : '${cols.take(5).join(', ')} +${cols.length - 5}')),
          if (_sortName != null)
            CheckboxListTile(
              key: const ValueKey('save-view-sort'),
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _sort,
              onChanged: (v) => setState(() => _sort = v ?? false),
              title: Text('Remember sort ($_sortName ${tc.sortAscending ? '↑' : '↓'})'),
            ),
          const SizedBox(height: 6),
          row(
            'Context',
            Align(
              alignment: Alignment.centerLeft,
              child: SegmentedButton<bool>(
                key: const ValueKey('save-view-context'),
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                showSelectedIcon: false,
                segments: [
                  const ButtonSegment(value: true, label: Text('Any context')),
                  ButtonSegment(value: false, label: Text('Only ${app.currentContext}', overflow: TextOverflow.ellipsis)),
                ],
                selected: {_anyContext},
                onSelectionChanged: (s) => setState(() => _anyContext = s.first),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 96, top: 2),
            child: Text(
              _anyContext ? 'Opens on whichever context is current.' : 'Opening it switches to ${app.currentContext}.',
              style: hint,
            ),
          ),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        ValueListenableBuilder(
          valueListenable: _name,
          builder: (context, v, _) => FilledButton(
            key: const ValueKey('save-view-save'),
            onPressed: v.text.trim().isEmpty ? null : _save,
            child: const Text('Save'),
          ),
        ),
      ],
    );
  }
}

/// Asks for a new name.
Future<String?> showRenameViewDialog(BuildContext context, SavedView v) =>
    showTextPrompt(context, title: 'Rename View', initial: v.name, confirmLabel: 'Rename');

/// The menu of a saved view (sidebar right-click): Rename, Duplicate,
/// Change context, Copy as YAML, Open at Launch, Delete (with undo).
List<(String, VoidCallback)?> viewMenuItems(BuildContext context, SavedView v) {
  final app = context.read<AppState>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  Future<void> guard(Future<void> Function() f) async {
    try {
      await f();
    } catch (e) {
      if (context.mounted) showActionError(context, '$e');
    }
  }

  final info = app.contexts.where((c) => c.name == app.currentContext).firstOrNull;
  return [
    ('Open', () => openSavedView(context, v)),
    null,
    (
      'Rename…',
      () async {
        final name = await showRenameViewDialog(context, v);
        if (name != null && name.isNotEmpty && name != v.name) await guard(() => app.saveView(v.copyWith(name: name)));
      }
    ),
    ('Duplicate', () => guard(() => app.saveView(v.copyWith(id: SavedView.newId(), name: '${v.name} copy')))),
    v.context == null
        ? (
            'Only on ${app.currentContext}',
            () => guard(() => app.saveView(v.copyWith(context: () => ViewContext(kubeconfig: app.kubeconfigs.current, name: app.currentContext, server: info?.server))))
          )
        : ('Apply to Any Context', () => guard(() => app.saveView(v.copyWith(context: () => null)))),
    (
      'Export to File…',
      () => guard(() async {
            final yaml = await app.api.exportViews([v.toJson()]);
            if (context.mounted) await saveYamlFile(context, yaml, '${v.name}.yaml', label: 'view “${v.name}”');
          })
    ),
    (
      'Copy as YAML',
      () => guard(() async {
            final yaml = await app.api.exportViews([v.toJson()]);
            if (context.mounted) copyToClipboard(context, yaml, label: 'view “${v.name}” as YAML');
          })
    ),
    app.launchViewId == v.id
        ? ('Don\'t Open at Launch', () => guard(() => app.setLaunchView('')))
        : ('Open at Launch', () => guard(() => app.setLaunchView(v.id))),
    null,
    (
      'Delete',
      () => guard(() async {
            final removed = await app.deleteView(v.id);
            if (removed == null) return;
            messenger?.showSnackBar(SnackBar(
              content: Text('Deleted view “${v.name}”'),
              duration: const Duration(seconds: 6),
              action: SnackBarAction(label: 'Undo', onPressed: () => app.restoreView(removed.$1, removed.$2)),
            ));
          })
    ),
  ];
}

/// Paste YAML view documents (as Copy as YAML writes them) and import them.
/// A bound context that doesn't exist here is re-pointed: to the context
/// with the same API server URL when there is exactly one, else by asking.
Future<void> showImportViewsDialog(BuildContext context) async {
  final text = TextEditingController();
  final yaml = await showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Import Views'),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Paste one or more views (apiVersion: k8sman.dev/v1, kind: View), separated by ---.'),
          const SizedBox(height: 10),
          TextField(
            key: const ValueKey('import-views-text'),
            controller: text,
            autofocus: true,
            maxLines: 14,
            minLines: 8,
            style: const TextStyle(fontFamily: 'Menlo', fontSize: 12),
            decoration: const InputDecoration(hintText: 'apiVersion: k8sman.dev/v1\nkind: View\nname: …'),
          ),
        ]),
      ),
      actions: [
        TextButton(
          key: const ValueKey('import-views-file'),
          onPressed: () async {
            final yaml = await _readYamlFile(context);
            if (yaml != null && context.mounted) Navigator.pop(context, yaml);
          },
          child: const Text('From File…'),
        ),
        const SizedBox(width: 8),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, text.text), child: const Text('Import')),
      ],
    ),
  ).whenComplete(text.dispose);
  if (yaml == null || yaml.trim().isEmpty || !context.mounted) return;
  await importViewsYaml(context, yaml);
}

/// "Import from File…": choose a `.yaml` / `.yml` file and import its views.
Future<void> importViewsFromFile(BuildContext context) async {
  final yaml = await _readYamlFile(context);
  if (yaml != null && context.mounted) await importViewsYaml(context, yaml);
}

/// Asks for a YAML file and returns its text (null when cancelled).
Future<String?> _readYamlFile(BuildContext context) async {
  try {
    final path = await NativeFiles.chooseYaml();
    if (path == null) return null;
    return await File(path).readAsString();
  } catch (e) {
    if (context.mounted) showActionError(context, 'Could not read the file: $e');
    return null;
  }
}

/// Imports the view documents in [yaml] (see [showImportViewsDialog]).
Future<void> importViewsYaml(BuildContext context, String yaml) async {
  final app = context.read<AppState>();
  try {
    final parsed = [for (final j in await app.api.parseViews(yaml)) ?SavedView.fromJson(j)];
    var imported = 0;
    for (var v in parsed) {
      final c = v.context;
      if (c != null) {
        final byName = app.contexts.where((x) => x.name == c.name).firstOrNull;
        final byServer = [for (final x in app.contexts) if (c.server != null && x.server == c.server) x];
        final target = byName ?? (byServer.length == 1 ? byServer.first : null);
        if (target != null) {
          v = v.copyWith(context: () => ViewContext(kubeconfig: app.kubeconfigs.current, name: target.name, server: target.server ?? c.server));
        } else {
          if (!context.mounted) return;
          final fixed = await showRepointDialog(context, v, title: 'Import “${v.name}”: context “${c.name}” not found');
          if (fixed == null) continue;
          v = fixed;
        }
      }
      await app.saveView(v);
      imported++;
    }
    if (context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Imported $imported view${imported == 1 ? '' : 's'}')));
    }
  } on ApiException catch (e) {
    if (context.mounted) showActionError(context, 'Could not import: ${e.message}');
  } catch (e) {
    if (context.mounted) showActionError(context, 'Could not import: $e');
  }
}

/// Saves [yaml] to a file the user chooses; where the platform has no save
/// panel, copies it to the clipboard instead.
Future<void> saveYamlFile(BuildContext context, String yaml, String suggestedName, {required String label}) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    final path = await NativeFiles.saveYaml(suggestedName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_'), yaml);
    if (path != null) messenger?.showSnackBar(SnackBar(content: Text('Exported $label to $path')));
  } on UnsupportedError {
    if (context.mounted) copyToClipboard(context, yaml, label: '$label as YAML');
  } catch (e) {
    if (context.mounted) showActionError(context, 'Could not export: $e');
  }
}

/// Saves every saved view to a YAML file.
Future<void> exportAllViewsToFile(BuildContext context) async {
  final app = context.read<AppState>();
  try {
    final yaml = await app.api.exportViews([for (final v in app.savedViews) v.toJson()]);
    if (context.mounted) await saveYamlFile(context, yaml, 'k8sman-views.yaml', label: '${app.savedViews.length} views');
  } catch (e) {
    if (context.mounted) showActionError(context, 'Could not export: $e');
  }
}

/// Copies every saved view as YAML documents.
Future<void> exportAllViews(BuildContext context) async {
  final app = context.read<AppState>();
  try {
    final yaml = await app.api.exportViews([for (final v in app.savedViews) v.toJson()]);
    if (context.mounted) copyToClipboard(context, yaml, label: '${app.savedViews.length} views as YAML');
  } catch (e) {
    if (context.mounted) showActionError(context, 'Could not export: $e');
  }
}

/// Saved views grouped by context, for the connecting and cluster error
/// screens: a dead last context isn't a dead end. Opening one goes through
/// [openSavedView] (switching context when it is bound to another).
///
/// Only views bound to a context other than [except] are listed: a view
/// for any context needs a working cluster.
class SavedViewsList extends StatelessWidget {
  final String title;

  /// The context that is failing or connecting.
  final String? except;
  const SavedViewsList({super.key, this.title = 'Or open a saved view', this.except});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final views = [for (final v in app.savedViews) if (v.context != null && v.context!.name != except) v];
    if (views.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final groups = <String, List<SavedView>>{};
    for (final v in views) {
      (groups[v.context?.name ?? ''] ??= []).add(v);
    }
    final keys = groups.keys.toList()..sort((a, b) => a.isEmpty ? -1 : (b.isEmpty ? 1 : a.compareTo(b)));
    return ConstrainedBox(
      key: const ValueKey('saved-views-list'),
      constraints: const BoxConstraints(maxWidth: 420, maxHeight: 220),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(title, style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        Flexible(
          child: ListView(shrinkWrap: true, children: [
            for (final k in keys) ...[
              Padding(padding: const EdgeInsets.only(top: 4, bottom: 2), child: Text(k.isEmpty ? 'Any context' : k, style: hint)),
              for (final v in groups[k]!)
                InkWell(
                  borderRadius: BorderRadius.circular(5),
                  onTap: () => openSavedView(context, v),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(children: [
                      Icon(Icons.bookmark_outline, size: 14, color: theme.colorScheme.primary),
                      const SizedBox(width: 8),
                      Flexible(child: Text(v.name, overflow: TextOverflow.ellipsis)),
                      const SizedBox(width: 8),
                      Text(v.kind, style: hint),
                    ]),
                  ),
                ),
            ],
          ]),
        ),
      ]),
    );
  }
}
