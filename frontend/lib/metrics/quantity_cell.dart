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
const usageBarMinWidth = 90.0;

/// Table cell for the `usage` column type (see [UsageValue]): the value, a
/// thin bar against the limit/request/allocatable/capacity and the
/// percentage, which turns amber at 70% (80% of a capacity) and red at 90%.
/// Narrower than [usageBarMinWidth] it keeps only the value; "—" when empty.
class UsageCell extends StatelessWidget {
  final dynamic value;
  final TextStyle? style;
  const UsageCell({super.key, required this.value, this.style});

  static const _barWidth = 30.0;
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
      return Row(children: [
        Expanded(child: valueText),
        const SizedBox(width: 6),
        SizedBox(
          width: _barWidth,
          child: p == null
              ? null
              : _UsageBar(frac: p / 100, color: alert ?? theme.colorScheme.onSurface.withValues(alpha: 0.42)),
        ),
        SizedBox(
          width: _pctWidth,
          child: p == null
              ? null
              : Text(
                  formatPercent(p / 100),
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
