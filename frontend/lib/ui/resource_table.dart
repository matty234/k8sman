import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../actions/actions.dart' show showActionError;
import '../actions/bulk.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../app/window_chrome.dart';
import '../metrics/quantity.dart' show thresholdSeverity;
import '../metrics/quantity_cell.dart';
import 'widgets/editorial.dart' show HairlineBar;
import '../state/app_state.dart';
import '../state/cluster_error.dart';
import '../state/table_controller.dart';
import '../state/table_query.dart' show cellText, fieldKey;
import '../util/k8s.dart';
import '../util/node_os.dart';
import 'cluster_error_view.dart';
import 'column_editor.dart';
import 'resource_nav.dart' show showKindMenu;
import '../actions/actions.dart' show ResourceAction;
import '../panels/registry.dart';
import '../plugins/plugin_host.dart' show pluginHost;
import 'detail/detail_sidebar.dart' show resourceActionsFor;
import 'keyboard_help.dart';
import 'kubectl_menu.dart';
import 'logs/open_logs.dart' show hasWorkloadLogs, kLogsActionId, openPodsLogs, openWorkloadsLogs;
import 'row_context_menu.dart';
import 'terminal/open_terminal.dart' show kTerminalActionId;
import 'theme.dart';
import 'widgets/common.dart';
import 'editor/resource_editor_screen.dart';
import 'table_filter_field.dart';
import 'widgets/group_icon.dart';
import 'widgets/node_os_icon.dart';
import 'widgets/namespace_picker.dart';
import 'widgets/partial_banner.dart';
import 'views/saved_views_ui.dart';
import 'widgets/page_mode_switch.dart';
import '../modules/modules.dart' show pageFor;
import 'widgets/context_menu.dart';

/// Live table for the selected resource type. Re-created (via key) whenever
/// the type, namespace or column config changes.
class ResourceTableView extends StatelessWidget {
  final ResourceType type;
  const ResourceTableView({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    // An open saved view of this kind runs the table as a view session.
    final session = app.viewSession?.view.gk == type.gk ? app.viewSession : null;
    return ChangeNotifierProvider<TableController>(
      key: ValueKey('${type.gk}|${app.namespaceScope}|${app.columnsVersion}|${app.currentContext}|${session?.view.id}|${app.viewRevision}'),
      create: (_) => TableController(api: context.read<ApiClient>(), type: type, scope: app.namespaceScope, prefs: app.tablePrefs, session: session),
      child: const _TableBody(),
    );
  }
}

class _TableBody extends StatefulWidget {
  const _TableBody();

  @override
  State<_TableBody> createState() => _TableBodyState();
}

class _TableBodyState extends State<_TableBody> {
  final _hScroll = ScrollController();
  final _vScroll = ScrollController();
  FocusNode get _focus => context.read<TableController>().bodyFocus;
  Timer? _ageTicker;

  static const _rowHeight = 28.0;

  @override
  void initState() {
    super.initState();
    // Re-render ages periodically without per-cell timers.
    _ageTicker = Timer.periodic(const Duration(seconds: 30), (_) => mounted ? setState(_rowCache.clear) : null);
  }

  @override
  void dispose() {
    _ageTicker?.cancel();
    _hScroll.dispose();
    _vScroll.dispose();
    _bulkProgress.dispose();
    super.dispose();
  }

  final _bulkProgress = ValueNotifier<BulkProgress?>(null);

  @override
  Widget build(BuildContext context) {
    final tc = context.watch<TableController>();
    final app = context.watch<AppState>();
    final rows = tc.rows;
    final selectedRows = tc.selectedRows;
    final multi = selectedRows.length >= 2;
    // No rows because the list failed: explain why instead of "No pods".
    final failedEmpty = tc.failure != null && tc.totalCount == 0;
    // "Filter by this label" from the inspector.
    final term = app.takeFilterTerm(tc.type.gk);
    if (term != null) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? _addTerm(tc, term) : null);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(tc, rows.length),
        if (tc.error != null && !failedEmpty) _StaleBanner(controller: tc),
        if (tc.partialErrors.isNotEmpty) PartialBanner(errors: tc.partialErrors),
        const Divider(),
        if (multi) ...[
          _SelectionBar(
            controller: tc,
            rows: selectedRows,
            actions: bulkActionsFor(app, tc.type, selectedRows),
            progress: _bulkProgress,
            onRun: (a) => _runBulk(a, selectedRows),
          ),
          const Divider(),
        ],
        Expanded(
          child: tc.loading || (failedEmpty && !tc.failureShown)
              ? const Center(child: CircularProgressIndicator())
              : failedEmpty
              ? ClusterErrorView(
                  error: tc.failure!,
                  resource: tc.type.resource,
                  namespace: tc.type.namespaced && !tc.scope.isAll ? tc.scope.label : null,
                  namespaced: tc.type.namespaced,
                  onRetry: tc.retry,
                  onRediscover: app.refreshTypes,
                )
              : LayoutBuilder(
                  builder: (context, box) {
                    final widths = _stableWidths(_columnWidths(tc.columns, box.maxWidth, app.tablePrefs.of(tc.type.gk).widths, nameFit: _nameFit(rows)));
                    final total = widths.fold<double>(0, (a, b) => a + b) + 18; // + gutters
                    return Scrollbar(
                      controller: _hScroll,
                      child: SingleChildScrollView(
                        controller: _hScroll,
                        scrollDirection: Axis.horizontal,
                        child: SizedBox(
                          width: math.max(total, box.maxWidth),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _header(tc, widths),
                              const Divider(),
                              Expanded(
                                child: rows.isEmpty
                                    ? _EmptyTable(controller: tc)
                                    : Focus(
                                        focusNode: _focus,
                                        // Keys work without a click first; never steals from a focused field.
                                        autofocus: true,
                                        onKeyEvent: (node, e) => _onKey(e, rows, app),
                                        child: Scrollbar(
                                          controller: _vScroll,
                                          child: ListView.builder(
                                            controller: _vScroll,
                                            padding: const EdgeInsets.only(top: 4, bottom: 8),
                                            itemExtent: _rowHeight,
                                            // Rows hold no state worth keeping alive off screen; skipping
                                            // the keep-alive wrappers saves 4 rebuilt widgets per row per frame.
                                            addAutomaticKeepAlives: false,
                                            itemCount: rows.length,
                                            itemBuilder: (_, i) {
                                              final row = rows[i];
                                              final sel = multi && tc.isSelected(row.uid);
                                              return _rowWidget(
                                                tc,
                                                app,
                                                row,
                                                widths,
                                                striped: i.isOdd,
                                                inspected: _isInspected(app, tc.type, row),
                                                selected: sel,
                                                joinAbove: sel && i > 0 && tc.isSelected(rows[i - 1].uid),
                                                joinBelow: sel && i + 1 < rows.length && tc.isSelected(rows[i + 1].uid),
                                              );
                                            },
                                          ),
                                        ),
                                      ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  /// The last widths, reused while equal so cached rows stay valid.
  List<double> _widths = const [];
  List<double> _stableWidths(List<double> w) => listEquals(w, _widths) ? _widths : _widths = w;

  /// The width the longest row name needs in the name column (text plus
  /// the cell's padding and status mark), worked out again only when the
  /// rows change, and only ever growing while the table shows one kind so
  /// the column doesn't jitter as rows come and go.
  double? _nameFit(List<TableRowData> rows) {
    if (identical(rows, _nameRows)) return _nameWidth;
    _nameRows = rows;
    var longest = '';
    for (final r in rows) {
      if (r.name.length > longest.length) longest = r.name;
    }
    if (longest.isEmpty) return _nameWidth;
    final style = Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w500);
    final p = TextPainter(text: TextSpan(text: longest, style: style), textDirection: TextDirection.ltr, maxLines: 1, textScaler: MediaQuery.textScalerOf(context))..layout();
    final w = p.width + 40;
    p.dispose();
    return _nameWidth = math.max(_nameWidth ?? 0, w);
  }

  List<TableRowData>? _nameRows;
  double? _nameWidth;

  // Toolbar and header, reused while what they show is unchanged (a watch
  // event usually changes neither). They still rebuild on their own
  // inherited dependencies (theme, AppState).
  _Toolbar? _toolbarCache;
  _Toolbar _toolbar(TableController tc, int shown) {
    final t = _toolbarCache;
    if (t != null && t.shown == shown && t.total == tc.totalCount && t.loaded == tc.loaded && t.isDefaultColumns == tc.isDefaultColumns) return t;
    return _toolbarCache = _Toolbar(controller: tc, shown: shown);
  }

  _Header? _headerCache;
  _Header _header(TableController tc, List<double> widths) {
    final h = _headerCache;
    if (h != null &&
        identical(h.widths, widths) &&
        identical(h.columns, tc.columns) &&
        h.sortColumn == tc.sortColumn &&
        h.sortAscending == tc.sortAscending &&
        identical(h.columnErrors, tc.columnErrors)) {
      return h;
    }
    return _headerCache = _Header(controller: tc, widths: widths, onResize: _resize, onResizeDone: _resizeDone, onFitWidth: _fitWidth, onReorder: _reorder);
  }

  /// Dragging a header divider: the column keeps that width (for this kind,
  /// for the session) and no longer stretches.
  void _resize(int col, double width) {
    final tc = context.read<TableController>();
    if (col >= tc.columns.length) return;
    final prefs = context.read<AppState>().tablePrefs;
    prefs.of(tc.type.gk).widths[tc.columns[col].name] = width.clamp(_minColumnWidth, 2000.0).roundToDouble();
    setState(() {});
  }

  /// A header was dragged to a new position: save the column order (as the
  /// kind's column configuration, like the column editor) and reload. If
  /// the order is back to the defaults, drop the override instead, so the
  /// kind keeps getting new default columns.
  Future<void> _reorder(int from, int to) async {
    final tc = context.read<TableController>();
    final app = context.read<AppState>();
    final api = context.read<ApiClient>();
    final cols = List.of(tc.columns);
    cols.insert(to, cols.removeAt(from));
    // In a saved view the order is the view's (saved with Update view).
    if (tc.session != null) return app.viewColumnsChanged(cols);
    try {
      final cfg = await api.getColumns(tc.type.ref);
      String sig(List<ColumnDef> l) => [for (final c in l) '${c.name}\u0000${c.query}\u0000${c.type}'].join('\u0001');
      if (sig(cols) == sig(cfg.defaults)) {
        await api.resetColumns(tc.type.ref);
      } else {
        await api.putColumns(tc.type.ref, cols);
      }
      app.columnsChanged();
    } catch (e) {
      if (mounted) showActionError(context, 'Could not move the column: $e');
    }
  }

  /// A drag ended: save the widths once.
  void _resizeDone() {
    final tc = context.read<TableController>();
    context.read<AppState>().tablePrefs.changed(tc.type.gk);
  }

  /// Double-clicking a divider: the column takes the width of its widest
  /// text (header, or up to 500 loaded rows), at most 600px. Saved like a
  /// drag. Already fitted, it goes back to the default width instead.
  void _fitWidth(int col) {
    final tc = context.read<TableController>();
    if (col >= tc.columns.length) return;
    final prefs = context.read<AppState>().tablePrefs;
    final c = tc.columns[col];
    final widths = prefs.of(tc.type.gk).widths;
    final theme = Theme.of(context);
    final cellStyle = theme.textTheme.bodyMedium?.copyWith(fontSize: 12.5, fontWeight: col == 0 ? FontWeight.w500 : null);
    final headStyle = theme.textTheme.labelMedium?.copyWith(fontWeight: FontWeight.w600);
    double measure(String t, TextStyle? st) {
      final p = TextPainter(text: TextSpan(text: t, style: st), textDirection: TextDirection.ltr, maxLines: 1)..layout();
      final w = p.width;
      p.dispose();
      return w;
    }

    // + header sort arrow; cells pad 6 each side. Status badges add padding.
    var best = measure(c.name, headStyle) + 18;
    final rows = tc.rows;
    final step = math.max(1, (rows.length / 500).ceil());
    for (var r = 0; r < rows.length; r += step) {
      final v = rows[r].cells.elementAtOrNull(col);
      final t = switch (c.type) {
        'age' => parseTime(v) != null ? formatAge(parseTime(v)!) : cellText(v),
        'until' => parseTime(v) != null ? formatUntil(parseTime(v)!) : cellText(v),
        'nodeos' => nodeOsOf(nodeFromOsCell(cellText(v)))?.label ?? '',
        _ => cellText(v),
      };
      if (t.isEmpty) continue;
      // Usage cells add the bar and percentage beside the value.
      best = math.max(best, measure(t, cellStyle) + switch (c.type) { 'status' => 20, 'usage' => 78, 'nodeos' => 20, _ => 0 });
    }
    final fit = (best + 14).clamp(_minColumnWidth, 600.0).ceilToDouble();
    if (widths[c.name] == fit) {
      widths.remove(c.name);
    } else {
      widths[c.name] = fit;
    }
    prefs.changed(tc.type.gk);
    setState(() {});
  }

  /// Row widgets by UID. A watch event changes one row, but the list's
  /// builder runs for every visible row: returning the identical widget for
  /// rows whose inputs are unchanged lets Flutter skip rebuilding them.
  /// Cleared when ages re-render; the inputs below are the rest of the key.
  final Map<String, _Row> _rowCache = {};

  Widget _rowWidget(
    TableController tc,
    AppState app,
    TableRowData row,
    List<double> widths, {
    required bool striped,
    required bool inspected,
    required bool selected,
    required bool joinAbove,
    required bool joinBelow,
  }) {
    final c = _rowCache[row.uid];
    if (c != null &&
        identical(c.row, row) &&
        identical(c.widths, widths) &&
        identical(c.columns, tc.columns) &&
        c.striped == striped &&
        c.inspected == inspected &&
        c.selected == selected &&
        c.joinAbove == joinAbove &&
        c.joinBelow == joinBelow) {
      return c;
    }
    if (_rowCache.length > 600) _rowCache.clear(); // deleted / scrolled-past rows
    return _rowCache[row.uid] = _Row(
      key: ValueKey(row.uid),
      row: row,
      columns: tc.columns,
      widths: widths,
      striped: striped,
      inspected: inspected,
      selected: selected,
      joinAbove: joinAbove,
      joinBelow: joinBelow,
      onTap: () {
        _focus.requestFocus();
        _click(tc, app, row);
      },
      // Decided at click time (the selection may have changed since).
      onContextMenu: (pos, col) {
        final selectedRows = tc.selectedRows;
        selectedRows.length >= 2 && tc.isSelected(row.uid)
            ? _showBulkMenu(context, pos, tc, app, selectedRows)
            : showRowContextMenu(context, pos, tc.type, row, cellFilter: _cellFilter(tc, row, col));
      },
    );
  }

  /// "Filter by" / "Exclude" for the right-clicked cell: a `column=value`
  /// term added to the filter. Not for empty cells, or columns whose text
  /// doesn't make a useful term (ages, usage, label sets).
  static CellFilter? _cellFilter(TableController tc, TableRowData row, int? col) {
    if (col == null || col >= tc.columns.length) return null;
    final column = tc.columns[col];
    if (const {'age', 'until', 'usage', 'labels', 'percent'}.contains(column.type)) return null;
    final key = fieldKey(column.name);
    final value = cellText(col < row.cells.length ? row.cells[col] : null).trim();
    if (key.isEmpty || value.isEmpty || value.length > 80 || value.contains('"')) return null;
    final v = value.contains(RegExp(r'\s')) ? '"$value"' : value;
    return CellFilter(column: column.name, value: value, include: () => _addTerm(tc, '$key=$v'), exclude: () => _addTerm(tc, '$key!=$v'));
  }

  /// [term] appended to the filter (unless it is already there).
  static void _addTerm(TableController tc, String term) {
    final f = tc.filter.trim();
    if (f.split(RegExp(r'\s+')).contains(term)) return;
    tc.setFilter('${f.isEmpty ? '' : '$f '}$term ');
  }

  static bool _isInspected(AppState app, ResourceType type, TableRowData row) =>
      app.detail?.type == type && app.detail?.name == row.name && app.detail?.namespace == (type.namespaced ? row.namespace : null);

  void _open(AppState app, ResourceType type, TableRowData row, {DetailTab? tab}) =>
      app.openDetail(DetailTarget(type: type, name: row.name, namespace: type.namespaced ? row.namespace : null, seed: row.object), tab: tab);

  /// Plain click: select just this row and inspect it. ⌘-click toggles it
  /// in the selection; ⇧-click selects the range from the anchor.
  void _click(TableController tc, AppState app, TableRowData row) {
    final keys = HardwareKeyboard.instance;
    if (keys.isMetaPressed || keys.isControlPressed) {
      // Starting a multi-selection from the inspected row keeps it in.
      if (tc.selection.isEmpty) {
        final inspected = tc.rows.where((r) => _isInspected(app, tc.type, r)).firstOrNull;
        if (inspected != null && inspected.uid != row.uid) tc.selection.add(inspected.uid);
      }
      tc.toggleSelected(row.uid);
      return;
    }
    if (keys.isShiftPressed) {
      tc.anchor ??= tc.rows.where((r) => _isInspected(app, tc.type, r)).firstOrNull?.uid;
      tc.selectRange(row.uid);
      return;
    }
    tc.selectOnly(row.uid);
    _open(app, tc.type, row);
  }

  /// One merged log tab for exactly the selected pods (one per namespace).
  /// Logs of several selected rows: the pods themselves, or (workload rows)
  /// all the pods of every selected workload.
  bool _canMergeLogs(TableController tc) => tc.type.gk == '/Pod' || hasWorkloadLogs(tc.type.kind);

  void _openSelectedLogs(TableController tc, List<TableRowData> rows) {
    if (tc.type.gk != '/Pod') {
      openWorkloadsLogs(context, tc.type, rows);
      return;
    }
    _openSelectedPodLogs(rows);
  }

  void _openSelectedPodLogs(List<TableRowData> rows) {
    final byNs = <String, List<String>>{};
    for (final r in rows) {
      (byNs[r.namespace ?? ''] ??= []).add(r.name);
    }
    for (final e in byNs.entries) {
      openPodsLogs(context, e.key, e.value);
    }
  }

  Future<void> _runBulk(BulkAction action, List<TableRowData> rows) async {
    final tc = context.read<TableController>();
    await runBulkAction(
      context,
      api: context.read<ApiClient>(),
      app: context.read<AppState>(),
      targets: [for (final r in rows) BulkTarget.fromRow(tc.type, r)],
      action: action,
      progress: _bulkProgress,
    );
  }

  /// Right-click on a row of a multi-selection: actions for all of them.
  Future<void> _showBulkMenu(BuildContext context, Offset globalPosition, TableController tc, AppState app, List<TableRowData> rows) async {
    final theme = Theme.of(context);
    final actions = bulkActionsFor(app, tc.type, rows);
    PopupMenuItem<VoidCallback> item(IconData icon, String label, VoidCallback run, {bool danger = false}) => menuItem(run, icon, label, danger: danger);

    final names = rows.map((r) => tc.type.namespaced && r.namespace != null ? '${r.namespace}/${r.name}' : r.name).join('\n');
    final safe = actions.where((a) => !a.destructive);
    final destructive = actions.where((a) => a.destructive);
    final chosen = await showContextMenuAt<VoidCallback>(
      context,
      globalPosition,
      [
        PopupMenuItem<VoidCallback>(
          enabled: false,
          height: 26,
          child: Text('${rows.length} ${tc.type.resource} selected', style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor)),
        ),
        if (_canMergeLogs(tc)) item(Icons.layers_outlined, 'Logs (${rows.length} ${tc.type.resource})', () => _openSelectedLogs(tc, rows)),
        for (final a in safe) item(a.icon, '${a.verb} ${rows.length} ${tc.type.resource}', () => _runBulk(a, rows)),
        const PopupMenuDivider(height: 9),
        item(Icons.content_copy, 'Copy names', () => copyToClipboard(context, names, label: '${rows.length} names')),
        item(Icons.terminal, 'Copy kubectl command…', () {
          showKubectlMenu(context, globalPosition, app: app, type: tc.type, refs: [for (final r in rows) (namespace: r.namespace, name: r.name)]);
        }),
        item(Icons.deselect, 'Clear selection', tc.clearSelection),
        if (destructive.isNotEmpty) const PopupMenuDivider(height: 9),
        for (final a in destructive) item(a.icon, '${a.verb} ${rows.length} ${tc.type.resource}…', () => _runBulk(a, rows), danger: true),
      ],
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
    );
    if (chosen != null && context.mounted) chosen();
  }

  void _scrollTo(int idx) {
    if (!_vScroll.hasClients) return;
    final y = idx * _rowHeight;
    if (y < _vScroll.offset || y > _vScroll.offset + _vScroll.position.viewportDimension - _rowHeight) {
      _vScroll.jumpTo((y - _vScroll.position.viewportDimension / 2).clamp(0, _vScroll.position.maxScrollExtent));
    }
  }

  /// Select just row [idx], inspect it and scroll it into view.
  void _goto(TableController tc, AppState app, List<TableRowData> rows, int idx, {DetailTab? tab}) {
    tc.selectOnly(rows[idx].uid);
    _open(app, tc.type, rows[idx], tab: tab);
    _scrollTo(idx);
  }

  /// The row single-row keys act on: the cursor, else the inspected row.
  int _currentIndex(TableController tc, AppState app, List<TableRowData> rows) {
    final i = tc.cursor == null ? -1 : rows.indexWhere((r) => r.uid == tc.cursor);
    return i >= 0 ? i : rows.indexWhere((r) => _isInspected(app, tc.type, r));
  }

  /// Runs the row's resource action [id] (the one labelled [label], if
  /// given) for l / s / ⇧F / ⌃D, or says why it isn't available.
  Future<void> _rowAction(TableController tc, AppState app, TableRowData row, String id, String what, {String? label}) async {
    final api = context.read<ApiClient>();
    final type = tc.type;
    final ns = type.namespaced ? row.namespace : null;
    final messenger = ScaffoldMessenger.maybeOf(context);
    ResourceAction? action;
    try {
      final object = await api.object(type.ref, namespace: ns, name: row.name);
      if (!mounted) return;
      final target = DetailTarget(type: type, name: row.name, namespace: ns);
      final actions = resourceActionsFor(app, target, panelFor(type, app), PanelContext(object: object, type: type, api: api, app: app));
      action = actions.where((a) => a.id == id && (label == null || a.label == label)).firstOrNull;
    } catch (_) {}
    if (!mounted) return;
    if (action == null) {
      messenger?.showSnackBar(SnackBar(content: Text('No $what for ${type.kind}'), duration: const Duration(seconds: 2)));
      return;
    }
    await action.run(context);
  }

  /// Single-key bindings (k9s style), only without ⌘/Ctrl/Alt; see
  /// [showKeyboardHelp] for the list. Returns whether [e] was one.
  bool _letterKey(KeyEvent e, List<TableRowData> rows, AppState app, TableController tc) {
    final shift = HardwareKeyboard.instance.isShiftPressed;
    final key = e.logicalKey;
    final repeat = e is KeyRepeatEvent;
    bool did(VoidCallback f) {
      f();
      return true;
    }

    final idx = _currentIndex(tc, app, rows);
    final row = idx < 0 ? null : rows[idx];

    void step(int d) => _goto(tc, app, rows, ((idx < 0 && d < 0 ? 0 : idx) + d).clamp(0, rows.length - 1));
    void inspect(DetailTab? tab) => row == null ? _goto(tc, app, rows, 0, tab: tab) : _goto(tc, app, rows, idx, tab: tab);
    void act(String id, String what) => row == null
        ? ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('Select a row first'), duration: Duration(seconds: 2)))
        : _rowAction(tc, app, row, id, what);

    if (!shift) {
      if (key == LogicalKeyboardKey.keyJ) return did(() => step(1));
      if (key == LogicalKeyboardKey.keyK) return did(() => step(-1));
      if (key == LogicalKeyboardKey.keyG) return did(() => _goto(tc, app, rows, 0));
      if (key == LogicalKeyboardKey.slash) return did(() => tc.filterFocus.requestFocus());
    }
    if (shift && key == LogicalKeyboardKey.keyG) return did(() => _goto(tc, app, rows, rows.length - 1));
    if (repeat) return false;
    if (shift && key == LogicalKeyboardKey.slash) return did(() => showKeyboardHelp(context));
    if (shift && key == LogicalKeyboardKey.keyF) return did(() => act('port-forward', 'port-forward'));
    // A plugin action's `shortcut` (the row's, once the inspector has
    // loaded its actions); the built-in keys above and below win.
    bool pluginKey() {
      final a = row == null ? null : pluginHost.actionForKey(row.uid, key, shift: shift);
      return a != null && did(() => act('plugin.${a.plugin}.${a.id}', a.label));
    }

    if (shift) return pluginKey();
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) return did(() => inspect(null));
    if (key == LogicalKeyboardKey.keyD) return did(() => inspect(DetailTab.overview));
    if (key == LogicalKeyboardKey.keyY) return did(() => inspect(DetailTab.yaml));
    if (key == LogicalKeyboardKey.keyE) return did(() => inspect(DetailTab.edit));
    if (key == LogicalKeyboardKey.keyL) {
      final sel = tc.selectedRows;
      return did(() => sel.length >= 2 && _canMergeLogs(tc) ? _openSelectedLogs(tc, sel) : act(kLogsActionId, 'logs'));
    }
    if (key == LogicalKeyboardKey.keyS) return did(() => act(kTerminalActionId, 'shell'));
    return pluginKey();
  }

  /// ↑/↓ (or j/k) move the selection (and the inspector); ⇧↑/⇧↓ extend it;
  /// ⌘A selects every visible row; Esc clears a multi-selection, else closes
  /// the inspector; ⌘⌫ / ⌃D delete the selection; plus [_letterKey]s.
  KeyEventResult _onKey(KeyEvent e, List<TableRowData> rows, AppState app) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final tc = context.read<TableController>();
    final keys = HardwareKeyboard.instance;
    final meta = keys.isMetaPressed || keys.isControlPressed;
    final key = e.logicalKey;
    // k9s' ⌃D (literal Control on every platform) deletes, like ⌘⌫.
    final ctrlD = keys.isControlPressed && !keys.isMetaPressed && !keys.isAltPressed && key == LogicalKeyboardKey.keyD;
    if (!meta && !keys.isAltPressed) {
      if (_letterKey(e, rows, app, tc)) return KeyEventResult.handled;
    }
    if (meta && key == LogicalKeyboardKey.keyA) {
      tc.selectAll();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.escape) {
      if (tc.selectedRows.length >= 2) {
        tc.clearSelection();
      } else {
        tc.clearSelection();
        app.closeDetail();
      }
      return KeyEventResult.handled;
    }
    if (ctrlD && e is KeyDownEvent) {
      final sel = tc.selectedRows;
      final i = _currentIndex(tc, app, rows);
      if (sel.length >= 2) {
        final del = bulkActionsFor(app, tc.type, sel).where((a) => a.action == 'delete' && a.label != 'Restart pods').firstOrNull;
        if (del != null) _runBulk(del, sel);
      } else if (i >= 0) {
        _rowAction(tc, app, rows[i], 'delete', 'delete', label: 'Delete');
      }
      return KeyEventResult.handled;
    }
    if (meta && (key == LogicalKeyboardKey.backspace || key == LogicalKeyboardKey.delete)) {
      final sel = tc.selectedRows;
      final del = bulkActionsFor(app, tc.type, sel).where((a) => a.action == 'delete' && a.label != 'Restart pods').firstOrNull;
      if (sel.isNotEmpty && del != null) _runBulk(del, sel);
      return KeyEventResult.handled;
    }
    final down = key == LogicalKeyboardKey.arrowDown;
    final up = key == LogicalKeyboardKey.arrowUp;
    if (!down && !up) return KeyEventResult.ignored;
    if (keys.isShiftPressed) {
      if (tc.cursor == null) {
        final inspected = rows.where((r) => _isInspected(app, tc.type, r)).firstOrNull;
        if (inspected != null) tc.anchor = tc.cursor = inspected.uid;
      }
      tc.extendSelection(down ? 1 : -1);
      final at = rows.indexWhere((r) => r.uid == tc.cursor);
      if (at >= 0) _scrollTo(at);
      return KeyEventResult.handled;
    }
    var idx = tc.cursor == null ? -1 : rows.indexWhere((r) => r.uid == tc.cursor);
    if (idx < 0) idx = rows.indexWhere((r) => _isInspected(app, tc.type, r));
    idx = (idx + (down ? 1 : -1)).clamp(0, rows.length - 1);
    tc.selectOnly(rows[idx].uid);
    _open(app, tc.type, rows[idx]);
    _scrollTo(idx);
    return KeyEventResult.handled;
  }

  static double _baseWidth(ColumnDef c, int index) {
    if (index == 0 && c.query == '.metadata.name') return 280;
    if (c.query == '.metadata.namespace') return 140;
    switch (c.type) {
      case 'age':
      case 'until':
        return 80;
      case 'ratio':
        return 72;
      case 'number':
      case 'quantity':
        return 90;
      case 'percent':
        return 120;
      case 'usage':
        return 160;
      case 'bool':
        return 80;
      case 'status':
        return 150;
      case 'nodeos':
        return 150;
      case 'labels':
        return 260;
    }
    return 160;
  }

  static const _minColumnWidth = 40.0;

  /// Fixed base widths (or the user's, from dragging a divider). An unsized
  /// name column fits its longest name ([nameFit], 180–480px), so it doesn't
  /// change width with the window; the spare space goes to the last other
  /// free-text column (a labels column first). Opening the inspector then
  /// narrows that column instead of sliding every column left.
  static List<double> _columnWidths(List<ColumnDef> cols, double available, Map<String, double> sized, {double? nameFit}) {
    final w = [for (var i = 0; i < cols.length; i++) sized[cols[i].name] ?? _baseWidth(cols[i], i)];
    final fitName = nameFit != null && cols.isNotEmpty && cols[0].query == '.metadata.name' && !sized.containsKey(cols[0].name);
    if (fitName) w[0] = nameFit.clamp(180.0, 480.0);
    final sum = w.fold<double>(0, (a, b) => a + b) + 24;
    final stretchy = [
      for (var i = fitName ? 1 : 0; i < cols.length; i++)
        // Namespaces are short and repetitive: they keep their base width
        // rather than sharing the spare space with names and images.
        if ((cols[i].type == 'string' || cols[i].type == 'labels') && cols[i].query != '.metadata.namespace' && !sized.containsKey(cols[i].name)) i,
    ];
    if (sum < available && stretchy.isNotEmpty) {
      w[stretchy.where((i) => cols[i].type == 'labels').lastOrNull ?? stretchy.last] += available - sum;
    }
    return w;
  }
}

/// Compact buttons for the table toolbar.
const _toolbarButton = ButtonStyle(
  visualDensity: VisualDensity.compact,
  padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
  minimumSize: WidgetStatePropertyAll(Size(0, 28)),
);

class _Toolbar extends StatelessWidget {
  final TableController controller;
  final int shown;

  // What the toolbar shows from the controller (the cache key in _toolbar).
  final int total;
  final bool loaded;
  final bool isDefaultColumns;
  _Toolbar({required this.controller, required this.shown})
      : total = controller.totalCount,
        loaded = controller.loaded,
        isDefaultColumns = controller.isDefaultColumns;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final t = controller.type;
    final session = controller.session;
    final home = app.homePageOf(t);
    final count = shown == controller.totalCount ? '$shown' : '$shown of ${controller.totalCount}';
    return WindowDragArea(
      child: SizedBox(
        height: toolbarRowHeight(context),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 10, 0),
          child: LayoutBuilder(
            builder: (context, box) {
              // Controls get explicit widths (shrinking only when space is
              // tight) and the title takes all remaining slack, so the
              // controls stay pinned right on wide windows.
              // Very narrow (an inspector beside a small window): tighter
              // minimums, and New… moves to ⌘K.
              final tight = box.maxWidth < 520;
              final nsWidth = (box.maxWidth * 0.2).clamp(tight ? 84.0 : 110.0, 190.0);
              final filterWidth = (box.maxWidth * 0.26).clamp(tight ? 76.0 : 104.0, 240.0);
              return Row(
                children: [
                  Expanded(
                    // Right-click the title: pin this kind to the sidebar.
                    // Squeezed below its icon and a few letters (an inspector
                    // beside a small window), it gives way to the controls.
                    child: LayoutBuilder(builder: (context, title) => title.maxWidth < 72 ? const SizedBox.shrink() : GestureDetector(
                      key: const ValueKey('table-title'),
                      behavior: HitTestBehavior.translucent,
                      onSecondaryTapUp: (d) => showKindMenu(context, d.globalPosition, t),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          if (session != null) ...[
                            // On the title's baseline the glyph rides high; drop it
                            // to centre on the capitals (checked at 3x).
                            Transform.translate(offset: const Offset(0, 2.5), child: Icon(Icons.bookmark, size: 16, color: theme.colorScheme.primary)),
                            const SizedBox(width: 6),
                          ] else if (t.custom) ...[GroupIcon(group: t.group, size: 18), const SizedBox(width: 8)],
                          Flexible(
                            child: Tooltip(
                              message: session == null ? '' : 'Saved view · ${t.kind} · ${viewContextLabel(session.view)}',
                              child: Text(session?.view.name ?? (home != null ? pageFor(home)?.label ?? t.kind : t.kind),
                                  key: const ValueKey('table-title-text'), overflow: TextOverflow.ellipsis, maxLines: 1, style: theme.textTheme.titleLarge),
                            ),
                          ),
                          // The kind's home page in its Table mode: switch back to its Overview.
                          if (home != null) ...[
                            const SizedBox(width: 12),
                            Baseline(baseline: 16, baselineType: TextBaseline.alphabetic, child: PageModeSwitch(page: home)),
                          ],
                          if (session != null && session.modified) ...[
                            const SizedBox(width: 5),
                            Tooltip(
                              message: 'Changed since saved',
                              // On the title's baseline row: sit at the text's middle.
                              child: Baseline(
                                baseline: 12,
                                baselineType: TextBaseline.alphabetic,
                                child: Container(
                                  key: const ValueKey('view-modified-dot'),
                                  width: 7,
                                  height: 7,
                                  decoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle),
                                ),
                              ),
                            ),
                          ],
                          // No count until the first list arrives (not "0").
                          if (loaded) ...[
                            const SizedBox(width: 8),
                            Flexible(
                              child: Text(
                                count,
                                maxLines: 1,
                                overflow: TextOverflow.clip,
                                softWrap: false,
                                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontFeatures: const [FontFeature.tabularFigures()]),
                              ),
                            ),
                          ],
                          const SizedBox(width: 8),
                          if (session != null) ...[
                            Flexible(child: Text(t.kind, maxLines: 1, overflow: TextOverflow.clip, softWrap: false, style: theme.textTheme.labelSmall?.copyWith(color: colors.faint, fontWeight: FontWeight.w400))),
                            const SizedBox(width: 6),
                          ],
                          Flexible(
                            child: Text(
                              t.apiVersion,
                              overflow: TextOverflow.ellipsis,
                              maxLines: 1,
                              style: theme.textTheme.labelSmall?.copyWith(color: colors.faint, fontWeight: FontWeight.w400),
                            ),
                          ),
                        ],
                      ),
                    )),
                  ),
                  // A modified view: Update View and Revert as buttons when
                  // there's room, else one menu button (an inspector beside
                  // the table leaves too little for both).
                  if (session != null && session.modified && box.maxWidth >= 720) ...[
                    FilledButton.tonal(
                      key: const ValueKey('view-update'),
                      style: _toolbarButton,
                      onPressed: () => _updateView(context, app),
                      child: const Text('Update View'),
                    ),
                    const SizedBox(width: 6),
                    TextButton(key: const ValueKey('view-revert'), style: _toolbarButton, onPressed: app.revertActiveView, child: const Text('Revert')),
                    const SizedBox(width: 8),
                  ] else if (session != null && session.modified) ...[
                    PopupMenuButton<bool>(
                      key: const ValueKey('view-changes-menu'),
                      popUpAnimationStyle: AnimationStyle.noAnimation,
                      tooltip: 'View changed since saved',
                      padding: EdgeInsets.zero,
                      iconSize: 18,
                      icon: Icon(Icons.save_outlined, color: theme.colorScheme.primary),
                      onSelected: (update) => update ? _updateView(context, app) : app.revertActiveView(),
                      itemBuilder: (_) => const [
                        PopupMenuItem(value: true, child: Text('Update View')),
                        PopupMenuItem(value: false, child: Text('Revert')),
                      ],
                    ),
                    const SizedBox(width: 4),
                  ],
                  if (t.namespaced) ...[SizedBox(width: nsWidth, child: const NamespacePicker()), const SizedBox(width: 8)],
                  SizedBox(
                    width: filterWidth,
                    height: 26,
                    child: TableFilterField(controller: controller),
                  ),
                  const SizedBox(width: 4),
                  if (!app.readOnly && t.can('create') && !tight)
                    IconButton(
                      key: const ValueKey('table-create'),
                      tooltip: 'New ${t.kind}…',
                      icon: const Icon(Icons.add),
                      onPressed: () => openCreateResource(context, kind: t, namespace: app.namespace),
                    ),
                  IconButton(
                    tooltip: session != null
                        ? 'Customise this view\'s columns'
                        : (controller.isDefaultColumns ? 'Customise columns' : 'Customise columns (customised)'),
                    icon: Badge(isLabelVisible: !controller.isDefaultColumns, smallSize: 6, child: const Icon(Icons.view_column_outlined)),
                    onPressed: () async {
                      if (session != null) {
                        // A view's columns are its own (saved with Update view).
                        await showColumnEditor(context,
                            type: t, namespace: app.namespace, columns: controller.columns, onSave: (cols) async => app.viewColumnsChanged(cols));
                        return;
                      }
                      final changed = await showColumnEditor(context, type: t, namespace: app.namespace);
                      if (changed == true) app.columnsChanged();
                    },
                  ),
                  // Narrow toolbars drop it (⌘K → Save Current Table as View).
                  if (box.maxWidth >= 480)
                    IconButton(
                      key: const ValueKey('table-save-view'),
                      tooltip: session != null ? 'Save as new view…' : 'Save view…',
                      icon: const Icon(Icons.bookmark_add_outlined),
                      onPressed: () => showSaveViewDialog(context, controller),
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

Future<void> _updateView(BuildContext context, AppState app) async {
  try {
    await app.updateActiveView();
  } catch (e) {
    if (context.mounted) showActionError(context, 'Could not update the view: $e');
  }
}

class _Header extends StatefulWidget {
  final TableController controller;
  final List<double> widths;

  // What the header shows from the controller (the cache key in _header).
  final List<ColumnDef> columns;
  final int? sortColumn;
  final bool sortAscending;
  final Map<int, String> columnErrors;
  final void Function(int col, double width) onResize;
  final void Function(int col) onFitWidth;
  final VoidCallback onResizeDone;

  /// A header was dragged from column [from] to position [to].
  final void Function(int from, int to) onReorder;
  _Header({
    required this.controller,
    required this.widths,
    required this.onResize,
    required this.onResizeDone,
    required this.onFitWidth,
    required this.onReorder,
  }) : columns = controller.columns,
       sortColumn = controller.sortColumn,
       sortAscending = controller.sortAscending,
       columnErrors = controller.columnErrors;

  @override
  State<_Header> createState() => _HeaderState();
}

class _HeaderState extends State<_Header> {
  static const _lead = 12.0;

  /// The column being dragged, and how far.
  int? _from;
  double _dx = 0;

  TableController get controller => widget.controller;
  List<double> get widths => widget.widths;
  int get _n => math.min(controller.columns.length, widths.length);

  double _start(int i) => _lead + widths.take(i).fold<double>(0, (a, b) => a + b);

  /// Where the dragged column would land (index in the reordered list): it
  /// passes a neighbour once its leading edge (in the direction of travel)
  /// crosses that neighbour's middle, so wide columns move as easily as
  /// narrow ones.
  int _target() {
    final from = _from!;
    final probe = _dx >= 0 ? _start(from) + widths[from] + _dx : _start(from) + _dx;
    var to = 0;
    for (var j = 0; j < _n; j++) {
      if (j != from && _start(j) + widths[j] / 2 < probe) to++;
    }
    return to;
  }

  /// The x of the drop marker for [to] (between the remaining columns).
  double _markerX(int to) {
    final others = [for (var j = 0; j < _n; j++) if (j != _from) j];
    return to < others.length ? _start(others[to]) : _start(others.last) + widths[others.last];
  }

  void _end() {
    final from = _from;
    if (from == null) return;
    final to = _target();
    setState(() {
      _from = null;
      _dx = 0;
    });
    if (to != from) widget.onReorder(from, to);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(color: theme.hintColor);
    final from = _from;
    // Divider handles sit over each column's right edge.
    final edges = [for (var i = 0; i < _n; i++) _start(i) + widths[i]];
    final to = from == null ? null : _target();
    return SizedBox(
      height: 28,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(child: _headerRow(theme, style)),
          if (from == null)
            for (final (i, x) in edges.indexed)
              Positioned(
                left: x - _ResizeHandle.width / 2,
                top: 0,
                bottom: 0,
                width: _ResizeHandle.width,
                child: _ResizeHandle(
                  key: ValueKey('resize-${controller.columns[i].name}'),
                  startWidth: () => widths[i],
                  onResize: (w) => widget.onResize(i, w),
                  onResizeDone: widget.onResizeDone,
                  onReset: () => widget.onFitWidth(i),
                ),
              ),
          if (from != null && to != null && to != from)
            Positioned(
              left: _markerX(to) - 1,
              top: 3,
              bottom: 3,
              width: 2,
              child: ColoredBox(color: theme.colorScheme.primary),
            ),
          if (from != null)
            Positioned(
              left: _start(from) + _dx,
              top: 0,
              bottom: 0,
              width: widths[from],
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(5),
                    boxShadow: const [BoxShadow(blurRadius: 6, color: Color(0x33000000), offset: Offset(0, 1))],
                  ),
                  child: _cell(theme, style, from, hovered: true),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _headerRow(ThemeData theme, TextStyle? style) {
    return Row(
      children: [
        const SizedBox(width: _lead),
        for (var i = 0; i < _n; i++)
          SizedBox(
            width: widths[i],
            // Drag a header sideways to move the column; click to sort.
            child: GestureDetector(
              key: ValueKey('header-${controller.columns[i].name}'),
              dragStartBehavior: DragStartBehavior.down,
              onHorizontalDragStart: (_) => setState(() {
                _from = i;
                _dx = 0;
              }),
              onHorizontalDragUpdate: (d) => setState(() {
                final total = _start(_n) - _lead;
                _dx = (_dx + d.delta.dx).clamp(_lead - _start(i), total - (_start(i) - _lead) - widths[i]);
              }),
              onHorizontalDragEnd: (_) => _end(),
              onHorizontalDragCancel: () => setState(() {
                _from = null;
                _dx = 0;
              }),
              child: Opacity(
                opacity: _from == i ? 0.25 : 1,
                child: Hoverable(
                  cursor: SystemMouseCursors.basic,
                  onTap: () => controller.sortBy(i),
                  builder: (h) => _cell(theme, style, i, hovered: h),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _cell(ThemeData theme, TextStyle? style, int i, {required bool hovered}) {
    final c = controller.columns[i];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        mainAxisAlignment: const {'number', 'quantity', 'usage', 'ratio'}.contains(c.type) ? MainAxisAlignment.end : MainAxisAlignment.start,
        children: [
          Flexible(child: () {
            final name = Text(
              c.name,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(
                color: hovered || controller.sortColumn == i ? theme.colorScheme.onSurface : null,
                fontWeight: controller.sortColumn == i ? FontWeight.w600 : null,
              ),
            );
            // Plugin columns: their description and plugin.
            return c.plugin == null ? name : Tooltip(message: [?c.description, '${c.plugin} plugin'].join('\n'), child: name);
          }()),
          if (controller.sortColumn == i) ...[
            const SizedBox(width: 2),
            Icon(controller.sortAscending ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 14, color: theme.hintColor),
          ],
          if (controller.columnErrors[i] != null)
            Tooltip(
              message: c.plugin != null ? '${c.plugin} plugin: ${controller.columnErrors[i]}' : 'jq error: ${controller.columnErrors[i]}\n${c.query}',
              child: Icon(Icons.warning_amber, size: 14, color: theme.colorScheme.error),
            ),
        ],
      ),
    );
  }
}

/// A column divider in the header: drag to resize, double-click to fit the content
/// (again to reset).
class _ResizeHandle extends StatefulWidget {
  static const width = 9.0;
  final double Function() startWidth;
  final ValueChanged<double> onResize;
  final VoidCallback onResizeDone;
  final VoidCallback onReset;
  const _ResizeHandle({super.key, required this.startWidth, required this.onResize, required this.onResizeDone, required this.onReset});

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  double _start = 0, _dx = 0;
  bool _hover = false, _dragging = false;

  @override
  Widget build(BuildContext context) {
    final on = _hover || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        // Count from pointer-down so the divider tracks the cursor exactly.
        dragStartBehavior: DragStartBehavior.down,
        onHorizontalDragStart: (_) => setState(() {
          _start = widget.startWidth();
          _dx = 0;
          _dragging = true;
        }),
        onHorizontalDragUpdate: (d) {
          _dx += d.delta.dx;
          widget.onResize(_start + _dx);
        },
        onHorizontalDragEnd: (_) {
          setState(() => _dragging = false);
          widget.onResizeDone();
        },
        onHorizontalDragCancel: () {
          setState(() => _dragging = false);
          widget.onResizeDone();
        },
        onDoubleTap: widget.onReset,
        child: Center(
          child: Container(width: on ? 2 : 1, height: on ? 20 : 12, color: on ? Theme.of(context).colorScheme.primary : Theme.of(context).dividerColor),
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  /// The column under [x] (row-local), past the row's margin and inset.
  int? _columnAt(double x) {
    var left = 6.0 + (selected && inspected ? 3 : 6);
    for (var i = 0; i < widths.length; i++) {
      if (x >= left && x < left + widths[i]) return i;
      left += widths[i];
    }
    return null;
  }

  final TableRowData row;
  final List<ColumnDef> columns;
  final List<double> widths;
  final bool striped;

  /// Shown in the inspector.
  final bool inspected;

  /// Part of a multi-selection (2+ rows).
  final bool selected;

  /// Neighbouring rows are selected too: the highlight runs on unbroken.
  final bool joinAbove;
  final bool joinBelow;
  final VoidCallback onTap;

  /// Right-click (or two-finger click) at a global position, over column
  /// [col] (null between columns).
  final void Function(Offset global, int? col)? onContextMenu;
  const _Row({
    super.key,
    required this.row,
    required this.columns,
    required this.widths,
    required this.striped,
    required this.inspected,
    required this.onTap,
    this.selected = false,
    this.joinAbove = false,
    this.joinBelow = false,
    this.onContextMenu,
  });

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    const r = Radius.circular(5);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onSecondaryTapDown: onContextMenu == null ? null : (d) => onContextMenu!(d.globalPosition, _columnAt(d.localPosition.dx)),
      child: Hoverable(
        cursor: SystemMouseCursors.basic,
        onTap: onTap,
        builder: (hovered) => Container(
          margin: const EdgeInsets.symmetric(horizontal: 6),
          // The inspected-row edge (3 px) replaces part of the inset.
          padding: EdgeInsets.only(left: selected && inspected ? 3 : 6),
          decoration: BoxDecoration(
            // macOS multi-selection: every selected row tinted with the
            // accent, contiguous rows joined into one block. The inspected
            // row alone keeps the lighter source-list tint.
            color: selected
                ? theme.colorScheme.primary.withValues(alpha: dark ? 0.42 : 0.26)
                : inspected
                ? colors.selection
                : hovered
                ? colors.hover
                : striped
                ? colors.stripe
                : null,
            borderRadius: selected ? BorderRadius.vertical(top: joinAbove ? Radius.zero : r, bottom: joinBelow ? Radius.zero : r) : const BorderRadius.all(r),
            // Inside a multi-selection, the inspected row gets an inset edge.
            border: selected && inspected ? Border(left: BorderSide(color: theme.colorScheme.primary, width: 3)) : null,
          ),
          child: Row(
            children: [
              for (var i = 0; i < columns.length; i++)
                SizedBox(
                  width: widths[i],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: TableCellView(
                      value: i < row.cells.length ? row.cells[i] : null,
                      column: columns[i],
                      emphasise: i == 0,
                      notReady: columns[i].type == 'status' ? _notReady(columns, row) : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Over rows that are still shown after a refresh failed.
class _StaleBanner extends StatelessWidget {
  final TableController controller;
  const _StaleBanner({required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = controller.failure;
    final what = switch (f?.kind) {
      ClusterErrorKind.backendDown => "The k8sman backend isn't responding",
      ClusterErrorKind.unreachable || ClusterErrorKind.timeout => "Can't reach the cluster",
      ClusterErrorKind.unauthorized => 'Credentials rejected or expired',
      ClusterErrorKind.forbidden => 'Permission denied',
      _ => "Can't refresh",
    };
    return Container(
      key: const ValueKey('stale-banner'),
      color: severityColor(context, Severity.warn).withValues(alpha: 0.12),
      padding: const EdgeInsets.fromLTRB(14, 4, 8, 4),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 15, color: severityColor(context, Severity.warn)),
          const SizedBox(width: 8),
          Expanded(
            child: Tooltip(
              message: controller.error ?? '',
              child: Text(
                '$what. Showing the last loaded data. ${controller.error ?? ''}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall,
              ),
            ),
          ),
          TextButton(
            style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
            onPressed: controller.retry,
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

/// "N selected · Clear" and the actions that apply to all selected rows.
class _SelectionBar extends StatelessWidget {
  final TableController controller;
  final List<TableRowData> rows;
  final List<BulkAction> actions;
  final ValueNotifier<BulkProgress?> progress;
  final void Function(BulkAction) onRun;
  const _SelectionBar({required this.controller, required this.rows, required this.actions, required this.progress, required this.onRun});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Container(
      key: const ValueKey('selection-bar'),
      height: 32,
      color: theme.colorScheme.primary.withValues(alpha: 0.06),
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
      child: LayoutBuilder(
        builder: (context, box) => ValueListenableBuilder<BulkProgress?>(
          valueListenable: progress,
          builder: (context, p, _) {
            // Narrow: icon-only actions (labels in tooltips).
            final compact = box.maxWidth < 300 + 110 * actions.length;
            return Row(
              children: [
                Text(
                  '${rows.length} selected',
                  maxLines: 1,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, fontFeatures: const [FontFeature.tabularFigures()]),
                ),
                Text('  ·  ', style: hint),
                Hoverable(
                  key: const ValueKey('selection-clear'),
                  onTap: controller.clearSelection,
                  builder: (h) => Text(
                    'Clear',
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.primary, decoration: h ? TextDecoration.underline : null),
                  ),
                ),
                const SizedBox(width: 12),
                if (p != null) ...[
                  const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text('$p', maxLines: 1, overflow: TextOverflow.ellipsis, style: hint),
                  ),
                ],
                const Spacer(),
                for (final a in actions)
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: compact
                        ? IconButton(
                            key: ValueKey('bulk-${a.label}'),
                            tooltip: a.label,
                            iconSize: 16,
                            visualDensity: VisualDensity.compact,
                            color: a.destructive ? theme.colorScheme.error : null,
                            onPressed: p != null ? null : () => onRun(a),
                            icon: Icon(a.icon),
                          )
                        : TextButton.icon(
                            key: ValueKey('bulk-${a.label}'),
                            style: TextButton.styleFrom(
                              visualDensity: VisualDensity.compact,
                              padding: const EdgeInsets.symmetric(horizontal: 8),
                              foregroundColor: a.destructive ? theme.colorScheme.error : null,
                              splashFactory: NoSplash.splashFactory,
                            ),
                            onPressed: p != null ? null : () => onRun(a),
                            icon: Icon(a.icon, size: 15),
                            label: Text(a.label),
                          ),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Renders one cell according to its column's type hint.
/// "x/y" from the row's Ready column when fewer than all are ready (pods:
/// containers), else null. Lets a Running status show amber, like k9s.
(int, int)? _notReady(List<ColumnDef> columns, TableRowData row) {
  final i = columns.indexWhere((c) => c.name == 'Ready');
  if (i < 0 || i >= row.cells.length) return null;
  final m = RegExp(r'^(\d+)/(\d+)$').firstMatch('${row.cells[i]}');
  if (m == null) return null;
  final ready = int.parse(m[1]!), total = int.parse(m[2]!);
  return ready < total ? (ready, total) : null;
}

class TableCellView extends StatelessWidget {
  final dynamic value;
  final ColumnDef column;
  final bool emphasise;

  /// For a status cell: (ready, total) when not everything in the row is
  /// ready. A Running status then shows amber with a tooltip.
  final (int, int)? notReady;
  const TableCellView({super.key, required this.value, required this.column, this.emphasise = false, this.notReady});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium?.copyWith(fontSize: 12.5, fontWeight: emphasise ? FontWeight.w500 : null);
    final v = value;
    if (column.type == 'quantity') return quantityCell(context, v, base);
    if (column.type == 'percent') return percentCell(context, v, base);
    if (column.type == 'usage') return UsageCell(value: v, style: base);
    if (v == null) return const SizedBox.shrink();
    switch (column.type) {
      case 'age':
        final t = parseTime(v);
        return Tooltip(
          message: t?.toLocal().toString() ?? '$v',
          child: Text(
            t != null ? formatAge(t) : '$v',
            style: base?.copyWith(color: theme.hintColor, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        );
      case 'until':
        // A future time as time left; red once it has passed.
        final t = parseTime(v);
        final passed = t != null && t.isBefore(DateTime.now());
        return Tooltip(
          message: t?.toLocal().toString() ?? '$v',
          child: Text(
            t != null ? formatUntil(t) : '$v',
            style: base?.copyWith(color: passed ? severityColor(context, Severity.error) : null, fontFeatures: const [FontFeature.tabularFigures()]),
          ),
        );
      case 'status':
        final s = _text(v);
        if (s.isEmpty) return const SizedBox.shrink();
        final nr = notReady;
        if (nr != null && s == 'Running') {
          return Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(
              message: 'Running, but ${nr.$1} of ${nr.$2} ready',
              child: const StatusBadge('Running', severity: Severity.warn, dense: true),
            ),
          );
        }
        return Align(alignment: Alignment.centerLeft, child: StatusBadge(s, dense: true));
      case 'bool':
        final b = v == true || '$v'.toLowerCase() == 'true';
        return Align(
          alignment: Alignment.centerLeft,
          child: Icon(b ? Icons.check_circle : Icons.remove, size: 14, color: b ? severityColor(context, Severity.ok) : theme.hintColor),
        );
      case 'number':
        return Text(
          _text(v),
          textAlign: TextAlign.right,
          style: base?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
        );
      case 'ratio':
        // Neutral: a completed pod's 0/1 is fine, and Status carries health.
        return Text(_text(v), textAlign: TextAlign.right, maxLines: 1, style: base?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]));
      case 'nodeos':
        // Icon and short name; the OS image, platform and runtime in the tooltip.
        final os = nodeOsOf(nodeFromOsCell(_text(v)));
        if (os == null) return const SizedBox.shrink();
        return Tooltip(
          message: os.tooltip,
          child: Row(children: [
            NodeOsGlyph(os.mark),
            const SizedBox(width: 6),
            Flexible(child: Text(os.label, overflow: TextOverflow.ellipsis, maxLines: 1, style: base)),
          ]),
        );
      case 'labels':
        if (v is Map) {
          return Text(v.entries.map((e) => '${e.key}=${e.value}').join('  '), overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11));
        }
    }
    final s = _text(v);
    final text = Text(s, overflow: TextOverflow.ellipsis, maxLines: 1, style: base);
    // Only long values get a tooltip (an empty-message Tooltip renders just
    // its child, but still costs a stateful element per cell).
    return s.length > 40 ? Tooltip(message: s, child: text) : text;
  }

  static String _text(dynamic v) {
    if (v == null) return '';
    if (v is List) return v.map(_text).join(', ');
    if (v is Map) return jsonEncode(v);
    return '$v';
  }
}

/// Empty table: when the list is empty only because of the namespace scope,
/// offer a one-click switch to all namespaces.
class _EmptyTable extends StatelessWidget {
  final TableController controller;
  const _EmptyTable({required this.controller});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final tc = controller;
    final hint = TextStyle(color: theme.hintColor);
    if (tc.filter.isNotEmpty) return Center(child: Text('No matches', style: hint));
    final scope = app.namespaceScope;
    final scoped = tc.type.namespaced && !scope.isAll;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(scoped ? 'No ${tc.type.resource} in ${scope.namespaces.join(', ')}' : 'No ${tc.type.resource}', style: hint),
          if (scoped) ...[
            const SizedBox(height: 10),
            FilledButton.tonalIcon(icon: const Icon(Icons.public, size: 15), label: const Text('Show all namespaces'), onPressed: () => app.setNamespace(null)),
          ],
        ],
      ),
    );
  }
}

/// A 0–100 value as a small bar plus the number (PVC "Used"): amber from 80,
/// red from 90. Empty (no stats) shows a faint "—".
Widget percentCell(BuildContext context, dynamic v, TextStyle? base) {
  final theme = Theme.of(context);
  final p = v is num ? v.toDouble() : double.tryParse('$v'.replaceAll('%', ''));
  if (p == null) {
    return Align(alignment: Alignment.centerRight, child: Text('—', style: base?.copyWith(color: AppColors.of(context).faint)));
  }
  final sev = thresholdSeverity(p / 100, warn: 0.8);
  final color = sev == Severity.neutral ? theme.colorScheme.primary : severityColor(context, sev);
  final label = p >= 10 || p == 0 ? '${p.round()}%' : '${p.toStringAsFixed(1)}%';
  return Row(children: [
    Expanded(
      child: HairlineBar(frac: p / 100, color: color, height: 4, radius: 2, track: AppColors.of(context).separator),
    ),
    SizedBox(
      width: 40,
      child: Text(
        label,
        textAlign: TextAlign.right,
        style: base?.copyWith(
          color: sev == Severity.neutral ? null : color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    ),
  ]);
}
