/// The top of a workload inspector, in the pod inspector's style: is it OK,
/// and if not, why? A headline with a mark, an optional progress bar, large
/// figures with small captions divided by hairlines (colour only when
/// wrong), insights marked by a severity bar, then a few key facts.
library;

import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets/common.dart';
import '../../../ui/widgets/editorial.dart' show HairlineBar, tabularFigures;
import '../../../util/k8s.dart';
import 'util.dart';

/// One large figure: "2" "/3" over "ready".
class WorkloadFigure {
  final String value;
  final String? of;
  final String label;
  final Severity severity;
  final String? tooltip;
  const WorkloadFigure(this.value, this.label, {this.of, this.severity = Severity.neutral, this.tooltip});

  /// "[n]/[total] [label]", amber when short (red at zero when [zeroIsError]).
  factory WorkloadFigure.count(int n, int total, String label, {bool zeroIsError = false, String? tooltip}) => WorkloadFigure(
        '$n',
        label,
        of: '/$total',
        severity: n >= total ? Severity.neutral : (n == 0 && zeroIsError ? Severity.error : Severity.warn),
        tooltip: tooltip,
      );
}

/// A line under the headline explaining a problem (or a notable state):
/// a short bar in its severity colour, the text, a quieter detail and an
/// optional action under them.
class WorkloadInsight {
  final Severity severity;
  final String text;
  final String? detail;

  /// Replaces [text] (e.g. a line with a link in it).
  final Widget? title;
  final Widget? action;
  const WorkloadInsight(this.severity, this.text, {this.detail, this.title, this.action});
}

/// A rollout's progress: [frac] of the way, captioned by the headline.
class WorkloadProgress {
  final double frac;
  final String? tooltip;
  const WorkloadProgress(this.frac, {this.tooltip});
}

class WorkloadStatusHeader extends StatelessWidget {
  final String headline;
  final Severity severity;
  final String? detail;
  final WorkloadProgress? progress;
  final List<WorkloadFigure> figures;
  final List<WorkloadInsight> insights;

  /// Further lines in the insights' place that load on their own (e.g.
  /// the HPA note); they draw nothing when there is nothing to say.
  final List<Widget> extraInsights;
  final List<(String, Object?)> facts;
  const WorkloadStatusHeader({
    super.key,
    required this.headline,
    required this.severity,
    this.detail,
    this.progress,
    this.figures = const [],
    this.insights = const [],
    this.extraInsights = const [],
    this.facts = const [],
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor, fontSize: 12.5);
    final title = theme.textTheme.titleLarge?.copyWith(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.2, height: 1.2);
    final visibleFacts = facts.where((f) => f.$2 != null).toList();
    return Padding(
      key: const ValueKey('workload-status'),
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          SizedBox(width: 20, child: Align(alignment: Alignment.centerLeft, child: _mark(context, severity))),
          Flexible(child: Text(headline, key: const ValueKey('workload-status-headline'), maxLines: 1, overflow: TextOverflow.ellipsis, style: title)),
        ]),
        if (detail != null && detail!.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 20, top: 2), child: Text(detail!, style: hint)),
        if (progress != null)
          Padding(
            padding: const EdgeInsets.only(left: 20, top: 8),
            child: Tooltip(
              message: progress!.tooltip ?? '',
              child: SizedBox(width: 160, child: HairlineBar(frac: progress!.frac.clamp(0.0, 1.0), color: theme.colorScheme.primary, height: 3)),
            ),
          ),
        if (figures.isNotEmpty) ...[const SizedBox(height: 14), _FigureRow(figures)],
        if (insights.isNotEmpty) ...[const SizedBox(height: 14), _Insights(insights)],
        for (final w in extraInsights) w,
        if (visibleFacts.isNotEmpty) ...[const SizedBox(height: 14), KeyValueTable(keyWidth: 72, visibleFacts)],
      ]),
    );
  }

  /// A check when healthy, else a dot in the severity (hollow for neutral).
  static Widget _mark(BuildContext context, Severity s) {
    if (s == Severity.ok) return Icon(Icons.check_circle, size: 15, color: severityColor(context, Severity.ok));
    final c = severityColor(context, s);
    return Container(width: 9, height: 9, decoration: BoxDecoration(color: s == Severity.neutral ? null : c, shape: BoxShape.circle, border: Border.all(color: c, width: 1.5)));
  }
}

/// Large light numerals over small captions, divided by hairlines.
class _FigureRow extends StatelessWidget {
  final List<WorkloadFigure> figures;
  const _FigureRow(this.figures);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final separator = AppColors.of(context).separator;
    return LayoutBuilder(builder: (context, box) {
      final width = (box.maxWidth / figures.length).clamp(60.0, 104.0);
      return IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < figures.length; i++)
            Container(
              key: ValueKey('workload-figure-${figures[i].label}'),
              width: width,
              padding: EdgeInsets.only(left: i == 0 ? 0 : 12, right: 6),
              decoration: i == 0 ? null : BoxDecoration(border: Border(left: BorderSide(color: separator))),
              child: _cell(context, theme, figures[i]),
            ),
        ]),
      );
    });
  }

  Widget _cell(BuildContext context, ThemeData theme, WorkloadFigure f) {
    final bad = f.severity == Severity.error || f.severity == Severity.warn;
    final big = theme.textTheme.headlineSmall?.copyWith(
      fontSize: 24,
      height: 1.1,
      fontWeight: FontWeight.w300,
      letterSpacing: -0.4,
      fontFeatures: tabularFigures,
      color: bad ? severityColor(context, f.severity) : theme.colorScheme.onSurface,
    );
    final cell = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      SizedBox(
        height: 28,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: f.value, style: big),
              if (f.of != null) TextSpan(text: f.of, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w400, color: theme.hintColor, fontFeatures: tabularFigures)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
      const SizedBox(height: 1),
      Text(f.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
    ]);
    return f.tooltip == null ? cell : Tooltip(message: f.tooltip!, child: cell);
  }
}

class _Insights extends StatelessWidget {
  final List<WorkloadInsight> insights;
  const _Insights(this.insights);

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final (n, i) in insights.indexed) Padding(padding: EdgeInsets.only(top: n == 0 ? 0 : 10), child: InsightRow(i)),
      ]);
}

/// One [WorkloadInsight]: the severity bar beside its text, detail and
/// action.
class InsightRow extends StatelessWidget {
  final WorkloadInsight insight;
  const InsightRow(this.insight, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final i = insight;
    final strong = theme.textTheme.bodySmall?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600, color: theme.colorScheme.onSurface, height: 1.3);
    return IntrinsicHeight(
      child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Container(
          width: 2.5,
          margin: const EdgeInsets.only(top: 2, bottom: 2, right: 10),
          decoration: BoxDecoration(color: severityColor(context, i.severity), borderRadius: BorderRadius.circular(2)),
        ),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            i.title == null ? Text(i.text, style: strong) : DefaultTextStyle.merge(style: strong, child: i.title!),
            if (i.detail != null && i.detail!.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Text(i.detail!, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35)),
              ),
            if (i.action != null) Padding(padding: const EdgeInsets.only(top: 6), child: CompactButtons(child: i.action!)),
          ]),
        ),
      ]),
    );
  }
}

/// Conditions that are bad when True rather than when False.
const badWhenTrue = {'ReplicaFailure', 'ScalingLimited'};

/// Whether condition [c] says something is wrong.
bool conditionIsBad(Json c) => badWhenTrue.contains(c['type']) ? c['status'] == 'True' : c['status'] != 'True';

/// An insight per condition that is wrong (False, or True for
/// [badWhenTrue]): "Available: MinimumReplicasUnavailable" over its
/// message. A missed progress deadline, replica failures and the types in
/// [errors] are errors; the rest warnings.
List<WorkloadInsight> conditionInsights(List<Json> conditions, {Set<String> skip = const {}, Set<String> errors = const {}}) => [
      for (final c in conditions)
        if (!skip.contains(c['type']) && conditionIsBad(c))
          WorkloadInsight(
            c['type'] == 'ReplicaFailure' || errors.contains(c['type']) || c['reason'] == 'ProgressDeadlineExceeded' ? Severity.error : Severity.warn,
            [c['type'], c['reason']].whereType<String>().join(': '),
            detail: c['message'] as String?,
          ),
    ];

/// The scale stepper as a fact; shrinks rather than overflowing when its
/// apply/reset buttons show in a narrow inspector.
/// Its buttons overhang the 18px row (centred on the label's line) and
/// the minus sits under the other values' left edge.
Widget scaleFact(Widget control) => SizedBox(
      height: 18,
      child: OverflowBox(
        alignment: Alignment.centerLeft,
        minHeight: 0,
        maxHeight: 48,
        child: Transform.translate(
          offset: const Offset(-8, 0),
          child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: control),
        ),
      ),
    );
