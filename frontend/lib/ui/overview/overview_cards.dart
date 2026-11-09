/// The Overview's summary blocks: the hero (status line and inventory
/// strip), cluster capacity, the "Needs attention" list per area and nodes.
/// Laid out open, with hairlines rather than boxes.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../metrics/metrics_api.dart' show Usage;
import '../../metrics/quantity.dart' show formatPercent;
import '../../metrics/widgets.dart' show meterColor, percentColor;
import '../../prometheus/prom_api.dart' show PromApi;
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../../modules/modules.dart' show enabledPages;
import 'capacity_history.dart';
import 'overview_api.dart';
import 'overview_nav.dart';
import 'overview_widgets.dart' show OverviewSection, SkeletonBar, issueColor, openObject;

const _tabular = [FontFeature.tabularFigures()];

/// Lays [children] out in rows of [cols] equal-width cells, each row as tall
/// as its tallest cell.
Widget _grid(List<Widget> children, int cols, {double gap = 10, double runGap = 10}) {
  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    for (var r = 0; r < children.length; r += cols) ...[
      if (r > 0) SizedBox(height: runGap),
      IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var c = 0; c < cols; c++) ...[
            if (c > 0) SizedBox(width: gap),
            Expanded(child: r + c < children.length ? children[r + c] : const SizedBox.shrink()),
          ],
        ]),
      ),
    ],
  ]);
}

/// A thin horizontal bar: [frac] of the track filled with [color], and
/// optionally [under] (e.g. requests behind usage) in a fainter tint.
class _Bar extends StatelessWidget {
  final double frac;
  final double? under;
  final Color color;
  final double height;
  const _Bar({required this.frac, required this.color, this.under, this.height = 3});

  @override
  Widget build(BuildContext context) {
    final track = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    Widget fill(double f, Color c) => FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: f.clamp(0.0, 1.0),
          child: DecoratedBox(decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(height))),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(fit: StackFit.expand, children: [
          ColoredBox(color: track),
          if (under != null) fill(under!, color.withValues(alpha: 0.35)),
          fill(frac, color),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Hero: one status line over the inventory strip
// ---------------------------------------------------------------------------

/// Problem totals behind the status line.
class _Tally {
  int critical = 0, warning = 0;
  final areas = <String>{};
  _Tally(OverviewData data) {
    for (final c in data.categories) {
      if (c.severity == IssueSeverity.info) continue;
      c.severity == IssueSeverity.critical ? critical += c.count : warning += c.count;
      areas.add(c.section);
    }
  }
  int get problems => critical + warning;
}

/// Never "All healthy" while a source is loading: its problems are unknown.
bool _allHealthy(OverviewData data) => data.loadingSections.isEmpty && _Tally(data).problems == 0;

/// The top of the page: how the cluster is ("All healthy", "Needs
/// attention · 13 critical · 17 warnings in 6 areas") over the inventory.
/// A faint wash of red sits behind it while anything is critical.
class OverviewHero extends StatelessWidget {
  final OverviewData data;
  final NamespaceScope scope;
  final DateTime? checkedAt;

  /// Horizontal inset of the content (the wash runs edge to edge).
  final double inset;
  const OverviewHero({super.key, required this.data, this.scope = NamespaceScope.all, this.checkedAt, this.inset = 24});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    final tally = _Tally(data);
    final crit = issueColor(context, IssueSeverity.critical);
    return Container(
      key: const ValueKey('overview-hero'),
      decoration: tally.critical == 0
          ? null
          : BoxDecoration(
              // A wide, low glow from the top left that has faded out
              // by the hero's bottom edge.
              gradient: RadialGradient(
                center: _washCenter,
                radius: 1.1,
                colors: [crit.withValues(alpha: dark ? 0.09 : 0.06), crit.withValues(alpha: 0)],
                transform: const _StretchX(4),
              ),
            ),
      padding: EdgeInsets.fromLTRB(inset, 22, inset, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _StatusLine(data: data, tally: tally, checkedAt: checkedAt),
        const SizedBox(height: 22),
        StatBlocks(data: data, scope: scope),
      ]),
    );
  }
}

const _washCenter = Alignment(-0.8, -1.2);

/// Widens a gradient horizontally about the wash's centre (a radial glow
/// into an ellipse).
class _StretchX extends GradientTransform {
  final double factor;
  const _StretchX(this.factor);

  @override
  Matrix4 transform(Rect bounds, {TextDirection? textDirection}) {
    final c = _washCenter.withinRect(bounds);
    return Matrix4.identity()
      ..translateByDouble(c.dx, c.dy, 0, 1)
      ..scaleByDouble(factor, 1, 1, 1)
      ..translateByDouble(-c.dx, -c.dy, 0, 1);
  }
}

class _StatusLine extends StatelessWidget {
  final OverviewData data;
  final _Tally tally;
  final DateTime? checkedAt;
  const _StatusLine({required this.data, required this.tally, required this.checkedAt});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor, fontFeatures: _tabular);
    final loading = data.loadingSections;
    final healthy = loading.isEmpty && tally.problems == 0;
    final headline = healthy ? 'All healthy' : (tally.problems > 0 ? 'Needs attention' : 'Checking…');
    final mark = healthy
        ? IssueSeverity.info
        : tally.critical > 0
            ? IssueSeverity.critical
            : IssueSeverity.warning;
    final title = theme.textTheme.titleLarge?.copyWith(fontSize: 19, fontWeight: FontWeight.w600, letterSpacing: -0.2, height: 1.2);
    Widget detail;
    if (healthy) {
      detail = Row(mainAxisSize: MainAxisSize.min, children: [
        if (checkedAt != null) ...[
          Text('checked ', style: hint),
          DefaultTextStyle.merge(style: hint, child: AgeText(checkedAt!.toUtc().toIso8601String(), suffix: ' ago')),
        ],
      ]);
    } else {
      final n = tally.areas.length;
      detail = Text.rich(
        TextSpan(children: [
          if (tally.critical > 0) TextSpan(text: '${tally.critical} critical', style: TextStyle(color: issueColor(context, IssueSeverity.critical))),
          if (tally.critical > 0 && tally.warning > 0) const TextSpan(text: '  ·  '),
          if (tally.warning > 0) TextSpan(text: plural(tally.warning, 'warning'), style: TextStyle(color: issueColor(context, IssueSeverity.warning))),
          if (n > 0) TextSpan(text: n == 1 ? ' in 1 area' : ' across $n areas'),
          if (loading.isNotEmpty) TextSpan(text: '${tally.problems > 0 ? '  ·  ' : ''}still checking ${plural(loading.length, 'source')}'),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: hint,
      );
    }
    final lines = healthy ? _healthyLines(data) : const <String>[];
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: 22, child: Align(alignment: Alignment.centerLeft, child: _StatusMark(severity: healthy ? null : (tally.problems > 0 ? mark : IssueSeverity.info)))),
        Text(headline, style: title),
        const SizedBox(width: 14),
        Flexible(child: Padding(padding: const EdgeInsets.only(top: 2), child: detail)),
      ]),
      if (lines.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 22, top: 4),
          child: Text(lines.join(' · '), style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ),
    ]);
  }
}

/// A check when healthy; a dot in the worst severity otherwise. A critical
/// dot sends out a few slow rings when it appears (none with reduced
/// motion), then rests: nothing animates on an idle page.
class _StatusMark extends StatefulWidget {
  /// Null: healthy. Info: still checking.
  final IssueSeverity? severity;
  const _StatusMark({required this.severity});

  @override
  State<_StatusMark> createState() => _StatusMarkState();
}

class _StatusMarkState extends State<_StatusMark> with SingleTickerProviderStateMixin {
  static const _rings = 3;
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800 * _rings));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybePulse(null);
  }

  @override
  void didUpdateWidget(_StatusMark old) {
    super.didUpdateWidget(old);
    _maybePulse(old.severity);
  }

  void _maybePulse(IssueSeverity? before) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.severity == IssueSeverity.critical && before != IssueSeverity.critical && !reduce && !_c.isAnimating) _c.forward(from: 0);
    if (widget.severity != IssueSeverity.critical) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.severity;
    if (s == null) return Icon(Icons.check_circle, size: 16, color: severityColor(context, Severity.ok));
    final color = s == IssueSeverity.info ? Theme.of(context).hintColor : issueColor(context, s);
    final dot = Container(width: 9, height: 9, decoration: BoxDecoration(color: s == IssueSeverity.info ? null : color, shape: BoxShape.circle, border: s == IssueSeverity.info ? Border.all(color: color, width: 1.5) : null));
    if (s != IssueSeverity.critical) return dot;
    return SizedBox(
      width: 9,
      height: 9,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = _c.isAnimating ? (_c.value * _rings) % 1 : 0.0;
          return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
            if (t > 0)
              Positioned(
                left: -6 * t,
                top: -6 * t,
                right: -6 * t,
                bottom: -6 * t,
                child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.35 * (1 - t)))),
              ),
            child!,
          ]);
        },
        child: dot,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Inventory strip: ready/total per type
// ---------------------------------------------------------------------------

class _Stat {
  final String label;
  final int? good;
  final int? total;
  final String? note;

  /// Whether the shortfall is a problem (colours the number and bar).
  final bool bad;

  /// Where clicking the block goes: the kind's table (filtered to the
  /// shortfall where a column can say so) or page.
  final OverviewTarget? target;
  const _Stat(this.label, this.good, this.total, {this.note, this.bad = false, this.target});
  bool get pending => total == null;
}

/// One row of large numerals with small labels, divided by hairlines. A
/// healthy type shows its plain count; a shortfall shows good/total in
/// amber (red when none are good) with a short bar under it.
class StatBlocks extends StatelessWidget {
  final OverviewData data;
  final NamespaceScope scope;
  const StatBlocks({super.key, required this.data, this.scope = NamespaceScope.all});

  List<_Stat> _stats() {
    final out = <_Stat>[];
    void add(String type, String label, String good, String source, OverviewTarget target, {String? badFilter}) {
      if (data.isPending(source)) return out.add(_Stat(label, null, null));
      final total = data.count(type, 'total');
      if (total == 0) return;
      final g = data.count(type, good);
      final bad = g < total;
      final t = bad && badFilter != null ? OverviewTarget.table(target.group, target.kind, badFilter) : target;
      out.add(_Stat(label, g, total, bad: bad, target: t));
    }

    final pods = data.count('pods', 'total');
    if (pods > 0) {
      final completed = data.count('pods', 'completed');
      final ready = data.count('pods', 'ready');
      out.add(_Stat('pods ready', ready, pods - completed,
          note: completed > 0 ? '+$completed completed' : null, bad: ready < pods - completed, target: const OverviewTarget.table('', 'Pod')));
    }
    add('deployments', 'deployments', 'healthy', 'deployments', const OverviewTarget.table('apps', 'Deployment'));
    add('statefulSets', 'statefulsets', 'healthy', 'statefulsets', const OverviewTarget.table('apps', 'StatefulSet'));
    add('daemonSets', 'daemonsets', 'healthy', 'daemonsets', const OverviewTarget.table('apps', 'DaemonSet'));
    final jobs = data.count('jobs', 'total');
    if (data.isPending('jobs')) {
      out.add(const _Stat('jobs succeeded', null, null));
    } else if (jobs > 0) {
      final failed = data.count('jobs', 'failed');
      out.add(_Stat('jobs succeeded', data.count('jobs', 'succeeded'), jobs,
          note: failed > 0 ? '$failed failed' : null,
          bad: failed > 0,
          target: OverviewTarget.table('batch', 'Job', failed > 0 ? 'status=Failed' : null)));
    }
    add('nodes', 'nodes ready', 'ready', 'nodes', const OverviewTarget.page(MainView.nodes));
    add('pvcs', 'PVCs bound', 'bound', 'pvcs', const OverviewTarget.table('', 'PersistentVolumeClaim'), badFilter: 'status!=Bound');
    return out;
  }

  static const _minCell = 124.0;
  static const _maxCell = 200.0;

  @override
  Widget build(BuildContext context) {
    final stats = _stats();
    if (stats.isEmpty) return const SizedBox.shrink();
    final separator = AppColors.of(context).separator;
    return LayoutBuilder(builder: (context, box) {
      final n = stats.length;
      final fit = (box.maxWidth / _minCell).floor().clamp(1, 8);
      // More than fit: spread evenly over the rows. Fewer: each keeps a
      // comfortable width, left-aligned, rather than stretching apart.
      final rows = (n / fit).ceil();
      final cols = (n / rows).ceil();
      final width = rows > 1 ? box.maxWidth / cols : (box.maxWidth / n).clamp(_minCell, _maxCell);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var r = 0; r < n; r += cols) ...[
          if (r > 0) const SizedBox(height: 14),
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = r; i < r + cols && i < n; i++)
                Container(
                  width: width,
                  padding: EdgeInsets.only(left: i == r ? 0 : 16, right: 8),
                  decoration: i == r ? null : BoxDecoration(border: Border(left: BorderSide(color: separator))),
                  child: _StatBlock(stat: stats[i], scope: scope),
                ),
            ]),
          ),
        ],
      ]);
    });
  }
}

class _StatBlock extends StatelessWidget {
  final _Stat stat;
  final NamespaceScope scope;
  const _StatBlock({required this.stat, required this.scope});

  @override
  Widget build(BuildContext context) {
    final target = stat.target;
    if (stat.pending || target == null) return _block(context, hovered: false);
    return Hoverable(
      key: ValueKey('stat-${stat.label}'),
      onTap: () => openOverviewTarget(context, target, scope),
      builder: (hovered) => _block(context, hovered: hovered),
    );
  }

  Widget _block(BuildContext context, {required bool hovered}) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final good = stat.good ?? 0;
    final total = stat.total ?? 0;
    // Red only when none are ready/bound/succeeded (an outage); partly
    // ready is amber, so a busy cluster isn't a wall of red.
    final color = issueColor(context, good == 0 && total > 0 ? IssueSeverity.critical : IssueSeverity.warning);
    final big = theme.textTheme.headlineMedium?.copyWith(
      fontSize: 30,
      height: 1.1,
      fontWeight: FontWeight.w300,
      letterSpacing: -0.5,
      fontFeatures: _tabular,
      color: stat.bad ? color : theme.colorScheme.onSurface,
    );
    final label = theme.textTheme.bodySmall?.copyWith(
      color: hovered ? theme.colorScheme.onSurface : theme.hintColor,
      decoration: hovered ? TextDecoration.underline : null,
      decorationColor: theme.hintColor,
    );
    return Column(
      key: stat.pending ? ValueKey('pending-inventory-${stat.label}') : null,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 34,
          child: stat.pending
              ? const Align(alignment: Alignment.centerLeft, child: SkeletonBar(width: 44, height: 22))
              : Text.rich(
                  TextSpan(children: [
                    TextSpan(text: '$good', style: big),
                    if (stat.bad) TextSpan(text: ' / $total', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w400, color: theme.hintColor, fontFeatures: _tabular)),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
        ),
        const SizedBox(height: 3),
        Text.rich(
          TextSpan(children: [
            TextSpan(text: stat.label),
            if (stat.note != null) TextSpan(text: ' · ${stat.note}', style: TextStyle(color: stat.bad && stat.label.startsWith('jobs') ? color : colors.faint, decoration: TextDecoration.none)),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: label,
        ),
        // Only a shortfall gets a bar: healthy is the plain number.
        if (stat.bad && total > 0) ...[
          const SizedBox(height: 7),
          SizedBox(width: 56, child: _Bar(frac: good / total, color: color, height: 2.5)),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Capacity: cluster requests (and usage) against allocatable
// ---------------------------------------------------------------------------

/// Cores with at most one decimal ("12.4", "32").
String formatCores(double millis) {
  final c = millis / 1000;
  if (c == c.roundToDouble()) return c.toStringAsFixed(0);
  return c < 10 ? c.toStringAsFixed(c < 1 ? 2 : 1) : c.toStringAsFixed(1);
}

/// The Capacity section: CPU and memory history (Prometheus), or plain
/// bars of requests (and live usage) against allocatable without it.
class CapacityStrip extends StatelessWidget {
  /// Null while nodes are pending: a placeholder stands in.
  final ResourceTotals? capacity;

  /// Live usage summed over nodes (metrics-server), when available.
  final Usage? usage;
  final int nodes;
  const CapacityStrip({super.key, required this.capacity, this.usage, this.nodes = 0});

  @override
  Widget build(BuildContext context) {
    final c = capacity;
    final u = usage;
    final where = 'across ${plural(nodes, 'node')}';
    final cpu = c == null
        ? null
        : _Meter(
            label: 'CPU',
            requested: c.cpuRequests,
            allocatable: c.cpuAllocatable,
            used: u?.cpuMillis,
            amount: '${formatCores(c.cpuRequests)} / ${formatCores(c.cpuAllocatable)} cores',
            usedText: u == null ? null : '${formatCores(u.cpuMillis)} cores',
            where: where,
          );
    final mem = c == null
        ? null
        : _Meter(
            label: 'Memory',
            requested: c.memoryRequests,
            allocatable: c.memoryAllocatable,
            used: u?.memoryBytes,
            amount: '${formatBytes(c.memoryRequests)} / ${formatBytes(c.memoryAllocatable)}',
            usedText: u == null ? null : formatBytes(u.memoryBytes),
            where: where,
          );
    final bars = CapacityColumns(children: [cpu ?? const _PendingMeter(), mem ?? const _PendingMeter()]);
    if (c != null) return ClusterHistory(capacity: c, fallback: bars, note: where);
    // Pending on a cluster where Prometheus was found before: hold the
    // charts' height rather than the bars', so the page doesn't jump.
    return OverviewSection(
      key: const ValueKey('pending-capacity'),
      title: 'Capacity',
      collapsible: false,
      child: PromApi.of(context.read<ApiClient>()).knownHasPrometheus == true ? const HistoryPlaceholder() : bars,
    );
  }
}

/// CPU and memory side by side, or stacked when narrow.
class CapacityColumns extends StatelessWidget {
  final List<Widget> children;
  const CapacityColumns({super.key, required this.children});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        if (box.maxWidth >= 620) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: children[0]),
            const SizedBox(width: 48),
            Expanded(child: children[1]),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [children[0], const SizedBox(height: 22), children[1]]);
      });
}

class _PendingMeter extends StatelessWidget {
  const _PendingMeter();

  @override
  Widget build(BuildContext context) => const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SkeletonBar(width: 50, height: 10),
        SizedBox(height: 8),
        SkeletonBar(width: 110, height: 24),
        SizedBox(height: 8),
        SkeletonBar(width: 180, height: 10),
        SizedBox(height: 10),
        SkeletonBar(height: 4),
      ]);
}

/// The big figure of a capacity column: "29%" or "1.8" with its unit
/// after it in small type.
Widget capacityFigure(BuildContext context, String value, String unit, {String? suffix, Color? color}) {
  final theme = Theme.of(context);
  final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontFeatures: _tabular);
  return Text.rich(
    TextSpan(children: [
      TextSpan(
        text: value,
        style: theme.textTheme.headlineSmall?.copyWith(fontSize: 26, height: 1.15, fontWeight: FontWeight.w300, letterSpacing: -0.4, fontFeatures: _tabular, color: color),
      ),
      TextSpan(text: ' $unit', style: hint?.copyWith(fontSize: 12.5)),
      if (suffix != null) TextSpan(text: '  ·  $suffix', style: hint?.copyWith(fontSize: 12.5)),
    ]),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
  );
}

/// The small caption over a capacity column ("CPU", "Memory").
Widget capacityLabel(BuildContext context, String label) {
  final theme = Theme.of(context);
  return Text(label, style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600, letterSpacing: 0.3));
}

/// "3.5 / 12 cores requested · 29%".
Widget requestedLine(BuildContext context, String amount, double? frac) {
  final theme = Theme.of(context);
  return Text.rich(
    TextSpan(children: [
      TextSpan(text: amount, style: TextStyle(color: theme.colorScheme.onSurface.withValues(alpha: 0.85))),
      const TextSpan(text: ' requested'),
      if (frac != null) ...[
        const TextSpan(text: ' · '),
        TextSpan(text: formatPercent(frac), style: TextStyle(color: percentColor(context, frac) ?? theme.colorScheme.onSurface, fontWeight: FontWeight.w600)),
      ],
    ]),
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontFeatures: _tabular),
  );
}

class _Meter extends StatelessWidget {
  final String label;
  final double requested;
  final double allocatable;
  final double? used;
  final String amount;
  final String? usedText;
  final String where;
  const _Meter({
    required this.label,
    required this.requested,
    required this.allocatable,
    required this.amount,
    required this.where,
    this.used,
    this.usedText,
  });

  @override
  Widget build(BuildContext context) {
    final req = allocatable > 0 ? requested / allocatable : null;
    final use = allocatable > 0 && used != null ? used! / allocatable : null;
    // Colour follows the larger of the two (thresholds only; neutral below).
    final color = meterColor(context, [req ?? 0, use ?? 0].reduce((a, b) => a > b ? a : b));
    final free = allocatable - requested;
    return Tooltip(
      message: [
        '$label requested $where: $amount${req == null ? '' : ' (${formatPercent(req)})'}',
        if (usedText != null) 'In use: $usedText${use == null ? '' : ' (${formatPercent(use)})'}',
      ].join('\n'),
      waitDuration: const Duration(milliseconds: 400),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        capacityLabel(context, label),
        const SizedBox(height: 2),
        // Live usage when metrics-server has it, else what is left to
        // schedule (the line below says what is requested).
        use != null
            ? capacityFigure(context, formatPercent(use), 'in use', suffix: usedText, color: percentColor(context, use))
            : capacityFigure(context, label == 'CPU' ? formatCores(free) : formatBytes(free), label == 'CPU' ? 'cores free to schedule' : 'free to schedule'),
        const SizedBox(height: 2),
        requestedLine(context, amount, req),
        const SizedBox(height: 10),
        _Bar(frac: use ?? req ?? 0, under: use == null ? null : req, color: color, height: 4),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Needs attention: problems per area
// ---------------------------------------------------------------------------

const _areaOrder = ['pods', 'workloads', 'jobs', 'nodes', 'storage', 'network', 'argocd', 'alerts'];

String sectionLabel(String section) => switch (section) {
      'pods' => 'Pods',
      'nodes' => 'Nodes',
      'alerts' => 'Alerts',
      'workloads' => 'Workloads',
      'jobs' => 'Jobs',
      'storage' => 'Storage',
      'argocd' => 'Argo CD',
      'network' => 'Network',
      _ => section.isEmpty ? section : '${section[0].toUpperCase()}${section.substring(1)}',
    };

IconData _sectionIcon(String section) => switch (section) {
      'pods' => Icons.view_in_ar_outlined,
      'workloads' => Icons.layers_outlined,
      'jobs' => Icons.schedule_outlined,
      'nodes' => Icons.dns_outlined,
      'storage' => Icons.storage_outlined,
      'network' => Icons.lan_outlined,
      'argocd' => Icons.sync_outlined,
      'alerts' => Icons.notifications_none,
      _ => Icons.extension_outlined,
    };

/// "All 17 pods healthy" (or "1 pod healthy").
String _all(int n, String noun, String state, [String? many]) => n == 1 ? '1 $noun $state' : 'All ${plural(n, noun, many)} $state';

/// What a problem-free [section] says, or null when it has nothing to report.
String? _healthyLine(OverviewData d, String section) {
  switch (section) {
    case 'pods':
      final n = d.count('pods', 'total') - d.count('pods', 'completed');
      return n > 0 ? _all(n, 'pod', 'healthy') : null;
    case 'workloads':
      final n = d.count('deployments', 'total') + d.count('statefulSets', 'total') + d.count('daemonSets', 'total');
      return n > 0 ? _all(n, 'workload', 'healthy') : null;
    case 'jobs':
      final n = d.count('jobs', 'total') + d.count('cronJobs', 'total');
      return n > 0 ? 'No failing jobs' : null;
    case 'nodes':
      final n = d.count('nodes', 'total');
      return n > 0 ? _all(n, 'node', 'ready') : null;
    case 'storage':
      final n = d.count('pvcs', 'total');
      return n > 0 ? _all(n, 'PVC', 'bound') : null;
    case 'network':
      final n = d.count('gateways', 'total') + d.count('routes', 'total');
      return n > 0 ? 'Gateways and routes healthy' : null;
    case 'argocd':
      final n = d.count('argoApps', 'total');
      return n > 0 ? _all(n, 'Argo CD app', 'healthy') : null;
  }
  return null;
}

/// Areas in display order: the built-in ones, then modules' and loading ones.
List<String> _sections(OverviewData data) => [
      ..._areaOrder,
      ...{for (final c in data.categories) c.section, ...data.loadingSections}.where((s) => !_areaOrder.contains(s)).toList()..sort(),
    ];

/// The lines of every problem-free, loaded area ("All 7 workloads healthy").
List<String> _healthyLines(OverviewData data) => [
      for (final s in _sections(data))
        if (!data.categories.any((c) => c.section == s) && !data.loadingSections.contains(s)) ?_healthyLine(data, s),
    ];

/// The issues behind a category, in words: "4 pods, 2 workloads".
String categorySublabel(OverviewData data, OverviewCategory c) {
  final issues = data.issues.where((i) => i.category == c.id).toList();
  if (issues.isEmpty) return '';
  final first = issues.first;
  if (first.kind == 'Pod') {
    final owners = {for (final i in issues) if (i.owner != null) '${i.namespace}/${i.owner!.kind}/${i.owner!.name}'};
    final bare = issues.where((i) => i.owner == null).length;
    if (issues.length == 1) return first.owner != null ? 'pod of ${first.owner!.name}' : 'pod ${first.name}';
    if (owners.length == 1 && bare == 0) return '${plural(issues.length, 'pod')} of ${first.owner!.name}';
    return '${plural(issues.length, 'pod')}, ${plural(owners.length + bare, 'workload')}';
  }
  final kind = first.kind == 'PersistentVolumeClaim' ? 'PVC' : first.kind;
  if (issues.length == 1) return '${first.kind == 'PersistentVolumeClaim' ? 'PVC' : kind.toLowerCase()} ${first.name}';
  final kinds = {for (final i in issues) i.kind};
  if (kinds.length > 1) return plural(issues.length, 'object');
  return '${issues.length} ${(kind.endsWith('s') ? '${kind}es' : '${kind}s').toLowerCase()}';
}

/// "Needs attention": one group per area (Pods, Workloads, Jobs, Nodes,
/// Storage, then modules) that has problems or is still loading, its name
/// in a narrow gutter and its problems beside it, hairlines between areas.
/// Wide pages flow the groups into two columns. Problem-free areas fold
/// into one quiet line; with nothing wrong at all there is no section (the
/// hero says so).
class AreaCards extends StatelessWidget {
  final OverviewData data;
  final String? selected;
  final ValueChanged<String> onSelect;

  /// The Overview's namespaces: tables opened from a row show these.
  final NamespaceScope scope;
  const AreaCards({super.key, required this.data, required this.selected, required this.onSelect, this.scope = NamespaceScope.all});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final loading = data.loadingSections;
    final groups = <(Widget, int)>[];
    for (final s in _sections(data)) {
      final cats = data.categories.where((c) => c.section == s).toList();
      final pending = loading.contains(s);
      if (cats.isEmpty && !pending) continue;
      groups.add((
        _AreaGroup(
          section: s,
          problems: [for (final c in cats) if (c.severity != IssueSeverity.info) c],
          info: [for (final c in cats) if (c.severity == IssueSeverity.info) c],
          pending: pending,
          data: data,
          selected: selected,
          onSelect: onSelect,
          scope: scope,
        ),
        cats.length + (pending ? 1 : 0) + 1,
      ));
    }
    if (groups.isEmpty) return const SizedBox.shrink();
    final allHealthy = _allHealthy(data);
    final healthy = allHealthy ? const <String>[] : _healthyLines(data);
    final tally = _Tally(data);
    return OverviewSection(
      title: allHealthy ? 'Worth a look' : 'Needs attention',
      collapsible: false,
      trailing: tally.problems == 0 ? null : Text(plural(tally.problems, 'problem')),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        LayoutBuilder(builder: (context, box) {
          final cols = box.maxWidth >= 1040 && groups.length > 1 ? 2 : 1;
          // Masonry: each group goes to the shorter column, in order.
          final columns = List.generate(cols, (_) => <Widget>[]);
          final heights = List.filled(cols, 0);
          for (final (w, h) in groups) {
            var c = 0;
            for (var i = 1; i < cols; i++) {
              if (heights[i] < heights[c]) c = i;
            }
            columns[c].add(w);
            heights[c] += h;
          }
          Widget column(List<Widget> items) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final (i, w) in items.indexed) ...[
                  if (i > 0) Divider(height: 1, thickness: 1, color: AppColors.of(context).separator.withValues(alpha: 0.6)),
                  w,
                ],
              ]);
          if (cols == 1) return column(columns[0]);
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: column(columns[0])),
            const SizedBox(width: 48),
            Expanded(child: column(columns[1])),
          ]);
        }),
        if (healthy.isNotEmpty) ...[
          Divider(height: 1, thickness: 1, color: AppColors.of(context).separator.withValues(alpha: 0.6)),
          Padding(padding: const EdgeInsets.only(top: 12), child: _HealthyLines(lines: healthy, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
        ],
      ]),
    );
  }
}

/// "✓ All 7 workloads healthy · No failing jobs".
class _HealthyLines extends StatelessWidget {
  final List<String> lines;
  final TextStyle? style;
  const _HealthyLines({required this.lines, this.style});

  @override
  Widget build(BuildContext context) {
    final ok = severityColor(context, Severity.ok).withValues(alpha: 0.85);
    final faint = AppColors.of(context).faint;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.check, size: 13, color: ok)),
      const SizedBox(width: 8),
      Expanded(
        child: Wrap(runSpacing: 2, children: [
          for (final (i, l) in lines.indexed) ...[
            if (i > 0) Text('  ·  ', style: style?.copyWith(color: faint)),
            Text(l, style: style),
          ],
        ]),
      ),
    ]);
  }
}

class _AreaGroup extends StatelessWidget {
  final String section;
  final List<OverviewCategory> problems;
  final List<OverviewCategory> info;
  final bool pending;
  final OverviewData data;
  final String? selected;
  final ValueChanged<String> onSelect;
  final NamespaceScope scope;
  const _AreaGroup({
    required this.section,
    required this.problems,
    required this.info,
    required this.pending,
    required this.data,
    required this.selected,
    required this.onSelect,
    required this.scope,
  });

  Widget _row(BuildContext context, OverviewCategory c) {
    final target = rowTarget(data, c);
    return _AreaRow(
      category: c,
      sublabel: categorySublabel(data, c),
      selected: selected == c.id,
      onFilter: () => onSelect(c.id),
      // A kind the cluster doesn't serve falls back to the Issues filter.
      onOpen: target == null ? null : () => openOverviewTarget(context, target, scope) ? null : onSelect(c.id),
    );
  }

  Widget _title(BuildContext context, OverviewTarget? title) {
    final theme = Theme.of(context);
    Widget row(bool hovered) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(_sectionIcon(section), size: 14, color: hovered ? theme.colorScheme.onSurface : theme.hintColor),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              sectionLabel(section),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontSize: 13,
                decoration: hovered ? TextDecoration.underline : null,
                decorationColor: theme.hintColor,
              ),
            ),
          ),
        ]);
    if (title == null) return row(false);
    return Hoverable(
      key: ValueKey('area-title-$section'),
      onTap: () => openOverviewTarget(context, title, scope),
      builder: (hovered) => Tooltip(message: 'Open ${sectionLabel(section)}', waitDuration: const Duration(milliseconds: 600), child: row(hovered)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final worst = problems.isEmpty ? null : problems.map((c) => c.severity).reduce((a, b) => a.index <= b.index ? a : b);
    final total = problems.fold<int>(0, (n, c) => n + c.count);
    final page = enabledPages(context.read<AppState>()).any((p) => p.view.name == section) ? OverviewTarget.page(MainView(section)) : null;
    final title = titleTarget(data, section) ?? page;
    final healthyLine = _healthyLine(data, section);
    final count = worst == null
        ? null
        : Text(
            '$total',
            style: theme.textTheme.titleLarge?.copyWith(fontSize: 20, height: 1.1, fontWeight: FontWeight.w300, color: issueColor(context, worst), fontFeatures: _tabular),
          );
    final rows = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (problems.isEmpty && !pending && healthyLine != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
          child: _HealthyLines(lines: [healthyLine], style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ),
      for (final c in problems) _row(context, c),
      if (pending)
        Padding(
          key: ValueKey('pending-tile-$section'),
          padding: const EdgeInsets.fromLTRB(8, 5, 6, 5),
          child: Row(children: [
            const SkeletonBar(width: 90, height: 10),
            const SizedBox(width: 8),
            Text('Checking…', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ]),
        ),
      for (final c in info) _row(context, c),
    ]);
    return Padding(
      key: ValueKey('area-$section'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: LayoutBuilder(builder: (context, box) {
        // A narrow gutter with the area's name and total beside its rows;
        // when there isn't room, the name sits on top.
        if (box.maxWidth >= 420) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 128,
              child: Padding(
                padding: const EdgeInsets.only(top: 3, right: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _title(context, title),
                  if (count != null) ...[const SizedBox(height: 4), Padding(padding: const EdgeInsets.only(left: 21), child: count)],
                ]),
              ),
            ),
            Expanded(child: rows),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              Expanded(child: Align(alignment: Alignment.centerLeft, child: _title(context, title))),
              ?count,
            ]),
          ),
          rows,
        ]);
      }),
    );
  }
}

/// "▎4  CrashLoopBackOff · 4 pods, 2 workloads". Click goes to what the row
/// names ([onOpen]); the count filters the Issues list ([onFilter]), as does
/// the whole row when it has nowhere to go.
class _AreaRow extends StatelessWidget {
  final OverviewCategory category;
  final String sublabel;
  final bool selected;
  final VoidCallback onFilter;
  final VoidCallback? onOpen;
  const _AreaRow({required this.category, required this.sublabel, required this.selected, required this.onFilter, this.onOpen});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final info = category.severity == IssueSeverity.info;
    final c = issueColor(context, category.severity);
    final hint = theme.textTheme.bodySmall?.copyWith(color: info ? colors.faint : theme.hintColor);
    final count = Text(
      '${category.count}',
      style: theme.textTheme.bodySmall?.copyWith(
        fontWeight: FontWeight.w600,
        fontFeatures: _tabular,
        color: info ? theme.hintColor : null,
      ),
    );
    return Hoverable(
      key: ValueKey('area-row-${category.id}'),
      onTap: onOpen ?? onFilter,
      builder: (hovered) => Container(
        padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
        decoration: BoxDecoration(
          color: selected ? colors.selection : (hovered ? colors.hover : null),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(children: [
          // The severity marker: a short bar, hollow for info.
          Container(
            width: 3,
            height: 13,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(2),
              color: info ? null : c,
              border: info ? Border.all(color: colors.faint) : null,
            ),
          ),
          const SizedBox(width: 10),
          SizedBox(
            width: 22,
            child: onOpen == null
                ? Tooltip(message: selected ? 'Show all issues' : 'Show only ${category.label}', waitDuration: const Duration(milliseconds: 600), child: count)
                : Tooltip(
                    message: selected ? 'Show all issues' : 'Show these in Issues',
                    waitDuration: const Duration(milliseconds: 600),
                    child: GestureDetector(key: ValueKey('area-count-${category.id}'), behavior: HitTestBehavior.opaque, onTap: onFilter, child: count),
                  ),
          ),
          const SizedBox(width: 4),
          // One line: the detail is what an ellipsis cuts first.
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: category.label, style: TextStyle(color: info ? theme.hintColor : theme.colorScheme.onSurface)),
                if (sublabel.isNotEmpty) TextSpan(text: ' · $sublabel', style: hint),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall?.copyWith(fontSize: 12.5),
            ),
          ),
          if (onOpen != null) Icon(Icons.chevron_right, size: 14, color: hovered ? theme.hintColor : Colors.transparent),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Node cards
// ---------------------------------------------------------------------------

class NodeCards extends StatelessWidget {
  final List<NodeHealth> nodes;

  /// Draw request bars (only meaningful when every namespace is in scope).
  final bool showRequests;
  final int max;
  const NodeCards({super.key, required this.nodes, this.showRequests = true, this.max = 12});

  static int _rank(NodeHealth n) => !n.ready ? 0 : (n.pressure.isNotEmpty ? 1 : (n.cordoned ? 2 : 3));

  @override
  Widget build(BuildContext context) {
    final sorted = [...nodes]..sort((a, b) {
        final r = _rank(a).compareTo(_rank(b));
        return r != 0 ? r : a.name.compareTo(b.name);
      });
    final shown = sorted.take(max).toList();
    final more = sorted.length - shown.length;
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, box) {
        final cols = (box.maxWidth / 240).floor().clamp(1, 6);
        return _grid([for (final n in shown) _NodeCard(node: n, showRequests: showRequests)], cols, gap: 28, runGap: 14);
      }),
      if (more > 0)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () {
              final app = context.read<AppState>();
              final t = app.typeFor('', 'Node');
              if (t != null) app.selectType(t);
            },
            child: Text('+$more more on the Nodes page', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
          ),
        ),
    ]);
  }
}

class _NodeCard extends StatelessWidget {
  final NodeHealth node;
  final bool showRequests;
  const _NodeCard({required this.node, required this.showRequests});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final sev = !node.ready ? Severity.error : (node.pressure.isNotEmpty || node.cordoned ? Severity.warn : Severity.ok);
    final c = severityColor(context, sev);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final status = [if (!node.ready) 'NotReady', ...node.pressure, if (node.cordoned) 'Cordoned'];
    final r = node.resources;
    // Unboxed: a hairline down the left, in the node's colour when it
    // isn't plainly ready.
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => openObject(context, ObjectRef(kind: 'Node', name: node.name)),
        hoverColor: colors.hover,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          decoration: BoxDecoration(border: Border(left: BorderSide(color: sev == Severity.ok ? colors.separator : c, width: 2))),
          padding: const EdgeInsets.fromLTRB(12, 4, 6, 6),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Tooltip(
              message: status.isEmpty ? 'Ready' : status.join(', '),
              waitDuration: const Duration(milliseconds: 600),
              child: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
            ),
            const SizedBox(height: 2),
            Text.rich(
              TextSpan(children: [
                if (status.isNotEmpty) TextSpan(text: '${status.join(', ')} · ', style: TextStyle(color: c)),
                if (node.roles.isNotEmpty) TextSpan(text: '${node.roles.join(', ')} · '),
                TextSpan(text: plural(node.pods, 'pod')),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: hint,
            ),
            if (showRequests && r.known) ...[
              const SizedBox(height: 8),
              _MiniMeter(label: 'CPU', requested: r.cpuRequests, allocatable: r.cpuAllocatable),
              const SizedBox(height: 4),
              _MiniMeter(label: 'Mem', requested: r.memoryRequests, allocatable: r.memoryAllocatable),
            ],
          ]),
        ),
      ),
    );
  }
}

class _MiniMeter extends StatelessWidget {
  final String label;
  final double requested;
  final double allocatable;
  const _MiniMeter({required this.label, required this.requested, required this.allocatable});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final frac = allocatable > 0 ? requested / allocatable : 0.0;
    final small = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w400, fontFeatures: _tabular);
    return Tooltip(
      message: '$label requested: ${label == 'CPU' ? '${formatCores(requested)} / ${formatCores(allocatable)} cores' : '${formatBytes(requested)} / ${formatBytes(allocatable)}'}',
      waitDuration: const Duration(milliseconds: 400),
      child: Row(children: [
        SizedBox(width: 30, child: Text(label, style: small)),
        Expanded(child: _Bar(frac: frac, color: meterColor(context, frac), height: 4)),
        SizedBox(
          width: 36,
          child: Text(formatPercent(frac), textAlign: TextAlign.right, style: small?.copyWith(color: percentColor(context, frac))),
        ),
      ]),
    );
  }
}
