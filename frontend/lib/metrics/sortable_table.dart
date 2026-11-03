import 'package:flutter/material.dart';

import '../ui/theme.dart';
import '../ui/widgets/common.dart';

/// A column of [SortableTable].
class MetricColumn<T> {
  final String label;

  /// Fixed width; null = flexible (takes the remaining space).
  final double? width;
  final bool numeric;

  /// Hidden when the table is narrower than this (lower-priority columns).
  final double hideBelow;
  final Comparable<Object>? Function(T row)? sortKey;
  final Widget Function(BuildContext context, T row) cell;
  final String? tooltip;

  const MetricColumn({required this.label, this.width, this.numeric = false, this.hideBelow = 0, this.sortKey, required this.cell, this.tooltip});
}

/// A compact, sortable, responsive table (columns drop by priority as the
/// width shrinks). Rows are clickable.
class SortableTable<T> extends StatefulWidget {
  final List<MetricColumn<T>> columns;
  final List<T> rows;
  final int initialSort;
  final bool initialAscending;
  final void Function(T row)? onTap;
  final bool Function(T row)? selected;

  /// Rows shown before "Show all".
  final int limit;
  const SortableTable({
    super.key,
    required this.columns,
    required this.rows,
    this.initialSort = 0,
    this.initialAscending = true,
    this.onTap,
    this.selected,
    this.limit = 1 << 30,
  });

  @override
  State<SortableTable<T>> createState() => _SortableTableState<T>();
}

class _SortableTableState<T> extends State<SortableTable<T>> {
  late int _sort = widget.initialSort;
  late bool _asc = widget.initialAscending;
  bool _all = false;

  void _sortBy(int i) => setState(() {
    if (_sort == i) {
      _asc = !_asc;
    } else {
      _sort = i;
      // Numbers read best biggest-first.
      _asc = !widget.columns[i].numeric;
    }
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    return LayoutBuilder(
      builder: (context, box) {
        final visible = [
          for (var i = 0; i < widget.columns.length; i++)
            if (box.maxWidth >= widget.columns[i].hideBelow) i,
        ];
        final rows = [...widget.rows];
        final key = _sort < widget.columns.length ? widget.columns[_sort].sortKey : null;
        if (key != null) {
          rows.sort((a, b) {
            final x = key(a), y = key(b);
            // Missing values always last.
            if (x == null && y == null) return 0;
            if (x == null) return 1;
            if (y == null) return -1;
            final c = x.compareTo(y);
            return _asc ? c : -c;
          });
        }
        final shown = _all ? rows : rows.take(widget.limit).toList();
        final head = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600, letterSpacing: 0.3);

        Widget cell(int i, Widget child) {
          final c = widget.columns[i];
          final aligned = Align(alignment: c.numeric ? Alignment.centerRight : Alignment.centerLeft, child: child);
          final padded = Padding(padding: const EdgeInsets.symmetric(horizontal: 6), child: aligned);
          return c.width == null ? Expanded(child: padded) : SizedBox(width: c.width, child: padded);
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 26,
              decoration: BoxDecoration(
                border: Border(bottom: BorderSide(color: colors.separator)),
              ),
              child: Row(
                children: [
                  for (final i in visible)
                    cell(
                      i,
                      Hoverable(
                        onTap: widget.columns[i].sortKey == null ? null : () => _sortBy(i),
                        builder: (h) => Tooltip(
                          message: widget.columns[i].tooltip ?? '',
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Flexible(
                                child: Text(
                                  widget.columns[i].label.toUpperCase(),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: head?.copyWith(color: h || _sort == i ? theme.colorScheme.onSurface : null),
                                ),
                              ),
                              if (_sort == i) Icon(_asc ? Icons.arrow_upward : Icons.arrow_downward, size: 11, color: theme.hintColor),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            for (final r in shown)
              Hoverable(
                onTap: widget.onTap == null ? null : () => widget.onTap!(r),
                builder: (h) => Container(
                  height: 28,
                  decoration: BoxDecoration(
                    color: widget.selected?.call(r) == true ? colors.selection : (h ? colors.hover : null),
                    border: Border(bottom: BorderSide(color: colors.separator.withValues(alpha: 0.5))),
                  ),
                  child: Row(children: [for (final i in visible) cell(i, widget.columns[i].cell(context, r))]),
                ),
              ),
            if (rows.length > shown.length)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton(onPressed: () => setState(() => _all = true), child: Text('Show all ${rows.length}')),
              ),
          ],
        );
      },
    );
  }
}
