import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import 'pod_logic.dart';

/// Monospace selectable text with an optional inline copy button.
class MonoValue extends StatelessWidget {
  final String text;
  final bool copy;
  final Color? color;
  final double size;
  const MonoValue(this.text, {super.key, this.copy = false, this.color, this.size = 12});

  @override
  Widget build(BuildContext context) {
    final t = Text(text, style: monoStyle(context, size: size, color: color));
    if (!copy) return t;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Flexible(child: t),
      CopyIcon(text),
    ]);
  }
}

class CopyIcon extends StatelessWidget {
  final String value;
  const CopyIcon(this.value, {super.key});

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => copyToClipboard(context, value),
        child: Tooltip(
          message: 'Copy',
          child: Padding(padding: const EdgeInsets.fromLTRB(6, 2, 2, 2), child: Icon(Icons.copy, size: 12, color: Theme.of(context).hintColor)),
        ),
      );
}

/// Small uppercase tag: INIT / SIDECAR / CONTAINER / EPHEMERAL.
class KindTag extends StatelessWidget {
  final ContainerKind kind;
  const KindTag(this.kind, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = switch (kind) {
      ContainerKind.init => Colors.blueGrey.shade300,
      ContainerKind.sidecar => Colors.teal.shade300,
      ContainerKind.regular => theme.colorScheme.primary,
      ContainerKind.ephemeral => Colors.purple.shade200,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
      decoration: BoxDecoration(border: Border.all(color: c.withValues(alpha: 0.6)), borderRadius: BorderRadius.circular(3)),
      child: Text(kind.label.toUpperCase(), style: TextStyle(fontSize: 9.5, letterSpacing: 0.6, fontWeight: FontWeight.w700, color: c)),
    );
  }
}

/// The derived "why not ready" explanation list: each line marked by a
/// short bar in its severity colour, nothing boxed.
class InsightList extends StatelessWidget {
  final List<PodInsight> insights;
  const InsightList(this.insights, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (n, i) in insights.indexed)
        Padding(
          padding: EdgeInsets.only(top: n == 0 ? 0 : 10),
          child: IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Container(
                width: 2.5,
                margin: const EdgeInsets.only(top: 2, bottom: 2, right: 10),
                decoration: BoxDecoration(color: severityColor(context, i.severity), borderRadius: BorderRadius.circular(2)),
              ),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(i.text, style: theme.textTheme.bodySmall?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface, height: 1.3)),
                  if (i.detail != null && i.detail!.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(i.detail!, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35)),
                    ),
                ]),
              ),
            ]),
          ),
        ),
    ]);
  }
}

/// Inline row of small widgets separated by spacing; wraps when narrow.
class InlineWrap extends StatelessWidget {
  final List<Widget> children;
  const InlineWrap(this.children, {super.key});

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: children);
}

/// Dim helper text.
class Hint extends StatelessWidget {
  final String text;
  const Hint(this.text, {super.key});

  @override
  Widget build(BuildContext context) =>
      Text(text, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor));
}
