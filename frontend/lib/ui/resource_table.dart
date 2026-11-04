import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../actions/bulk.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../app/window_chrome.dart';
import '../metrics/quantity_cell.dart';
import '../state/app_state.dart';
import '../state/cluster_error.dart';
import '../state/table_controller.dart';
import '../util/k8s.dart';
import 'cluster_error_view.dart';
import 'column_editor.dart';
import 'resource_nav.dart' show showKindMenu;
import 'row_context_menu.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/group_icon.dart';
import 'widgets/namespace_picker.dart';

/// Live table for the selected resource type. Re-created (via key) whenever
/// the type, namespace or column config changes.
class ResourceTableView extends StatelessWidget {
  final ResourceType type;
  const ResourceTableView({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    return ChangeNotifierProvider<TableController>(
      key: ValueKey('${type.gk}|${app.namespace}|${app.columnsVersion}|${app.currentContext}'),
      create: (_) => TableController(api: context.read<ApiClient>(), type: type, namespace: app.namespace),
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
  final _focus = FocusNode();
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
    _focus.dispose();
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _toolbar(tc, rows.length),
        if (tc.error != null && !failedEmpty) _StaleBanner(controller: tc),
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
                  namespace: tc.type.namespaced ? tc.namespace : null,
                  namespaced: tc.type.namespaced,
                  onRetry: tc.retry,
                  onRediscover: app.refreshTypes,
                )
              : LayoutBuilder(
                  builder: (context, box) {
                    final widths = _stableWidths(_columnWidths(tc.columns, box.maxWidth));
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

  // Toolbar and header, reused while what they show is unchanged (a watch
  // event usually changes neither). They still rebuild on their own
  // inherited dependencies (theme, AppState).
  _Toolbar? _toolbarCache;
  _Toolbar _toolbar(TableController tc, int shown) {
    final t = _toolbarCache;
    if (t != null && t.shown == shown && t.total == tc.totalCount && t.isDefaultColumns == tc.isDefaultColumns) return t;
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
    return _headerCache = _Header(controller: tc, widths: widths);
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
      onContextMenu: (pos) {
        final selectedRows = tc.selectedRows;
        selectedRows.length >= 2 && tc.isSelected(row.uid)
            ? _showBulkMenu(context, pos, tc, app, selectedRows)
            : showRowContextMenu(context, pos, tc.type, row);
      },
    );
  }

  static bool _isInspected(AppState app, ResourceType type, TableRowData row) =>
      app.detail?.type == type && app.detail?.name == row.name && app.detail?.namespace == (type.namespaced ? row.namespace : null);

  void _open(AppState app, ResourceType type, TableRowData row) =>
      app.openDetail(DetailTarget(type: type, name: row.name, namespace: type.namespaced ? row.namespace : null));

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
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    final local = overlay.globalToLocal(globalPosition);
    final theme = Theme.of(context);
    final actions = bulkActionsFor(app, tc.type, rows);
    PopupMenuItem<VoidCallback> item(IconData icon, String label, VoidCallback run, {bool danger = false}) {
      final color = danger ? theme.colorScheme.error : null;
      return PopupMenuItem<VoidCallback>(
        value: run,
        height: 30,
        child: Row(
          children: [
            Icon(icon, size: 15, color: color ?? theme.hintColor),
            const SizedBox(width: 10),
            Expanded(
              child: Text(label, style: theme.textTheme.bodyMedium?.copyWith(color: color)),
            ),
          ],
        ),
      );
    }

    final names = rows.map((r) => tc.type.namespaced && r.namespace != null ? '${r.namespace}/${r.name}' : r.name).join('\n');
    final safe = actions.where((a) => !a.destructive);
    final destructive = actions.where((a) => a.destructive);
    final chosen = await showMenu<VoidCallback>(
      context: context,
      popUpAnimationStyle: AnimationStyle.noAnimation,
      position: RelativeRect.fromRect(Rect.fromPoints(local, local), Offset.zero & overlay.size),
      constraints: const BoxConstraints(minWidth: 220, maxWidth: 320),
      items: [
        PopupMenuItem<VoidCallback>(
          enabled: false,
          height: 26,
          child: Text('${rows.length} ${tc.type.resource} selected', style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor)),
        ),
        for (final a in safe) item(a.icon, '${a.verb} ${rows.length} ${tc.type.resource}', () => _runBulk(a, rows)),
        const PopupMenuDivider(height: 9),
        item(Icons.content_copy, 'Copy names', () => copyToClipboard(context, names, label: '${rows.length} names')),
        item(Icons.deselect, 'Clear selection', tc.clearSelection),
        if (destructive.isNotEmpty) const PopupMenuDivider(height: 9),
        for (final a in destructive) item(a.icon, '${a.verb} ${rows.length} ${tc.type.resource}…', () => _runBulk(a, rows), danger: true),
      ],
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

  /// ↑/↓ move the selection (and the inspector); ⇧↑/⇧↓ extend it; ⌘A
  /// selects every visible row; Esc clears a multi-selection, else closes
  /// the inspector; ⌘⌫ deletes the selection.
  KeyEventResult _onKey(KeyEvent e, List<TableRowData> rows, AppState app) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final tc = context.read<TableController>();
    final keys = HardwareKeyboard.instance;
    final meta = keys.isMetaPressed || keys.isControlPressed;
    final key = e.logicalKey;
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
        return 80;
      case 'number':
      case 'quantity':
        return 90;
      case 'bool':
        return 80;
      case 'status':
        return 150;
      case 'labels':
        return 260;
    }
    return 160;
  }

  /// Fixed base widths; spare space goes to free-text columns.
  static List<double> _columnWidths(List<ColumnDef> cols, double available) {
    final w = [for (var i = 0; i < cols.length; i++) _baseWidth(cols[i], i)];
    final sum = w.fold<double>(0, (a, b) => a + b) + 24;
    final stretchy = [
      for (var i = 0; i < cols.length; i++)
        if (cols[i].type == 'string' || cols[i].type == 'labels') i,
    ];
    if (sum < available && stretchy.isNotEmpty) {
      final extra = (available - sum) / stretchy.length;
      for (final i in stretchy) {
        w[i] += extra;
      }
    }
    return w;
  }
}

class _Toolbar extends StatelessWidget {
  final TableController controller;
  final int shown;

  // What the toolbar shows from the controller (the cache key in _toolbar).
  final int total;
  final bool isDefaultColumns;
  _Toolbar({required this.controller, required this.shown}) : total = controller.totalCount, isDefaultColumns = controller.isDefaultColumns;

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final t = controller.type;
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
              final nsWidth = (box.maxWidth * 0.2).clamp(110.0, 190.0);
              final filterWidth = (box.maxWidth * 0.26).clamp(120.0, 240.0);
              return Row(
                children: [
                  Expanded(
                    // Right-click the title: pin this kind to the sidebar.
                    child: GestureDetector(
                    key: const ValueKey('table-title'),
                    behavior: HitTestBehavior.translucent,
                    onSecondaryTapUp: (d) => showKindMenu(context, d.globalPosition, t),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
                        if (t.custom) ...[GroupIcon(group: t.group, size: 18), const SizedBox(width: 8)],
                        Flexible(
                          child: Text(t.kind, overflow: TextOverflow.ellipsis, maxLines: 1, style: theme.textTheme.titleLarge),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          count,
                          maxLines: 1,
                          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontFeatures: const [FontFeature.tabularFigures()]),
                        ),
                        const SizedBox(width: 8),
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
                    ),
                  ),
                  if (t.namespaced) ...[SizedBox(width: nsWidth, child: const NamespacePicker()), const SizedBox(width: 8)],
                  SizedBox(
                    width: filterWidth,
                    height: 26,
                    child: TextField(
                      decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 15), hintText: 'Filter  (or column=value)'),
                      style: theme.textTheme.bodyMedium,
                      onChanged: controller.setFilter,
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    tooltip: controller.isDefaultColumns ? 'Customise columns' : 'Customise columns (customised)',
                    icon: Badge(isLabelVisible: !controller.isDefaultColumns, smallSize: 6, child: const Icon(Icons.view_column_outlined)),
                    onPressed: () async {
                      final changed = await showColumnEditor(context, type: t, namespace: app.namespace);
                      if (changed == true) app.columnsChanged();
                    },
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

class _Header extends StatelessWidget {
  final TableController controller;
  final List<double> widths;

  // What the header shows from the controller (the cache key in _header).
  final List<ColumnDef> columns;
  final int? sortColumn;
  final bool sortAscending;
  final Map<int, String> columnErrors;
  _Header({required this.controller, required this.widths})
      : columns = controller.columns,
        sortColumn = controller.sortColumn,
        sortAscending = controller.sortAscending,
        columnErrors = controller.columnErrors;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(color: theme.hintColor);
    return SizedBox(
      height: 28,
      child: Row(
        children: [
          const SizedBox(width: 12),
          for (var i = 0; i < controller.columns.length; i++)
            SizedBox(
              width: widths[i],
              child: Hoverable(
                cursor: SystemMouseCursors.basic,
                onTap: () => controller.sortBy(i),
                builder: (h) => Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  child: Row(
                    mainAxisAlignment: const {'number', 'quantity'}.contains(controller.columns[i].type) ? MainAxisAlignment.end : MainAxisAlignment.start,
                    children: [
                      Flexible(
                        child: Text(
                          controller.columns[i].name,
                          overflow: TextOverflow.ellipsis,
                          style: style?.copyWith(
                            color: h || controller.sortColumn == i ? theme.colorScheme.onSurface : null,
                            fontWeight: controller.sortColumn == i ? FontWeight.w600 : null,
                          ),
                        ),
                      ),
                      if (controller.sortColumn == i) ...[
                        const SizedBox(width: 2),
                        Icon(controller.sortAscending ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 14, color: theme.hintColor),
                      ],
                      if (controller.columnErrors[i] != null)
                        Tooltip(
                          message: 'jq error: ${controller.columnErrors[i]}\n${controller.columns[i].query}',
                          child: Icon(Icons.warning_amber, size: 14, color: theme.colorScheme.error),
                        ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
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

  /// Right-click (or two-finger click) at a global position.
  final ValueChanged<Offset>? onContextMenu;
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
      onSecondaryTapDown: onContextMenu == null ? null : (d) => onContextMenu!(d.globalPosition),
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
                    child: TableCellView(value: i < row.cells.length ? row.cells[i] : null, column: columns[i], emphasise: i == 0),
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
class TableCellView extends StatelessWidget {
  final dynamic value;
  final ColumnDef column;
  final bool emphasise;
  const TableCellView({super.key, required this.value, required this.column, this.emphasise = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium?.copyWith(fontSize: 12.5, fontWeight: emphasise ? FontWeight.w500 : null);
    final v = value;
    if (column.type == 'quantity') return quantityCell(context, v, base);
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
      case 'status':
        final s = _text(v);
        if (s.isEmpty) return const SizedBox.shrink();
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
    final ns = app.namespace;
    final scoped = tc.type.namespaced && ns != null;
    return Center(
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(scoped ? 'No ${tc.type.resource} in $ns' : 'No ${tc.type.resource}', style: hint),
        if (scoped) ...[
          const SizedBox(height: 10),
          FilledButton.tonalIcon(
            icon: const Icon(Icons.public, size: 15),
            label: const Text('Show all namespaces'),
            onPressed: () => app.setNamespace(null),
          ),
        ],
      ]),
    );
  }
}
