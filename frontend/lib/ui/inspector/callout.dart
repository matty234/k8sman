import 'package:flutter/material.dart';

import '../../util/k8s.dart';
import '../theme.dart';
import 'insights.dart';

/// A note that needs attention, in the insights' style rather than a box:
/// a short rounded bar in the [severity] colour (a neutral grey for info),
/// a small icon, the [title] in the text colour, a quieter [body] (and any
/// [child] under it) and an optional [action]: a quiet button at the right
/// when there's room, under the text when narrow.
class Callout extends StatelessWidget {
  final Severity severity;

  /// Defaults to the severity's icon.
  final IconData? icon;
  final String title;
  final String? body;

  /// More under the body (e.g. a list).
  final Widget? child;
  final Widget? action;
  const Callout({super.key, required this.severity, required this.title, this.icon, this.body, this.child, this.action});

  /// Narrower than this, the action wraps under the text.
  static const wrapBelow = 400.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final info = severity == Severity.info || severity == Severity.neutral;
    final barColor = info ? AppColors.of(context).faint : severityColor(context, severity);
    final iconColor = info ? theme.hintColor : severityColor(context, severity);
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: theme.textTheme.bodySmall?.copyWith(fontSize: 12.5, color: theme.colorScheme.onSurface, height: 1.3)),
      if (body != null && body!.isNotEmpty)
        Padding(padding: const EdgeInsets.only(top: 2), child: Text(body!, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35))),
      if (child != null) Padding(padding: const EdgeInsets.only(top: 3), child: DefaultTextStyle.merge(style: TextStyle(color: theme.hintColor), child: child!)),
    ]);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: LayoutBuilder(builder: (context, box) {
        final below = box.maxWidth < wrapBelow;
        final action = this.action == null ? null : CompactButtons(child: this.action!);
        // The bar is positioned beside the content, so the content needs
        // no intrinsic sizes (it may hold anything).
        return Stack(children: [
          Padding(
            padding: const EdgeInsets.only(left: 12),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 1.5, right: 7), child: Icon(icon ?? severityIcon(severity), size: 14, color: iconColor)),
              Expanded(
                child: below && action != null
                    ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [text, Padding(padding: const EdgeInsets.only(top: 6), child: action)])
                    : text,
              ),
              if (!below && action != null) Padding(padding: const EdgeInsets.only(left: 12), child: action),
            ]),
          ),
          Positioned(
            left: 0,
            top: 1,
            bottom: 1,
            width: 3,
            child: DecoratedBox(key: const ValueKey('callout-bar'), decoration: BoxDecoration(color: barColor, borderRadius: BorderRadius.circular(2))),
          ),
        ]);
      }),
    );
  }
}
