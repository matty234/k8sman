import 'package:flutter/material.dart';

import '../theme.dart';

/// A horizontal split: an optional fixed-width [start] pane, a flexible
/// [center] pane and an optional fixed-width [end] pane, separated by
/// draggable hairline dividers (wide invisible grab area, resize cursor,
/// highlight on hover and drag). Double-clicking a divider resets that pane to
/// its default width.
///
/// Widths are controlled: pass the current [startWidth] / [endWidth] (null =
/// the default) and update them from [onStartChanged] / [onEndChanged]. They
/// are clamped to each pane's minimum and to the space available, so shrinking
/// the window never overflows.
class ResizableSplit extends StatelessWidget {
  const ResizableSplit({
    super.key,
    required this.center,
    this.start,
    this.end,
    this.startWidth,
    this.endWidth,
    this.defaultStart = 230,
    this.defaultEnd = 310,
    this.onStartChanged,
    this.onEndChanged,
    this.minStart = 220,
    this.minEnd = 220,
    this.minCenter = 320,
  });

  final Widget center;
  final Widget? start;
  final Widget? end;
  final double? startWidth;
  final double? endWidth;
  final double defaultStart;
  final double defaultEnd;
  final ValueChanged<double?>? onStartChanged;
  final ValueChanged<double?>? onEndChanged;
  final double minStart;
  final double minEnd;
  final double minCenter;

  static const handleWidth = 5.0;

  static double _fit(double w, double min, double max) {
    final hi = max < 0 ? 0.0 : max;
    final lo = min > hi ? hi : min;
    return w.clamp(lo, hi);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, box) {
      final handles = (start != null ? handleWidth : 0) + (end != null ? handleWidth : 0);
      var s = start == null ? 0.0 : (startWidth ?? defaultStart);
      var e = end == null ? 0.0 : (endWidth ?? defaultEnd);
      if (start != null) s = _fit(s, minStart, box.maxWidth - handles - minCenter - (end != null ? minEnd : 0));
      if (end != null) e = _fit(e, minEnd, box.maxWidth - handles - minCenter - s);
      if (start != null) s = _fit(s, minStart, box.maxWidth - handles - minCenter - e);
      return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (start != null) ...[
          SizedBox(width: s, child: start),
          _Handle(
            key: const ValueKey('split-start'),
            onDrag: (dx) => onStartChanged?.call(_fit(s + dx, minStart, box.maxWidth - handles - minCenter - e)),
            onReset: () => onStartChanged?.call(null),
          ),
        ],
        Expanded(child: center),
        if (end != null) ...[
          _Handle(
            key: const ValueKey('split-end'),
            onDrag: (dx) => onEndChanged?.call(_fit(e - dx, minEnd, box.maxWidth - handles - minCenter - s)),
            onReset: () => onEndChanged?.call(null),
          ),
          SizedBox(width: e, child: end),
        ],
      ]);
    });
  }
}

class _Handle extends StatefulWidget {
  const _Handle({super.key, required this.onDrag, required this.onReset});
  final ValueChanged<double> onDrag;
  final VoidCallback onReset;

  @override
  State<_Handle> createState() => _HandleState();
}

class _HandleState extends State<_Handle> {
  bool _hover = false;
  bool _drag = false;

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final active = _hover || _drag;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: widget.onReset,
        onHorizontalDragStart: (_) => setState(() => _drag = true),
        onHorizontalDragUpdate: (d) => widget.onDrag(d.delta.dx),
        onHorizontalDragEnd: (_) => setState(() => _drag = false),
        onHorizontalDragCancel: () => setState(() => _drag = false),
        child: SizedBox(
          width: ResizableSplit.handleWidth,
          child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Expanded(child: ColoredBox(color: active ? colors.hover : Colors.transparent)),
            Container(width: 1, color: colors.separator),
            Expanded(child: ColoredBox(color: active ? colors.hover : Colors.transparent)),
          ]),
        ),
      ),
    );
  }
}
