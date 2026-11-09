import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart' show HairlineBar, SkeletonBar, tabularFigures;
import 'insights.dart';

/// One large figure of an [InspectorHeader]: "2" "/3" over "ready".
class InspectorFigure {
  /// Null while loading (a placeholder stands in).
  final String? value;

  /// Small after the value ("/5", "KiB").
  final String? of;
  final String label;

  /// Warn or error colour the value; anything else leaves it plain.
  final Severity severity;
  final String? tooltip;

  /// For [InspectorFigure.age]: the time the age counts from.
  final dynamic since;
  const InspectorFigure(this.value, this.label, {this.of, this.severity = Severity.neutral, this.tooltip}) : since = null;

  /// The time since [since] ("6d"), ticking, e.g. "up" or "last seen".
  const InspectorFigure.age(this.since, this.label)
      : value = '',
        of = null,
        severity = Severity.neutral,
        tooltip = null;

  /// "[n]/[total] [label]", amber when short (red at zero when [zeroIsError]).
  factory InspectorFigure.count(int n, int total, String label, {bool zeroIsError = false, String? tooltip}) => InspectorFigure(
        '$n',
        label,
        of: '/$total',
        severity: n >= total ? Severity.neutral : (n == 0 && zeroIsError ? Severity.error : Severity.warn),
        tooltip: tooltip,
      );
}

/// A rollout's progress under the headline: [frac] of the way.
class InspectorProgress {
  final double frac;
  final String? tooltip;
  const InspectorProgress(this.frac, {this.tooltip});
}

/// The top of an inspector: is it OK, and if not, why? A [headline] with a
/// [mark] (and small [chips] beside it), a quiet [detail] line (a string or
/// a widget), an optional [progress] bar, a row of large [figures], the
/// [insights] explaining a problem (plus [extraInsights], e.g. ones that
/// load), [actions], then [facts] as caption/value pairs (rows with a null
/// value are left out) and an optional [footer].
class InspectorHeader extends StatelessWidget {
  final Severity? mark;
  final String? headline;

  /// Colours the headline (e.g. red for a failed Job); null: plain.
  final Severity? headlineTone;

  /// A `String` or a `Widget`.
  final Object? detail;
  final List<Widget> chips;
  final InspectorProgress? progress;
  final List<InspectorFigure> figures;
  final List<Insight> insights;
  final List<Widget> extraInsights;
  final List<Widget> actions;
  final List<(String, Object?)> facts;
  final double factsKeyWidth;
  final Widget? footer;

  /// The headline's key (default `inspector-headline`).
  final Key? headlineKey;
  const InspectorHeader({
    super.key,
    this.mark,
    this.headline,
    this.headlineTone,
    this.detail,
    this.chips = const [],
    this.progress,
    this.figures = const [],
    this.insights = const [],
    this.extraInsights = const [],
    this.actions = const [],
    this.facts = const [],
    this.factsKeyWidth = 72,
    this.footer,
    this.headlineKey,
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
    final visibleFacts = [for (final f in facts) if (f.$2 != null) f];
    final detail = switch (this.detail) {
      final String s when s.isEmpty => null,
      final String s => Text(s),
      final Widget w => w,
      _ => null,
    };
    final top = <Widget>[
      if (headline != null)
        Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
          if (mark != null) SizedBox(width: 20, child: Align(alignment: Alignment.centerLeft, child: HeaderMark(mark!))),
          Flexible(child: Text(headline!, key: headlineKey ?? const ValueKey('inspector-headline'), maxLines: 2, overflow: TextOverflow.ellipsis, style: title)),
          for (final c in chips) ...[const SizedBox(width: 8), c],
        ]),
      if (detail != null)
        Padding(
          key: const ValueKey('inspector-detail'),
          padding: EdgeInsets.only(left: indent, top: headline == null ? 0 : 2),
          child: DefaultTextStyle.merge(style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor, fontSize: 12.5), child: detail),
        ),
      if (progress != null)
        Padding(
          padding: EdgeInsets.only(left: indent, top: 8),
          child: Tooltip(
            message: progress!.tooltip ?? '',
            child: SizedBox(width: 160, child: HairlineBar(frac: progress!.frac.clamp(0.0, 1.0), color: theme.colorScheme.primary, height: 3)),
          ),
        ),
    ];
    // Each block with the space above it. Extra insights may draw nothing
    // (one that loads and has nothing to say), so they bring their own
    // space and never add a block of their own.
    final blocks = <(double, Widget)>[
      if (top.isNotEmpty) (0, Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: top)),
      if (headline == null && chips.isNotEmpty) (14, Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: chips)),
      if (figures.isNotEmpty) (14, FigureRow(figures)),
      if (insights.isNotEmpty) (14, InsightList(insights)),
    ];
    if (extraInsights.isNotEmpty) {
      final (gap, last) = blocks.isEmpty ? (0.0, const SizedBox.shrink()) : blocks.removeLast();
      blocks.add((
        gap,
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          last,
          for (final (i, w) in extraInsights.indexed) _GapIfShown(gap: i == 0 && insights.isEmpty ? 14 : 10, child: w),
        ]),
      ));
    }
    blocks.addAll([
      if (actions.isNotEmpty) (14, Wrap(spacing: 8, runSpacing: 6, children: actions)),
      if (visibleFacts.isNotEmpty) (14, KeyValueTable(visibleFacts, keyWidth: factsKeyWidth)),
      if (footer != null) (14, footer!),
    ]);
    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (i, (gap, b)) in blocks.indexed) ...[if (i > 0) SizedBox(height: gap), b],
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
    // The same footprint as the check (a 15px icon whose circle is ~12.5px).
    return SizedBox(
      width: 15,
      height: 15,
      child: Center(
        child: Container(
          width: 12.5,
          height: 12.5,
          decoration: BoxDecoration(color: hollow ? null : c, shape: BoxShape.circle, border: Border.all(color: c, width: 1.5)),
        ),
      ),
    );
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
/// only when the number is a problem. Each cell is as wide as its figure
/// needs; more than fit go onto another row. Cells are keyed
/// `figure-<label>`.
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

    final text = f.since != null ? formatAge(parseTime(f.since)) : f.value;
    final value = text == null ? 32.0 : measure(text, _bigStyle(theme)) + (f.of == null ? 0 : measure(f.of!, _ofStyle(theme)));
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
                  key: ValueKey('figure-${figures[i].label}'),
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
  /// 104 (never wider than the line).
  static double _width(List<double> natural, List<int> row, int i, double max) {
    final sum = row.fold<double>(0, (a, k) => a + natural[k]);
    final extra = ((max - sum) / row.length).clamp(0.0, double.infinity);
    final cap = natural[i] > 104 ? natural[i] : 104.0;
    return (natural[i] + extra).clamp(0.0, cap).clamp(0.0, max);
  }

  Widget _cell(BuildContext context, ThemeData theme, InspectorFigure f) {
    final bad = f.severity == Severity.error || f.severity == Severity.warn;
    final big = _bigStyle(theme)?.copyWith(color: bad ? severityColor(context, f.severity) : theme.colorScheme.onSurface);
    final Widget number = f.since != null
        ? AgeText(f.since, style: big)
        : f.value == null
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
      Text(f.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
    ]);
    return f.tooltip == null ? cell : Tooltip(message: f.tooltip!, child: cell);
  }
}

/// [child] with [gap] above it, or nothing at all while [child] is empty
/// (so an extra insight that has nothing to say leaves no space).
class _GapIfShown extends SingleChildRenderObjectWidget {
  final double gap;
  const _GapIfShown({required this.gap, super.child});

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderGapIfShown(gap);

  @override
  void updateRenderObject(BuildContext context, _RenderGapIfShown renderObject) => renderObject.gap = gap;
}

class _RenderGapIfShown extends RenderShiftedBox {
  _RenderGapIfShown(this._gap) : super(null);
  double _gap;
  set gap(double v) {
    if (v == _gap) return;
    _gap = v;
    markNeedsLayout();
  }

  @override
  void performLayout() {
    final c = child;
    if (c == null) {
      size = constraints.smallest;
      return;
    }
    c.layout(constraints.loosen().copyWith(maxHeight: double.infinity), parentUsesSize: true);
    final shown = c.size.height > 0;
    (c.parentData! as BoxParentData).offset = Offset(0, shown ? _gap : 0);
    size = constraints.constrain(Size(c.size.width, shown ? c.size.height + _gap : 0));
  }
}
