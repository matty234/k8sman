import 'package:flutter/material.dart';

import '../../util/k8s.dart';
import '../theme.dart';
import 'insight.dart';

export 'insight.dart';

/// [insights] as [InsightLine]s, nothing boxed.
class InsightList extends StatelessWidget {
  final List<Insight> insights;
  const InsightList(this.insights, {super.key});

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (n, i) in insights.indexed) Padding(padding: EdgeInsets.only(top: n == 0 ? 0 : 10), child: InsightLine.of(i)),
      ]);
}

/// One insight: a short bar in its severity colour beside a bold line, a
/// quieter detail and an optional [action] under them. Use it directly for
/// insights that load or carry a widget.
class InsightLine extends StatelessWidget {
  final Severity severity;
  final String text;
  final String? detail;
  final Widget? title;
  final Widget? action;
  const InsightLine(this.severity, this.text, {super.key, this.detail, this.title, this.action});

  InsightLine.of(Insight i, {Key? key}) : this(i.severity, i.text, key: key, detail: i.detail, title: i.title, action: i.action);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final strong = theme.textTheme.bodySmall?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface, height: 1.3);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          width: 2.5,
          margin: const EdgeInsets.only(top: 2, bottom: 2, right: 10),
          decoration: BoxDecoration(color: severityColor(context, severity), borderRadius: BorderRadius.circular(2)),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            title == null ? Text(text, style: strong) : DefaultTextStyle.merge(style: strong, child: title!),
            if (detail != null && detail!.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 3), child: Text(detail!, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35))),
            if (action != null) Padding(padding: const EdgeInsets.only(top: 6), child: CompactButtons(child: action!)),
          ]),
        ),
      ]),
    );
  }
}

/// Shrinks outlined/filled buttons (e.g. ActionButton) to fit a dense row.
class CompactButtons extends StatelessWidget {
  final Widget child;
  const CompactButtons({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll(Size(0, 24)),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: WidgetStatePropertyAll(Theme.of(context).textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600)),
      iconSize: const WidgetStatePropertyAll(14),
    );
    // Over the app's button styles, so they keep their tinted fills.
    final theme = Theme.of(context);
    return Theme(
      data: theme.copyWith(
        outlinedButtonTheme: OutlinedButtonThemeData(style: style.merge(theme.outlinedButtonTheme.style)),
        filledButtonTheme: FilledButtonThemeData(style: style.merge(theme.filledButtonTheme.style)),
      ),
      child: child,
    );
  }
}
