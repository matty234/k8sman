import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart' show tabularFigures;
import 'section.dart';

/// A child as one compact row: a state [dot] (or a small [leading] icon), a
/// title over a quiet subtitle, small [trailing] figures on the right,
/// [actions] that show on hover (always while it's a [problem] or open, or
/// with [actionsAlways]), and a chevron when it has [details]. Click to
/// open; the open state is remembered per [memoryId] for the session.
/// Rows marked [problem] start open unless [initiallyExpanded] says
/// otherwise.
class InspectorRow extends StatefulWidget {
  final String? memoryId;
  final Severity? dot;

  /// A small icon in place of the dot (e.g. a kind icon).
  final Widget? leading;
  final bool hollowDot;
  final String? dotTooltip;
  final Widget title;
  final Widget? subtitle;

  /// Builds the subtitle while the row is open, when the details repeat
  /// part of it (null from it: no subtitle). Unset: [subtitle] always.
  final Widget? Function()? openSubtitle;
  final List<Widget> trailing;
  final List<Widget> actions;

  /// Shows [actions] without hovering (e.g. Reveal on a secret key).
  final bool actionsAlways;

  /// Keeps the actions visible and opens the row by default. Null: the
  /// actions show while the [dot] is a warning or an error, and the row
  /// starts closed.
  final bool? problem;
  final WidgetBuilder? details;

  /// Always shown under the header, e.g. a revealed value.
  final Widget? below;
  final bool? initiallyExpanded;
  const InspectorRow({
    super.key,
    required this.title,
    this.memoryId,
    this.dot,
    this.leading,
    this.hollowDot = false,
    this.dotTooltip,
    this.subtitle,
    this.openSubtitle,
    this.trailing = const [],
    this.actions = const [],
    this.actionsAlways = false,
    this.problem,
    this.details,
    this.below,
    this.initiallyExpanded,
  });

  bool get isProblem => problem ?? (dot == Severity.error || dot == Severity.warn);

  @override
  State<InspectorRow> createState() => _InspectorRowState();
}

class _InspectorRowState extends State<InspectorRow> {
  late bool _open = widget.memoryId == null
      ? (widget.initiallyExpanded ?? widget.problem ?? false)
      : SectionMemory.isOpen(widget.memoryId!, fallback: widget.initiallyExpanded ?? widget.problem ?? false);

  bool get _expandable => widget.details != null;

  double get _indent => widget.dot != null ? 15 : (widget.leading != null ? 18 : 0);

  void _toggle() {
    setState(() => _open = !_open);
    if (widget.memoryId != null) SectionMemory.set(widget.memoryId!, _open);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final open = _open && _expandable;
    final interactive = _expandable || widget.actions.isNotEmpty;
    return Hoverable(
      onTap: _expandable ? _toggle : null,
      builder: (hovered) => Container(
        decoration: BoxDecoration(color: hovered && !open && interactive ? colors.hover : null, borderRadius: BorderRadius.circular(5)),
        padding: const EdgeInsets.fromLTRB(4, 6, 2, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(context, hovered, open),
          if (widget.below != null) Padding(padding: EdgeInsets.fromLTRB(_indent, 4, 6, 0), child: widget.below),
          if (open)
            // Taps inside the details (links, copy, selection) must not
            // collapse the row.
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {},
              child: MouseRegion(
                cursor: SystemMouseCursors.basic,
                child: Padding(padding: EdgeInsets.fromLTRB(_indent, 8, 6, 2), child: widget.details!(context)),
              ),
            ),
        ]),
      ),
    );
  }

  Widget _header(BuildContext context, bool hovered, bool open) {
    final theme = Theme.of(context);
    final showActions = widget.actionsAlways || hovered || widget.isProblem || open;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (widget.dot != null) ...[
        Padding(padding: const EdgeInsets.only(top: 5), child: RowDot(widget.dot!, hollow: widget.hollowDot, tooltip: widget.dotTooltip)),
        const SizedBox(width: 8),
      ] else if (widget.leading != null) ...[
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: SizedBox(width: 12, child: IconTheme.merge(data: IconThemeData(size: 12, color: theme.hintColor), child: widget.leading!)),
        ),
        const SizedBox(width: 6),
      ],
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DefaultTextStyle.merge(
            style: theme.textTheme.bodySmall?.copyWith(fontSize: 12.5, color: theme.colorScheme.onSurface),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            child: widget.title,
          ),
          if ((open && widget.openSubtitle != null ? widget.openSubtitle!() : widget.subtitle) case final sub?) ...[
            const SizedBox(height: 2),
            DefaultTextStyle.merge(style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor), maxLines: 1, overflow: TextOverflow.ellipsis, child: sub),
          ],
        ]),
      ),
      for (final m in widget.trailing) ...[
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: DefaultTextStyle.merge(style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontFeatures: tabularFigures), child: m),
        ),
      ],
      if (widget.actions.isNotEmpty) ...[
        const SizedBox(width: 4),
        Row(mainAxisSize: MainAxisSize.min, children: [for (final a in widget.actions) RevealOnHover(visible: showActions, child: a)]),
      ],
      if (_expandable)
        Padding(
          padding: const EdgeInsets.only(top: 1, left: 2),
          child: AnimatedRotation(
            turns: open ? 0.25 : 0,
            duration: const Duration(milliseconds: 120),
            child: Icon(Icons.chevron_right, size: 16, color: hovered || open ? theme.hintColor : theme.hintColor.withValues(alpha: theme.hintColor.a * 0.5)),
          ),
        ),
    ]);
  }
}

/// The small state dot of an [InspectorRow]: filled in the severity's
/// colour, hollow when neutral (or [hollow]).
class RowDot extends StatelessWidget {
  final Severity severity;
  final bool hollow;
  final String? tooltip;
  const RowDot(this.severity, {super.key, this.hollow = false, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final color = severityColor(context, severity);
    final hollow = this.hollow || severity == Severity.neutral;
    final dot = Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(shape: BoxShape.circle, color: hollow ? null : color, border: hollow ? Border.all(color: color, width: 1.2) : null),
    );
    return tooltip == null ? dot : Tooltip(message: tooltip!, child: dot);
  }
}

/// Always laid out (no jump on hover) but only visible when [visible], or
/// when the child grows wider than an icon (a live port-forward's
/// `localhost:N` link stays visible).
class RevealOnHover extends StatefulWidget {
  final bool visible;
  final Widget child;

  /// Whether a hidden child ignores taps (false: invisible but clickable).
  final bool blockWhenHidden;
  const RevealOnHover({super.key, required this.visible, required this.child, this.blockWhenHidden = true});

  @override
  State<RevealOnHover> createState() => _RevealOnHoverState();
}

class _RevealOnHoverState extends State<RevealOnHover> {
  bool _wide = false;

  void _measured(Size size) {
    final wide = size.width > 30;
    if (wide == _wide) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _wide = wide);
    });
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        ignoring: widget.blockWhenHidden && !(widget.visible || _wide),
        child: AnimatedOpacity(
          opacity: widget.visible || _wide ? 1 : 0,
          duration: const Duration(milliseconds: 100),
          child: _SizeObserver(onSize: _measured, child: widget.child),
        ),
      );
}

class _SizeObserver extends SingleChildRenderObjectWidget {
  final ValueChanged<Size> onSize;
  const _SizeObserver({required this.onSize, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSizeObserver(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderSizeObserver renderObject) => renderObject.onSize = onSize;
}

class _RenderSizeObserver extends RenderProxyBox {
  ValueChanged<Size> onSize;
  _RenderSizeObserver(this.onSize);

  @override
  void performLayout() {
    super.performLayout();
    onSize(size);
  }
}

/// A small icon action for an [InspectorRow].
class RowAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  const RowAction({super.key, required this.icon, required this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    return Tooltip(
      message: tooltip,
      child: Hoverable(
        onTap: onTap,
        builder: (h) => Container(
          width: 22,
          height: 20,
          decoration: BoxDecoration(color: h && onTap != null ? accent.withValues(alpha: 0.12) : null, borderRadius: BorderRadius.circular(4)),
          child: Icon(icon, size: 14, color: onTap == null ? theme.disabledColor : (h ? accent : theme.hintColor)),
        ),
      ),
    );
  }
}

/// Copies [value]; a [RowAction].
RowAction copyAction(BuildContext context, String value, {String? tooltip}) =>
    RowAction(icon: Icons.copy, tooltip: tooltip ?? 'Copy $value', onTap: () => copyToClipboard(context, value));

/// A label for a run of rows inside a section ("Init", "Matching pods").
class RowGroupLabel extends StatelessWidget {
  final String text;
  const RowGroupLabel(this.text, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 10, 0, 2),
      child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(fontSize: 11, fontWeight: FontWeight.w600, color: theme.hintColor)),
    );
  }
}

/// Dim one-line text for a row's subtitle, parts joined by " · ".
Widget dotLine(List<String> parts) => Text(parts.where((p) => p.isNotEmpty).join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis);
