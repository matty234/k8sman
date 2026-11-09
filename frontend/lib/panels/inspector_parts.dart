/// The pod inspector's organisation for other kinds: a status header (a
/// headline with a mark, large figures over small captions, insights, a few
/// key facts), children as compact rows that open on demand, and quiet
/// labelled groups inside them. Sections are the pod's [PodSection]; the
/// insight list is the pod's [InsightList].
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../ui/widgets/editorial.dart' show SkeletonBar, tabularFigures;
import '../util/k8s.dart';
import 'pod/pod_logic.dart' show PodInsight;
import 'pod/pod_section.dart';
import 'pod/pod_widgets.dart' show InsightList;

export 'pod/pod_logic.dart' show PodInsight;
export 'pod/pod_section.dart' show PodSection, PodSectionMemory, SectionSummary;

// ---------------------------------------------------------------------------
// Status header
// ---------------------------------------------------------------------------

/// One large figure of an [InspectorHeader].
class InspectorFigure {
  /// Null while loading (a placeholder stands in).
  final String? value;

  /// Small after the value ("/5", "KiB").
  final String? of;
  final String label;

  /// Warn or error colour the value; anything else leaves it plain.
  final Severity severity;
  final String? tooltip;
  const InspectorFigure(this.value, this.label, {this.of, this.severity = Severity.neutral, this.tooltip});
}

/// The top of an inspector: is it OK, and if not, why? A [headline] with a
/// [mark], an optional quiet [detail] under it, [chips] (e.g. "immutable"),
/// a row of large [figures], the [insights] explaining a problem (plus
/// [extraInsights], e.g. ones that load), [actions], and [facts] as
/// caption/value pairs.
class InspectorHeader extends StatelessWidget {
  final Severity? mark;
  final String? headline;

  /// Colours the headline (e.g. red for a failed Job); null: plain.
  final Severity? headlineTone;
  final Widget? detail;
  final List<Widget> chips;
  final List<InspectorFigure> figures;
  final List<PodInsight> insights;
  final List<Widget> extraInsights;
  final List<Widget> actions;
  final List<(String, Object?)> facts;
  final double factsKeyWidth;
  const InspectorHeader({
    super.key,
    this.mark,
    this.headline,
    this.headlineTone,
    this.detail,
    this.chips = const [],
    this.figures = const [],
    this.insights = const [],
    this.extraInsights = const [],
    this.actions = const [],
    this.facts = const [],
    this.factsKeyWidth = 72,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = theme.textTheme.titleLarge?.copyWith(
      fontSize: 18,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
      height: 1.2,
      color: headlineTone == null ? null : severityColor(context, headlineTone!),
    );
    final indent = mark == null ? 0.0 : 20.0;
    final blocks = <Widget>[
      if (headline != null)
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          if (mark != null) SizedBox(width: 20, child: Align(alignment: Alignment.centerLeft, child: HeaderMark(mark!))),
          Flexible(child: Text(headline!, key: const ValueKey('inspector-headline'), maxLines: 2, overflow: TextOverflow.ellipsis, style: title)),
        ]),
      if (detail != null)
        Padding(
          padding: EdgeInsets.only(left: indent, top: headline == null ? 0 : 2),
          child: DefaultTextStyle.merge(style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor, fontSize: 12.5), child: detail!),
        ),
      if (chips.isNotEmpty) Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: chips),
      if (figures.isNotEmpty) FigureRow(figures),
      if (insights.isNotEmpty || extraInsights.isNotEmpty)
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (insights.isNotEmpty) InsightList(insights),
          for (final (i, w) in extraInsights.indexed) Padding(padding: EdgeInsets.only(top: i == 0 && insights.isEmpty ? 0 : 10), child: w),
        ]),
      if (actions.isNotEmpty) Wrap(spacing: 8, runSpacing: 6, children: actions),
      if (facts.isNotEmpty) KeyValueTable(facts, keyWidth: factsKeyWidth),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, b) in blocks.indexed) ...[
          // The detail hugs the headline; everything else breathes.
          if (i > 0 && !(i == 1 && headline != null && detail != null)) const SizedBox(height: 14),
          b,
        ],
      ]),
    );
  }
}

/// The headline mark: a check when ok, a hollow ring for neutral/info, a
/// dot in the severity colour otherwise.
class HeaderMark extends StatelessWidget {
  final Severity severity;
  const HeaderMark(this.severity, {super.key});

  @override
  Widget build(BuildContext context) {
    if (severity == Severity.ok) return Icon(Icons.check_circle, size: 15, color: severityColor(context, Severity.ok));
    final hollow = severity == Severity.neutral || severity == Severity.info;
    final c = hollow ? Theme.of(context).hintColor : severityColor(context, severity);
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(color: hollow ? null : c, shape: BoxShape.circle, border: Border.all(color: c, width: 1.5)),
    );
  }
}

/// Large light numerals over small captions, divided by hairlines; colour
/// only when the number is a problem. More than fit go onto a second row.
class FigureRow extends StatelessWidget {
  final List<InspectorFigure> figures;
  const FigureRow(this.figures, {super.key});

  static TextStyle? _bigStyle(ThemeData theme) => theme.textTheme.headlineSmall?.copyWith(
        fontSize: 24,
        height: 1.1,
        fontWeight: FontWeight.w300,
        letterSpacing: -0.4,
        fontFeatures: tabularFigures,
      );

  static TextStyle? _ofStyle(ThemeData theme) =>
      theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w400, color: theme.hintColor, fontFeatures: tabularFigures);

  /// How wide [f]'s value (and a short label) want to be.
  static double _natural(BuildContext context, ThemeData theme, InspectorFigure f) {
    final scaler = MediaQuery.textScalerOf(context);
    double measure(String text, TextStyle? style) {
      final p = TextPainter(text: TextSpan(text: text, style: style), textDirection: TextDirection.ltr, textScaler: scaler, maxLines: 1)..layout();
      final w = p.width;
      p.dispose();
      return w;
    }

    final value = f.value == null ? 32.0 : measure(f.value!, _bigStyle(theme)) + (f.of == null ? 0 : measure(f.of!, _ofStyle(theme)));
    final label = measure(f.label, theme.textTheme.bodySmall);
    return [value + 2, label.clamp(0.0, 64.0), 40.0].reduce((a, b) => a > b ? a : b);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final separator = AppColors.of(context).separator;
    const pad = 14.0; // 12 before a cell's content, 2 after
    return LayoutBuilder(builder: (context, box) {
      // Each cell is as wide as its figure needs, so "1m10s" isn't cut;
      // rows wrap when the figures don't fit side by side.
      final natural = [for (final f in figures) _natural(context, theme, f) + pad];
      final rows = <List<int>>[[]];
      var used = 0.0;
      for (var i = 0; i < figures.length; i++) {
        if (rows.last.isNotEmpty && used + natural[i] > box.maxWidth) {
          rows.add([]);
          used = 0;
        }
        rows.last.add(i);
        used += natural[i];
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final (r, row) in rows.indexed) ...[
          if (r > 0) const SizedBox(height: 12),
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (j, i) in row.indexed)
                Container(
                  width: _width(natural, row, i, box.maxWidth),
                  padding: EdgeInsets.only(left: j == 0 ? 0 : 12, right: 2),
                  decoration: j == 0 ? null : BoxDecoration(border: Border(left: BorderSide(color: separator))),
                  child: _cell(context, theme, figures[i]),
                ),
            ]),
          ),
        ],
      ]);
    });
  }

  /// A cell's natural width plus an even share of the spare room, up to
  /// the pod header's 104 (never wider than the line).
  static double _width(List<double> natural, List<int> row, int i, double max) {
    final sum = row.fold<double>(0, (a, k) => a + natural[k]);
    final extra = ((max - sum) / row.length).clamp(0.0, double.infinity);
    final cap = natural[i] > 104 ? natural[i] : 104.0;
    return (natural[i] + extra).clamp(0.0, cap).clamp(0.0, max);
  }

  Widget _cell(BuildContext context, ThemeData theme, InspectorFigure f) {
    final bad = f.severity == Severity.error || f.severity == Severity.warn;
    final big = _bigStyle(theme)?.copyWith(color: bad ? severityColor(context, f.severity) : theme.colorScheme.onSurface);
    final Widget number = f.value == null
        ? const SkeletonBar(width: 32, height: 18)
        : Text.rich(
            TextSpan(children: [
              TextSpan(text: f.value, style: big),
              if (f.of != null) TextSpan(text: f.of, style: _ofStyle(theme)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
    final cell = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      SizedBox(height: 28, child: Align(alignment: Alignment.centerLeft, child: number)),
      const SizedBox(height: 1),
      Text(f.label, key: ValueKey('figure-${f.label}'), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
    ]);
    return f.tooltip == null ? cell : Tooltip(message: f.tooltip!, child: cell);
  }
}

/// One insight in the [InsightList] style (a short severity bar, a bold
/// line, a quieter detail), with an optional [child] under it (a link, a
/// button). For insights that load or carry a widget.
class InsightLine extends StatelessWidget {
  final Severity severity;
  final String text;
  final String? detail;
  final Widget? child;
  const InsightLine(this.severity, this.text, {super.key, this.detail, this.child});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          width: 2.5,
          margin: const EdgeInsets.only(top: 2, bottom: 2, right: 10),
          decoration: BoxDecoration(color: severityColor(context, severity), borderRadius: BorderRadius.circular(2)),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(text, style: theme.textTheme.bodySmall?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface, height: 1.3)),
            if (detail != null && detail!.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 3), child: Text(detail!, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35))),
            if (child != null) Padding(padding: const EdgeInsets.only(top: 4), child: child!),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Compact rows
// ---------------------------------------------------------------------------

/// A child as one compact row: a state dot, a title over a quiet subtitle,
/// small [meta] on the right, [actions] that show on hover (always when
/// [problem] or open), and a chevron when it has [details]. Click to open;
/// the open state is remembered per [memoryId] for the session. Problem
/// rows start open unless [initiallyExpanded] says otherwise.
class InspectorRow extends StatefulWidget {
  final String? memoryId;
  final Severity? dot;

  /// A small icon in place of the dot (e.g. a kind icon).
  final Widget? leading;
  final bool hollowDot;
  final String? dotTooltip;
  final Widget title;
  final Widget? subtitle;
  final List<Widget> meta;
  final List<Widget> actions;

  /// Shows [actions] without hovering (e.g. Reveal on a secret key).
  final bool actionsAlways;
  final bool problem;
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
    this.meta = const [],
    this.actions = const [],
    this.actionsAlways = false,
    this.problem = false,
    this.details,
    this.below,
    this.initiallyExpanded,
  });

  @override
  State<InspectorRow> createState() => _InspectorRowState();
}

class _InspectorRowState extends State<InspectorRow> {
  late bool _open = widget.memoryId == null
      ? (widget.initiallyExpanded ?? widget.problem)
      : PodSectionMemory.isOpen(widget.memoryId!, fallback: widget.initiallyExpanded ?? widget.problem);

  bool get _expandable => widget.details != null;

  double get _indent => widget.dot != null ? 15 : (widget.leading != null ? 18 : 0);

  void _toggle() {
    setState(() => _open = !_open);
    if (widget.memoryId != null) PodSectionMemory.set(widget.memoryId!, _open);
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final open = _open && _expandable;
    return Hoverable(
      onTap: _expandable ? _toggle : null,
      builder: (hovered) => Container(
        decoration: BoxDecoration(color: hovered && !open && _expandable ? colors.hover : null, borderRadius: BorderRadius.circular(5)),
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
    final showActions = widget.actionsAlways || hovered || widget.problem || open;
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
          widget.title,
          if (widget.subtitle != null) ...[
            const SizedBox(height: 2),
            DefaultTextStyle.merge(style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor), maxLines: 1, overflow: TextOverflow.ellipsis, child: widget.subtitle!),
          ],
        ]),
      ),
      for (final m in widget.meta) ...[
        const SizedBox(width: 8),
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: DefaultTextStyle.merge(style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontFeatures: tabularFigures), child: m),
        ),
      ],
      if (widget.actions.isNotEmpty) ...[
        const SizedBox(width: 4),
        IgnorePointer(
          ignoring: !showActions,
          child: AnimatedOpacity(
            opacity: showActions ? 1 : 0,
            duration: const Duration(milliseconds: 100),
            child: Row(mainAxisSize: MainAxisSize.min, children: widget.actions),
          ),
        ),
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

/// The small state dot of an [InspectorRow].
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

/// A quiet group inside a row's details: a small uppercase label in the
/// hint colour over its rows.
class DetailGroup extends StatelessWidget {
  final String label;
  final List<Widget> children;
  final double gap;
  const DetailGroup(this.label, this.children, {super.key, this.gap = 4});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text(label.toUpperCase(), style: theme.textTheme.bodySmall?.copyWith(fontSize: 10, fontWeight: FontWeight.w600, letterSpacing: 0.7, color: theme.hintColor)),
      for (final (i, w) in children.indexed) Padding(padding: EdgeInsets.only(top: i == 0 ? 5 : gap), child: w),
    ]);
  }
}

/// A list that shows its first [shown] items with "Show N more" when it has
/// more than [over].
class TrimmedList extends StatefulWidget {
  final List<Widget> children;
  final int over;
  final int shown;
  const TrimmedList(this.children, {super.key, this.over = 8, this.shown = 6});

  @override
  State<TrimmedList> createState() => _TrimmedListState();
}

class _TrimmedListState extends State<TrimmedList> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final total = widget.children.length;
    final trims = total > widget.over;
    final shown = trims && !_all ? widget.shown : total;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ...widget.children.take(shown),
      if (trims) ShowMoreLink(_all ? 'Show fewer' : 'Show ${total - shown} more', onTap: () => setState(() => _all = !_all)),
    ]);
  }
}

/// A quiet "Show N more" link.
class ShowMoreLink extends StatelessWidget {
  final String text;
  final VoidCallback onTap;
  const ShowMoreLink(this.text, {super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4, top: 4),
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

// ---------------------------------------------------------------------------
// Shared fetches
// ---------------------------------------------------------------------------

/// A small session cache so a header and a section can share one fetch
/// (e.g. the Used by report both count and list). Keys should include the
/// API client's identity and whatever should trigger a refetch; a failed
/// fetch is dropped so the next build retries.
class SharedFetch {
  SharedFetch._();
  // Each entry remembers the zone that fetched it: a future from another
  // zone (a finished widget test) never delivers here, so it's refetched.
  static final _cache = <String, (Zone, Future<Object?>)>{};

  /// Bumped by [invalidate], so listeners rebuild and fetch again.
  static final changes = ValueNotifier<int>(0);

  static Future<T> get<T>(String key, Future<T> Function() fetch) {
    final hit = _cache.remove(key);
    if (hit != null && identical(hit.$1, Zone.current)) {
      _cache[key] = hit;
      return hit.$2 as Future<T>;
    }
    final f = fetch();
    _cache[key] = (Zone.current, f);
    f.then((_) {}, onError: (Object _) {
      if (identical(_cache[key]?.$2, f)) _cache.remove(key);
    });
    while (_cache.length > 48) {
      _cache.remove(_cache.keys.first);
    }
    return f;
  }

  /// Drops every entry whose key starts with [prefix] and notifies.
  static void invalidate(String prefix) {
    _cache.removeWhere((k, _) => k.startsWith(prefix));
    changes.value++;
  }
}

/// Builds from a [SharedFetch] entry, rebuilding after an invalidation.
class SharedFetchBuilder<T> extends StatelessWidget {
  final String fetchKey;
  final Future<T> Function() fetch;
  final Widget Function(BuildContext context, AsyncSnapshot<T> snap) builder;
  const SharedFetchBuilder({super.key, required this.fetchKey, required this.fetch, required this.builder});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: SharedFetch.changes,
        builder: (context, _, _) => FutureBuilder<T>(future: SharedFetch.get<T>(fetchKey, fetch), builder: builder),
      );
}
