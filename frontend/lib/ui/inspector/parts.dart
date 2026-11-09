import 'package:flutter/material.dart';

import '../theme.dart';
import '../widgets/common.dart';

/// A quiet group: a small uppercase label in the hint colour over its rows
/// ([gap] between them).
class QuietGroup extends StatelessWidget {
  final String label;
  final List<Widget> children;
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
/// more than [trimAbove]; [gap] between them. The link sits [indent] in
/// (rows have 4 of padding; plain lines pass 0).
class TrimmedList extends StatefulWidget {
  final List<Widget>? children;
  final int keep;
  final int trimAbove;
  final double gap;
  final double indent;

  /// For [TrimmedList.builder].
  final int? total;
  final Widget Function(int shown)? builder;
  const TrimmedList(List<Widget> this.children, {super.key, this.keep = 4, this.trimAbove = 6, this.gap = 0, this.indent = 4})
      : total = null,
        builder = null;

  /// Builds the first `shown` of [total] items itself (e.g. as a table).
  const TrimmedList.builder({super.key, required int this.total, required Widget Function(int shown) this.builder, this.keep = 4, this.trimAbove = 6, this.indent = 0})
      : children = null,
        gap = 0;

  @override
  State<TrimmedList> createState() => _TrimmedListState();
}

class _TrimmedListState extends State<TrimmedList> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final total = widget.total ?? widget.children!.length;
    final trims = total > widget.trimAbove;
    final shown = trims && !_all ? widget.keep : total;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (widget.builder != null)
        widget.builder!(shown)
      else
        for (var i = 0; i < shown; i++) Padding(padding: EdgeInsets.only(top: i == 0 ? 0 : widget.gap), child: widget.children![i]),
      if (trims) ShowMoreLink(_all ? 'Show fewer' : 'Show ${total - shown} more', indent: widget.indent, onTap: () => setState(() => _all = !_all)),
    ]);
  }
}

/// A quiet "Show N more" link.
class ShowMoreLink extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  final double indent;
  const ShowMoreLink(this.text, {super.key, required this.onTap, this.indent = 4});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: EdgeInsets.only(left: indent, top: 4),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Hoverable(
          key: const ValueKey('show-more'),
          onTap: onTap,
          builder: (h) => Text(text,
              style: theme.textTheme.bodySmall?.copyWith(color: h ? theme.colorScheme.onSurface : theme.hintColor, decoration: h ? TextDecoration.underline : null)),
        ),
      ),
    );
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

/// Mono text on one line (ellipsised, full text in a tooltip) with a copy
/// icon after it.
class MonoCopy extends StatelessWidget {
  final String text;
  final double size;
  const MonoCopy(this.text, {super.key, this.size = 11.5});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(
        child: Tooltip(
          message: text,
          waitDuration: const Duration(milliseconds: 500),
          child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, softWrap: false, style: monoStyle(context, size: size)),
        ),
      ),
      InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => copyToClipboard(context, text),
        child: Tooltip(message: 'Copy', child: Padding(padding: const EdgeInsets.all(3), child: Icon(Icons.copy, size: 12, color: theme.hintColor))),
      ),
    ]);
  }
}

/// Dim small text.
class Quiet extends StatelessWidget {
  final String text;
  final Color? color;
  const Quiet(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(text, style: theme.textTheme.bodySmall?.copyWith(color: color ?? theme.hintColor));
  }
}
