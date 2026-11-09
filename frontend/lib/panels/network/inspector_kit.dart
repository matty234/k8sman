/// The pod inspector's organisation for the other kinds: a status header
/// (headline with a mark, large figures, insights, a few facts), children as
/// compact rows (problems first and open, actions on hover), and quiet
/// labelled groups inside an opened row. Sections come from
/// `pod_section.dart` ([PodSection], [SectionSummary]).
///
/// Shared by the network, gateway and cluster panels.
library;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../api/models.dart';
import '../../ui/nodes/nodes_view.dart' show podHasProblem;
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/pod.dart';
import '../cluster/logic.dart' show podKubectlStatus, isTerminalPod;
import '../pod/pod_logic.dart' show PodInsight;
import '../pod/pod_section.dart';
import '../pod/pod_widgets.dart' show InsightList;

export '../pod/pod_logic.dart' show PodInsight;
export '../pod/pod_section.dart' show PodSection, SectionSummary;

const _tabular = [FontFeature.tabularFigures()];

/// The worst of [insights] (null when there are none or only info).
Severity? worstOf(Iterable<PodInsight> insights) {
  if (insights.any((i) => i.severity == Severity.error)) return Severity.error;
  if (insights.any((i) => i.severity == Severity.warn)) return Severity.warn;
  return null;
}

// ---------------------------------------------------------------------------
// Status header
// ---------------------------------------------------------------------------

/// One large figure of an [InspectorHeader].
class HeaderFigure {
  final String value;
  final String? of;
  final String label;
  final Severity severity;
  final String? tooltip;
  final dynamic since;
  final Key? key;
  const HeaderFigure(this.value, this.label, {this.of, this.severity = Severity.neutral, this.tooltip, this.key}) : since = null;

  /// The time since [since] ("6d"), e.g. "up" or "last seen".
  const HeaderFigure.age(this.since, this.label, {this.key})
      : value = '',
        of = null,
        severity = Severity.neutral,
        tooltip = null;
}

/// The top of an inspector: is it OK, and if not, why? A headline with a
/// mark (and optional [chips] beside it), a quiet [detail] line, a row of
/// large figures, the [insights] explaining any problem, then [facts].
class InspectorHeader extends StatelessWidget {
  final Severity mark;
  final String headline;
  final String? detail;
  final List<Widget> chips;
  final List<HeaderFigure> figures;
  final List<PodInsight> insights;
  final Widget? facts;
  const InspectorHeader({
    super.key,
    required this.mark,
    required this.headline,
    this.detail,
    this.chips = const [],
    this.figures = const [],
    this.insights = const [],
    this.facts,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor, fontSize: 12.5);
    final title = theme.textTheme.titleLarge?.copyWith(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.2, height: 1.2);
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          SizedBox(width: 20, child: Align(alignment: Alignment.centerLeft, child: StateMark(mark))),
          Flexible(child: Text(headline, key: const ValueKey('inspector-headline'), maxLines: 1, overflow: TextOverflow.ellipsis, style: title)),
          for (final c in chips) ...[const SizedBox(width: 8), c],
        ]),
        if (detail != null && detail!.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 20, top: 2), child: Text(detail!, key: const ValueKey('inspector-detail'), style: hint)),
        if (figures.isNotEmpty) ...[const SizedBox(height: 14), FigureStrip(figures)],
        if (insights.isNotEmpty) ...[const SizedBox(height: 14), InsightList(insights)],
        if (facts != null) ...[const SizedBox(height: 14), facts!],
      ]),
    );
  }
}

/// A check when ok, a hollow ring when neutral, else a dot in the severity.
class StateMark extends StatelessWidget {
  final Severity severity;
  const StateMark(this.severity, {super.key});

  @override
  Widget build(BuildContext context) {
    if (severity == Severity.ok) return Icon(Icons.check_circle, size: 15, color: severityColor(context, Severity.ok));
    final c = severityColor(context, severity);
    final hollow = severity == Severity.neutral || severity == Severity.info;
    return Container(width: 9, height: 9, decoration: BoxDecoration(color: hollow ? null : c, shape: BoxShape.circle, border: Border.all(color: c, width: 1.5)));
  }
}

/// A small outlined chip beside a headline ("Cordoned").
class HeadlineChip extends StatelessWidget {
  final String text;
  final Severity severity;
  final String? tooltip;
  const HeadlineChip(this.text, {super.key, this.severity = Severity.warn, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final c = severityColor(context, severity);
    final chip = Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(border: Border.all(color: c.withValues(alpha: c.a * 0.7)), borderRadius: BorderRadius.circular(4)),
      child: Text(text, maxLines: 1, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: c, fontWeight: FontWeight.w600)),
    );
    return tooltip == null ? chip : Tooltip(message: tooltip!, child: chip);
  }
}

/// Large light numerals over small captions, divided by hairlines; colour
/// only when the number is a problem. Breaks into rows when narrow.
class FigureStrip extends StatelessWidget {
  final List<HeaderFigure> figures;
  const FigureStrip(this.figures, {super.key});

  @override
  Widget build(BuildContext context) {
    final separator = AppColors.of(context).separator;
    return LayoutBuilder(builder: (context, box) {
      final perRow = (box.maxWidth / 66).floor().clamp(1, figures.length);
      final rows = <List<HeaderFigure>>[for (var i = 0; i < figures.length; i += perRow) figures.sublist(i, (i + perRow).clamp(0, figures.length))];
      final width = (box.maxWidth / perRow).clamp(60.0, 112.0);
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (r, row) in rows.indexed)
          Padding(
            padding: EdgeInsets.only(top: r == 0 ? 0 : 10),
            child: IntrinsicHeight(
              child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (var i = 0; i < row.length; i++)
                  Container(
                    width: width,
                    padding: EdgeInsets.only(left: i == 0 ? 0 : 12, right: 6),
                    decoration: i == 0 ? null : BoxDecoration(border: Border(left: BorderSide(color: separator))),
                    child: _cell(context, row[i]),
                  ),
              ]),
            ),
          ),
      ]);
    });
  }

  Widget _cell(BuildContext context, HeaderFigure f) {
    final theme = Theme.of(context);
    final bad = f.severity == Severity.error || f.severity == Severity.warn;
    final big = theme.textTheme.headlineSmall?.copyWith(
      fontSize: 24,
      height: 1.1,
      fontWeight: FontWeight.w300,
      letterSpacing: -0.4,
      fontFeatures: _tabular,
      color: bad ? severityColor(context, f.severity) : theme.colorScheme.onSurface,
    );
    final Widget number = f.since != null
        ? AgeText(f.since, style: big)
        : Text.rich(
            TextSpan(children: [
              TextSpan(text: f.value, style: big),
              if (f.of != null) TextSpan(text: f.of, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w400, color: theme.hintColor, fontFeatures: _tabular)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
    final cell = Column(key: f.key, crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      SizedBox(height: 28, child: Align(alignment: Alignment.centerLeft, child: number)),
      const SizedBox(height: 1),
      Text(f.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
    ]);
    return f.tooltip == null ? cell : Tooltip(message: f.tooltip!, child: cell);
  }
}

// ---------------------------------------------------------------------------
// Compact rows
// ---------------------------------------------------------------------------

/// A small dot: filled in the severity's colour, hollow grey when neutral.
class StateDot extends StatelessWidget {
  final Severity severity;
  final String? tooltip;
  const StateDot(this.severity, {super.key, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final hollow = severity == Severity.neutral;
    final c = severityColor(context, severity);
    final dot = Container(
      width: 7,
      height: 7,
      decoration: BoxDecoration(shape: BoxShape.circle, color: hollow ? null : c, border: hollow ? Border.all(color: c, width: 1.2) : null),
    );
    return tooltip == null ? dot : Tooltip(message: tooltip!, child: dot);
  }
}

/// One child as a compact row: a state dot, a title over a quiet subtitle,
/// [trailing] (always shown), [actions] (on hover, or while open or a
/// problem) and, when [details] is given, a chevron that opens them. The
/// open state is remembered for the session per [memoryId].
class CompactRow extends StatefulWidget {
  final Severity severity;
  final String? dotTooltip;
  final Widget title;
  final Widget? subtitle;
  final List<Widget> trailing;
  final List<Widget> actions;
  final Widget? details;
  final String? memoryId;

  /// Default open state (problems start open).
  final bool initiallyOpen;
  const CompactRow({
    super.key,
    required this.severity,
    required this.title,
    this.dotTooltip,
    this.subtitle,
    this.trailing = const [],
    this.actions = const [],
    this.details,
    this.memoryId,
    this.initiallyOpen = false,
  });

  bool get isProblem => severity == Severity.error || severity == Severity.warn;

  @override
  State<CompactRow> createState() => _CompactRowState();
}

class _CompactRowState extends State<CompactRow> {
  late bool _open = widget.memoryId == null ? widget.initiallyOpen : PodSectionMemory.isOpen(widget.memoryId!, fallback: widget.initiallyOpen);

  void _toggle() {
    setState(() => _open = !_open);
    if (widget.memoryId != null) PodSectionMemory.set(widget.memoryId!, _open);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final expandable = widget.details != null;
    return Hoverable(
      cursor: expandable ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onTap: expandable ? _toggle : null,
      builder: (hovered) {
        final showActions = hovered || _open || widget.isProblem;
        return Container(
          decoration: BoxDecoration(color: hovered && !_open ? colors.hover : null, borderRadius: BorderRadius.circular(5)),
          padding: const EdgeInsets.fromLTRB(4, 6, 2, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 5), child: StateDot(widget.severity, tooltip: widget.dotTooltip)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  DefaultTextStyle.merge(style: theme.textTheme.bodySmall?.copyWith(fontSize: 12.5, color: theme.colorScheme.onSurface), maxLines: 1, overflow: TextOverflow.ellipsis, child: widget.title),
                  if (widget.subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: DefaultTextStyle.merge(style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor), child: widget.subtitle!),
                    ),
                ]),
              ),
              for (final t in widget.trailing) Padding(padding: const EdgeInsets.only(left: 8, top: 1), child: t),
              if (widget.actions.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [for (final a in widget.actions) RevealOnHover(visible: showActions, child: a)]),
                ),
              if (expandable)
                Padding(
                  padding: const EdgeInsets.only(top: 1, left: 2),
                  child: AnimatedRotation(
                    turns: _open ? 0.25 : 0,
                    duration: const Duration(milliseconds: 120),
                    child: Icon(Icons.chevron_right, size: 16, color: hovered || _open ? theme.hintColor : theme.hintColor.withValues(alpha: theme.hintColor.a * 0.5)),
                  ),
                ),
            ]),
            if (_open && expandable)
              // Taps inside the details (links, copy, selection) must not
              // collapse the row.
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {},
                child: MouseRegion(
                  cursor: SystemMouseCursors.basic,
                  child: Padding(padding: const EdgeInsets.fromLTRB(15, 10, 6, 4), child: widget.details!),
                ),
              ),
          ]),
        );
      },
    );
  }
}

/// Always laid out (no jump on hover) but only visible when [visible], or
/// when the child grows wider than an icon (a live port-forward's
/// `localhost:N` link stays visible).
class RevealOnHover extends StatefulWidget {
  final bool visible;
  final Widget child;
  const RevealOnHover({super.key, required this.visible, required this.child});

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
        ignoring: !(widget.visible || _wide),
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

/// A small icon button for a row's hover actions.
class RowAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
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
          decoration: BoxDecoration(color: h ? accent.withValues(alpha: 0.12) : null, borderRadius: BorderRadius.circular(4)),
          child: Icon(icon, size: 14, color: h ? accent : theme.hintColor),
        ),
      ),
    );
  }
}

/// Copies [value]; a [RowAction].
RowAction copyAction(BuildContext context, String value, {String? tooltip}) =>
    RowAction(icon: Icons.copy, tooltip: tooltip ?? 'Copy $value', onTap: () => copyToClipboard(context, value));

/// A quiet group: a small uppercase label in the hint colour over its rows.
class QuietGroup extends StatelessWidget {
  final String label;
  final List<Widget> children;
  final double gap;
  const QuietGroup(this.label, this.children, {super.key, this.gap = 4});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text(label.toUpperCase(), style: theme.textTheme.bodySmall?.copyWith(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.7, color: theme.hintColor)),
        for (final (i, w) in children.indexed) Padding(padding: EdgeInsets.only(top: i == 0 ? 5 : gap), child: w),
      ]),
    );
  }
}

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

/// Rows with only the first 4 shown (and "Show N more") when there are
/// more than [limit].
class TrimmedRows extends StatefulWidget {
  final List<Widget> children;
  final int limit;

  /// Rows shown while trimmed.
  final int keep;
  const TrimmedRows(this.children, {super.key, this.limit = 6, this.keep = 4});

  @override
  State<TrimmedRows> createState() => _TrimmedRowsState();
}

class _TrimmedRowsState extends State<TrimmedRows> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final total = widget.children.length;
    final trims = total > widget.limit;
    final shown = trims && !_all ? widget.keep : total;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...widget.children.take(shown),
      if (trims)
        Align(
          alignment: Alignment.centerLeft,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 0, 0),
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

/// Dim one-line text for a row's subtitle, parts joined by " · ".
Widget dotLine(List<String> parts) => Text(parts.where((p) => p.isNotEmpty).join(' · '), maxLines: 1, overflow: TextOverflow.ellipsis);

// ---------------------------------------------------------------------------
// Pods
// ---------------------------------------------------------------------------

/// A pod's severity for a row: green when running and ready, grey when
/// done, amber while starting or restarting, red when failing.
Severity podRowSeverity(Json pod) {
  final status = podKubectlStatus(pod);
  if (status == 'Succeeded' || status == 'Completed') return Severity.neutral;
  if (!podHasProblem(pod)) return Severity.ok;
  return status == 'Pending' || status == 'ContainerCreating' || status == 'Terminating' || (status == 'Running' && podReady(pod)) ? Severity.warn : Severity.error;
}

/// Pods ordered problems first, then by namespace and name.
List<Json> problemsFirst(Iterable<Json> pods) {
  int rank(Json p) => switch (podRowSeverity(p)) { Severity.error => 0, Severity.warn => 1, Severity.ok => 2, _ => 3 };
  return [...pods]..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      final ns = '${dig(a, ['metadata', 'namespace'])}'.compareTo('${dig(b, ['metadata', 'namespace'])}');
      return ns != 0 ? ns : '${dig(a, ['metadata', 'name'])}'.compareTo('${dig(b, ['metadata', 'name'])}');
    });
}

/// A pod as a compact row: dot, linked name, status (coloured when wrong),
/// namespace and restarts; [trailing] on the right (an IP, requests).
class PodLinkRow extends StatelessWidget {
  final Json pod;
  final bool showNamespace;
  final List<Widget> trailing;
  final List<String> extra;
  const PodLinkRow(this.pod, {super.key, this.showNamespace = false, this.trailing = const [], this.extra = const []});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = '${dig(pod, ['metadata', 'name'])}';
    final ns = dig<String>(pod, ['metadata', 'namespace']);
    final sev = podRowSeverity(pod);
    final status = podKubectlStatus(pod);
    final restarts = podRestarts(pod);
    final bad = sev == Severity.error || sev == Severity.warn;
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return CompactRow(
      key: ValueKey('pod-row-$ns/$name'),
      severity: sev,
      dotTooltip: status,
      title: ResourceLink(ObjectRef(kind: 'Pod', name: name, namespace: ns), label: name, singleLine: true),
      subtitle: Text.rich(
        TextSpan(style: hint, children: [
          TextSpan(text: status, style: bad ? TextStyle(color: severityColor(context, sev), fontWeight: FontWeight.w600) : null),
          if (showNamespace && ns != null) TextSpan(text: ' · $ns'),
          if (restarts > 0) TextSpan(text: ' · ${restarts == 1 ? '1 restart' : '$restarts restarts'}', style: restarts >= 5 ? TextStyle(color: severityColor(context, Severity.warn)) : null),
          for (final e in extra) TextSpan(text: ' · $e'),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing,
    );
  }
}

/// Active pods (problems first, trimmed) with a quiet note for the
/// completed or failed ones left out.
class PodRows extends StatelessWidget {
  final List<Json> pods;
  final bool showNamespace;
  final String empty;
  final List<Widget> Function(Json pod)? trailing;
  final bool hideTerminal;
  const PodRows(this.pods, {super.key, this.showNamespace = false, this.empty = 'No pods', this.trailing, this.hideTerminal = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = hideTerminal ? pods.where((p) => !isTerminalPod(p)).toList() : pods;
    final hidden = pods.length - shown.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (shown.isEmpty)
        Padding(padding: const EdgeInsets.only(left: 4), child: Text(empty, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)))
      else
        TrimmedRows([for (final p in problemsFirst(shown)) PodLinkRow(p, showNamespace: showNamespace, trailing: trailing?.call(p) ?? const [])], limit: 12, keep: 8),
      if (hidden > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 0, 0),
          child: Text('$hidden completed/failed pods not shown', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ),
    ]);
  }
}
