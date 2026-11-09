import 'package:flutter/material.dart';

import '../../ui/widgets/editorial.dart' show SectionHeader;
import '../../ui/widgets/common.dart';

/// Expanded/collapsed state per pod inspector section, kept for the session
/// so a section the user opened stays open on the next pod.
class PodSectionMemory {
  PodSectionMemory._();
  static final Map<String, bool> _open = {};

  static bool isOpen(String id, {required bool fallback}) => _open[id] ?? fallback;
  static void set(String id, bool open) => _open[id] = open;

  @visibleForTesting
  static void reset() => _open.clear();
}

/// A pod inspector section in the Overview's style: a small semibold
/// label with a hairline running to [trailing] (a count or one-line
/// summary), collapsible from the header. Its open state is remembered
/// per [id] for the session; [initiallyExpanded] is the default.
class PodSection extends StatefulWidget {
  final String id;
  final String title;
  final Widget? trailing;
  final Widget child;
  final bool initiallyExpanded;
  const PodSection({super.key, required this.id, required this.title, required this.child, this.trailing, this.initiallyExpanded = true});

  @override
  State<PodSection> createState() => _PodSectionState();
}

class _PodSectionState extends State<PodSection> {
  late bool _open = PodSectionMemory.isOpen(widget.id, fallback: widget.initiallyExpanded);

  void _toggle() {
    setState(() => _open = !_open);
    PodSectionMemory.set(widget.id, _open);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 18, bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        LayoutBuilder(builder: (context, box) {
          // The trailing summary gets what the title, chevron and a short
          // hairline leave, ellipsised; far too narrow (the inspector
          // animating shut), just the title.
          final theme = Theme.of(context);
          final title = TextPainter(
            text: TextSpan(text: widget.title, style: theme.textTheme.labelLarge?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600, letterSpacing: 0.2)),
            textDirection: TextDirection.ltr,
            textScaler: MediaQuery.textScalerOf(context),
          )..layout();
          final room = box.maxWidth - title.width - 15 - 10 - 24 - 12;
          title.dispose();
          return Hoverable(
            key: ValueKey('pod-section-${widget.id}'),
            onTap: _toggle,
            builder: (h) => room < 0
                ? Text(widget.title, maxLines: 1, overflow: TextOverflow.clip, softWrap: false)
                : SectionHeader(
                    title: widget.title,
                    trailing: widget.trailing == null ? null : ConstrainedBox(constraints: BoxConstraints(maxWidth: room), child: widget.trailing!),
                    expanded: _open,
                    hovered: h,
                  ),
          );
        }),
        if (_open) Padding(padding: const EdgeInsets.only(top: 8), child: widget.child),
      ]),
    );
  }
}

/// One-line dim summary for a section header; ellipsised when narrow.
class SectionSummary extends StatelessWidget {
  final String text;
  final Color? color;
  const SectionSummary(this.text, {super.key, this.color});

  @override
  Widget build(BuildContext context) => Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: color == null ? null : TextStyle(color: color));
}
