/// Small pieces for inspector sections in the pod inspector's style: quiet
/// labelled groups, lists trimmed with "Show N more", and mono values whose
/// copy icon shows on hover.
library;

import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/common.dart';

/// A quiet group: a small uppercase label in the hint colour over its rows.
class QuietGroup extends StatelessWidget {
  final String label;
  final List<Widget> children;

  /// Space between the rows.
  final double gap;
  const QuietGroup(this.label, this.children, {super.key, this.gap = 4});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(label.toUpperCase(), style: theme.textTheme.bodySmall?.copyWith(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.7, color: theme.hintColor)),
      for (final (i, w) in children.indexed) Padding(padding: EdgeInsets.only(top: i == 0 ? 5 : gap), child: w),
    ]);
  }
}

/// [children] trimmed to the first [keep] with "Show N more" when there are
/// more than [trimAbove]; [gap] between them.
class TrimmedList extends StatefulWidget {
  final List<Widget> children;
  final int keep;
  final int trimAbove;
  final double gap;
  const TrimmedList(this.children, {super.key, this.keep = 4, this.trimAbove = 6, this.gap = 4});

  @override
  State<TrimmedList> createState() => _TrimmedListState();
}

class _TrimmedListState extends State<TrimmedList> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = widget.children.length;
    final trims = total > widget.trimAbove;
    final shown = trims && !_all ? widget.keep : total;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (var i = 0; i < shown; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : widget.gap), child: widget.children[i]),
      if (trims)
        Padding(
          padding: EdgeInsets.only(top: widget.gap),
          child: Align(
            alignment: Alignment.centerLeft,
            child: Hoverable(
              key: const ValueKey('show-more'),
              onTap: () => setState(() => _all = !_all),
              builder: (h) => Text(
                _all ? 'Show fewer' : 'Show ${total - shown} more',
                style: theme.textTheme.bodySmall?.copyWith(color: h ? theme.colorScheme.onSurface : theme.hintColor, decoration: h ? TextDecoration.underline : null),
              ),
            ),
          ),
        ),
    ]);
  }
}

/// Mono "key=value" (or any [child]) with a copy icon after it on hover;
/// [copy] is what the icon copies.
class HoverCopy extends StatelessWidget {
  final Widget child;
  final String copy;
  const HoverCopy({super.key, required this.child, required this.copy});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Hoverable(
      builder: (h) => Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        Flexible(child: child),
        // Always laid out, so showing it moves nothing.
        Opacity(
          opacity: h ? 1 : 0,
          child: Tooltip(
            message: 'Copy',
            child: Hoverable(
              onTap: () => copyToClipboard(context, copy),
              builder: (ih) => Padding(
                padding: const EdgeInsets.fromLTRB(5, 2, 1, 0),
                child: Icon(Icons.copy, size: 12, color: ih ? theme.colorScheme.onSurface : theme.hintColor),
              ),
            ),
          ),
        ),
      ]),
    );
  }
}

/// "key=value" in mono with the key in the hint colour.
Widget keyValueText(BuildContext context, String k, String v, {int? maxLines = 2, String sep = '='}) {
  final theme = Theme.of(context);
  return Text.rich(
    TextSpan(children: [
      TextSpan(text: '$k$sep', style: TextStyle(color: theme.hintColor)),
      TextSpan(text: v),
    ]),
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
    style: monoStyle(context, size: 11),
  );
}
