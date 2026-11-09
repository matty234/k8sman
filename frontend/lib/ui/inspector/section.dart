import 'package:flutter/material.dart';

import '../widgets/common.dart';
import '../widgets/editorial.dart' show SectionHeader;

/// Open/closed state of inspector sections and rows, kept for the session
/// so something the user opened stays open on the next object.
class SectionMemory {
  SectionMemory._();
  static final Map<String, bool> _open = {};

  static bool isOpen(String id, {required bool fallback}) => _open[id] ?? fallback;
  static void set(String id, bool open) => _open[id] = open;

  @visibleForTesting
  static void reset() => _open.clear();
}

/// An inspector section in the Overview's style: a small semibold label
/// with a hairline running to [trailing] (a count or one-line summary),
/// collapsible from the header. Its open state is remembered per [id] for
/// the session; [initiallyExpanded] is the default. The header is keyed
/// `pod-section-<id>` (the pod inspector's, where it started).
class InspectorSection extends StatefulWidget {
  final String id;
  final String title;
  final Widget? trailing;
  final Widget child;
  final bool initiallyExpanded;
  const InspectorSection({super.key, required this.id, required this.title, required this.child, this.trailing, this.initiallyExpanded = true});

  @override
  State<InspectorSection> createState() => _InspectorSectionState();
}

class _InspectorSectionState extends State<InspectorSection> {
  late bool _open = SectionMemory.isOpen(widget.id, fallback: widget.initiallyExpanded);

  void _toggle() {
    setState(() => _open = !_open);
    SectionMemory.set(widget.id, _open);
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
