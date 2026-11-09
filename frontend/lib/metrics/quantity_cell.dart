import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../ui/theme.dart';
import '../util/k8s.dart';
import 'quantity.dart';
import 'widgets.dart';

/// Table cell for the `quantity` column type ("250m", "128Mi", "42%"):
/// right-aligned tabular figures, "—" when empty (e.g. no metrics yet), and
/// threshold colour for percentages (≥ 70% amber, ≥ 90% red).
Widget quantityCell(BuildContext context, dynamic value, TextStyle? base) {
  final theme = Theme.of(context);
  final s = value == null ? '' : (value is List ? value.join(', ') : '$value');
  final style = base?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
  if (s.isEmpty) return Text('—', textAlign: TextAlign.right, style: style?.copyWith(color: theme.hintColor));
  Color? color;
  if (s.endsWith('%')) {
    final p = parseQuantity(s);
    if (p != null) color = percentColor(context, p / 100);
  }
  return Text(
    s,
    textAlign: TextAlign.right,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: style?.copyWith(color: color),
  );
}

/// Below this width a usage cell shows only its value.
const usageBarMinWidth = 112.0;

/// Table cell for the `usage` column type (see [UsageValue]): the value, a
/// thin bar against the limit/request/allocatable/capacity and the
/// percentage, which turns amber at 70% (80% of a capacity) and red at 90%.
/// Narrower than [usageBarMinWidth] it keeps only the value; "—" when empty.
class UsageCell extends StatelessWidget {
  final dynamic value;
  final TextStyle? style;
  const UsageCell({super.key, required this.value, this.style});

  static const _pctWidth = 38.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = this.style?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]);
    final u = UsageValue.of(value);
    if (u == null) return Text('—', textAlign: TextAlign.right, style: style?.copyWith(color: AppColors.of(context).faint));
    final sev = u.severity;
    final alert = sev == Severity.neutral ? null : severityColor(context, sev);
    final p = u.percent;
    final valueText = Text(u.text, textAlign: TextAlign.right, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
    final cell = LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < usageBarMinWidth) {
        return Align(
          alignment: Alignment.centerRight,
          child: Text(u.text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style?.copyWith(color: alert)),
        );
      }
      // The bar and percentage keep their place (blank without a base) so
      // values line up down the column.
      // The value takes a right-aligned slot sized to the column (so values
      // and bars line up down it), and the bar fills what's left.
      // Wide enough for the text (snapped up to a 16px step so rows with
      // similar values share a slot), and at least a third of the cell.
      final measured = (TextPainter(text: TextSpan(text: u.text, style: style), maxLines: 1, textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context))..layout()).width;
      final room = box.maxWidth - _pctWidth - 12 - 16; // keep 16px for the bar
      final valueWidth = math.min(room, math.max((box.maxWidth - _pctWidth) / 3, (measured / 16).ceil() * 16.0));
      return Row(children: [
        SizedBox(width: valueWidth, child: valueText),
        const SizedBox(width: 6),
        Expanded(
          child: p == null
              ? const SizedBox.shrink()
              : _UsageBar(frac: p / 100, color: alert ?? theme.colorScheme.onSurface.withValues(alpha: 0.42)),
        ),
        SizedBox(
          width: _pctWidth,
          child: p == null
              ? null
              : Text(
                  // 10× and over reads as a multiplier ("13×"): four-digit
                  // percentages don't fit, and "1300%" says less at a glance.
                  p >= 1000 ? '${(p / 100).round()}×' : formatPercent(p / 100),
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  style: style?.copyWith(color: alert ?? theme.hintColor),
                ),
        ),
      ]);
    });
    final detail = u.detail;
    return detail == u.text ? cell : Tooltip(message: detail, waitDuration: const Duration(milliseconds: 500), child: cell);
  }
}

class _UsageBar extends StatelessWidget {
  final double frac;
  final Color color;
  const _UsageBar({required this.frac, required this.color});

  @override
  Widget build(BuildContext context) {
    const h = 3.0;
    final track = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(h),
        child: SizedBox(
          height: h,
          child: Stack(fit: StackFit.expand, children: [
            ColoredBox(color: track),
            FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: frac.clamp(0.0, 1.0),
              child: ColoredBox(color: color),
            ),
          ]),
        ),
      ),
    );
  }
}
