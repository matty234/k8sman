import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../app/window_chrome.dart';
import '../state/app_state.dart';
import '../state/table_controller.dart';
import '../util/k8s.dart';
import 'column_editor.dart';
import 'theme.dart';
import 'widgets/common.dart';

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
    _ageTicker = Timer.periodic(const Duration(seconds: 30), (_) => mounted ? setState(() {}) : null);
  }

  @override
  void dispose() {
    _ageTicker?.cancel();
    _hScroll.dispose();
    _vScroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tc = context.watch<TableController>();
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final rows = tc.rows;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(controller: tc, shown: rows.length),
        if (tc.error != null)
          Container(
            color: theme.colorScheme.errorContainer.withValues(alpha: 0.4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: InlineMessage(tc.error!, isError: true),
          ),
        const Divider(),
        Expanded(
          child: tc.loading
              ? const Center(child: CircularProgressIndicator())
              : LayoutBuilder(
                  builder: (context, box) {
                    final widths = _columnWidths(tc.columns, box.maxWidth);
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
                              _Header(controller: tc, widths: widths),
                              const Divider(),
                              Expanded(
                                child: rows.isEmpty
                                    ? Center(
                                        child: Text(tc.filter.isEmpty ? 'No ${tc.type.resource}' : 'No matches', style: TextStyle(color: theme.hintColor)),
                                      )
                                    : Focus(
                                        focusNode: _focus,
                                        onKeyEvent: (node, e) => _onKey(e, rows, app),
                                        child: Scrollbar(
                                          controller: _vScroll,
                                          child: ListView.builder(
                                            controller: _vScroll,
                                            padding: const EdgeInsets.only(top: 4, bottom: 8),
                                            itemExtent: _rowHeight,
                                            itemCount: rows.length,
                                            itemBuilder: (context, i) => _Row(
                                              row: rows[i],
                                              columns: tc.columns,
                                              widths: widths,
                                              striped: i.isOdd,
                                              selected:
                                                  app.detail?.name == rows[i].name &&
                                                  app.detail?.namespace == (tc.type.namespaced ? rows[i].namespace : null) &&
                                                  app.detail?.type == tc.type,
                                              onTap: () {
                                                _focus.requestFocus();
                                                _open(app, tc.type, rows[i]);
                                              },
                                            ),
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

  void _open(AppState app, ResourceType type, TableRowData row) =>
      app.openDetail(DetailTarget(type: type, name: row.name, namespace: type.namespaced ? row.namespace : null));

  /// ↑/↓ move the selection, Esc closes the sidebar.
  KeyEventResult _onKey(KeyEvent e, List<TableRowData> rows, AppState app) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final tc = context.read<TableController>();
    if (e.logicalKey == LogicalKeyboardKey.escape) {
      app.closeDetail();
      return KeyEventResult.handled;
    }
    final down = e.logicalKey == LogicalKeyboardKey.arrowDown;
    final up = e.logicalKey == LogicalKeyboardKey.arrowUp;
    if (!down && !up) return KeyEventResult.ignored;
    var idx = rows.indexWhere((r) => r.name == app.detail?.name && (r.namespace ?? '') == (app.detail?.namespace ?? r.namespace ?? ''));
    idx = (idx + (down ? 1 : -1)).clamp(0, rows.length - 1);
    _open(app, tc.type, rows[idx]);
    final y = idx * _rowHeight;
    if (y < _vScroll.offset || y > _vScroll.offset + _vScroll.position.viewportDimension - _rowHeight) {
      _vScroll.jumpTo((y - _vScroll.position.viewportDimension / 2).clamp(0, _vScroll.position.maxScrollExtent));
    }
    return KeyEventResult.handled;
  }

  static double _baseWidth(ColumnDef c, int index) {
    if (index == 0 && c.query == '.metadata.name') return 280;
    if (c.query == '.metadata.namespace') return 140;
    switch (c.type) {
      case 'age':
        return 80;
      case 'number':
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
  const _Toolbar({required this.controller, required this.shown});

  static const _allNamespaces = '\u0000all';

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final t = controller.type;
    final count = shown == controller.totalCount ? '$shown' : '$shown of ${controller.totalCount}';
    final ns = app.namespaces.contains(app.namespace) ? app.namespace : null;
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
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.baseline,
                      textBaseline: TextBaseline.alphabetic,
                      children: [
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
                  if (t.namespaced) ...[
                    SizedBox(
                      width: nsWidth,
                      child: MenuButton<String>(
                        tooltip: 'Namespace',
                        onSelected: (v) => app.setNamespace(v == _allNamespaces ? null : v),
                        items: () => [
                          _nsItem(context, _allNamespaces, 'All namespaces', ns == null),
                          const PopupMenuDivider(height: 9),
                          for (final n in app.namespaces) _nsItem(context, n, n, n == ns),
                        ],
                        builder: (h) => Container(
                          height: 26,
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          decoration: BoxDecoration(
                            color: theme.inputDecorationTheme.fillColor?.withValues(alpha: h ? 0.14 : null),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.folder_outlined, size: 14, color: theme.hintColor),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(ns ?? 'All namespaces', overflow: TextOverflow.ellipsis, maxLines: 1, style: theme.textTheme.bodyMedium),
                              ),
                              Icon(Icons.unfold_more, size: 14, color: theme.hintColor),
                            ],
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
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

  static PopupMenuItem<String> _nsItem(BuildContext context, String value, String label, bool selected) => PopupMenuItem(
    value: value,
    height: 26,
    child: Row(
      children: [
        SizedBox(width: 18, child: selected ? Icon(Icons.check, size: 14, color: Theme.of(context).colorScheme.primary) : null),
        Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
      ],
    ),
  );
}

class _Header extends StatelessWidget {
  final TableController controller;
  final List<double> widths;
  const _Header({required this.controller, required this.widths});

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
                    mainAxisAlignment: controller.columns[i].type == 'number' ? MainAxisAlignment.end : MainAxisAlignment.start,
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
  final bool selected;
  final VoidCallback onTap;
  const _Row({required this.row, required this.columns, required this.widths, required this.striped, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return Hoverable(
      cursor: SystemMouseCursors.basic,
      onTap: onTap,
      builder: (hovered) => Container(
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.only(left: 6),
        decoration: BoxDecoration(
          color: selected
              ? colors.selection
              : hovered
              ? colors.hover
              : striped
              ? colors.stripe
              : null,
          borderRadius: BorderRadius.circular(5),
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
    return Tooltip(
      message: s.length > 40 ? s : '',
      child: Text(s, overflow: TextOverflow.ellipsis, maxLines: 1, style: base),
    );
  }

  static String _text(dynamic v) {
    if (v == null) return '';
    if (v is List) return v.map(_text).join(', ');
    if (v is Map) return jsonEncode(v);
    return '$v';
  }
}
