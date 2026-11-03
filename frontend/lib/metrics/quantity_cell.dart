import 'package:flutter/material.dart';

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
