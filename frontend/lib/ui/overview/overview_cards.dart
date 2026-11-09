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
import '../widgets/editorial.dart';
import 'overview_widgets.dart' show issueColor, openObject;

const _tabular = tabularFigures;

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

  /// Paint the wash behind the hero itself. Off when the page paints it
  /// ([OverviewWash]) behind its header and the hero together.
  final bool wash;
  const OverviewHero({super.key, required this.data, this.scope = NamespaceScope.all, this.checkedAt, this.inset = 24, this.wash = true});

  @override
  Widget build(BuildContext context) {
    final tally = _Tally(data);
    return Container(
      key: const ValueKey('overview-hero'),
      decoration: !wash || tally.critical == 0 ? null : overviewWashDecoration(context),
      padding: EdgeInsets.fromLTRB(inset, 22, inset, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _StatusLine(data: data, tally: tally, checkedAt: checkedAt),
        const SizedBox(height: 22),
        StatBlocks(data: data, scope: scope),
      ]),
    );
  }
}

/// Whether the Overview shows its red wash: while anything is critical.
bool overviewWashes(OverviewData data) => _Tally(data).critical > 0;

/// A wide, low glow from the top left that has faded out by the box's
/// bottom edge.
BoxDecoration overviewWashDecoration(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  final crit = issueColor(context, IssueSeverity.critical);
  return BoxDecoration(
    gradient: RadialGradient(
      center: _washCenter,
      radius: 1.1,
      colors: [crit.withValues(alpha: dark ? 0.09 : 0.06), crit.withValues(alpha: 0)],
      transform: const _StretchX(4),
    ),
  );
}

/// The wash on its own, for painting behind the page header and the hero
/// as one (static: a gradient, no animation).
class OverviewWash extends StatelessWidget {
  const OverviewWash({super.key});

  @override
  Widget build(BuildContext context) => IgnorePointer(child: DecoratedBox(key: const ValueKey('overview-wash'), decoration: overviewWashDecoration(context)));
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
    final hint = statusDetailStyle(context);
    final loading = data.loadingSections;
    final healthy = loading.isEmpty && tally.problems == 0;
    final headline = healthy ? 'All healthy' : (tally.problems > 0 ? 'Needs attention' : 'Checking…');
    final mark = healthy
        ? Severity.ok
        : tally.critical > 0
            ? Severity.error
            : tally.problems > 0
                ? Severity.warn
                : Severity.info;
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
    // What is fine, quietly under the headline: "All 7 workloads healthy"
    // when everything is, else "7 workloads healthy · 3 nodes ready".
    final lines = _healthyLines(data, brief: !healthy);
    return StatusLine(mark: StatusMark(severity: mark), headline: headline, detail: detail, note: lines.join(' · '), faintNote: !healthy);
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

  StatItem item(BuildContext context, NamespaceScope scope) {
    if (pending) return StatItem(label, null, pendingKey: ValueKey('pending-inventory-$label'));
    final g = good ?? 0;
    final t = total ?? 0;
    final target = this.target;
    return StatItem(
      label,
      '$g',
      of: bad ? '/ $t' : null,
      note: note,
      // Red only when none are ready/bound/succeeded (an outage); partly
      // ready is amber, so a busy cluster isn't a wall of red.
      tone: bad ? (g == 0 && t > 0 ? Severity.error : Severity.warn) : null,
      frac: bad && t > 0 ? g / t : null,
      noteTone: label.startsWith('jobs'),
      onTap: target == null ? null : () => openOverviewTarget(context, target, scope),
    );
  }
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

  @override
  Widget build(BuildContext context) => StatStrip(items: [for (final s in _stats()) s.item(context, scope)]);
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
    return EditorialSection(
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
        FigureCaption(label),
        const SizedBox(height: 2),
        // Live usage when metrics-server has it, else what is left to
        // schedule (the line below says what is requested).
        use != null
            ? BigFigure(formatPercent(use), 'in use', suffix: usedText, color: percentColor(context, use))
            : BigFigure(label == 'CPU' ? formatCores(free) : formatBytes(free), label == 'CPU' ? 'cores free to schedule' : 'free to schedule'),
        const SizedBox(height: 2),
        requestedLine(context, amount, req),
        const SizedBox(height: 10),
        HairlineBar(frac: use ?? req ?? 0, under: use == null ? null : req, color: color, height: 4),
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

/// "All 17 pods healthy" (or "1 pod healthy"); [brief]: "17 pods healthy".
String _all(int n, String noun, String state, {bool brief = false}) => n == 1 ? '1 $noun $state' : '${brief ? '' : 'All '}${plural(n, noun)} $state';

/// What a problem-free [section] says, or null when it has nothing to report.
/// [brief] drops the "All" and starts lower case, for a run of them under
/// the status line beside problems.
String? _healthyLine(OverviewData d, String section, {bool brief = false}) {
  String all(int n, String noun, String state) => _all(n, noun, state, brief: brief);
  String line(String text) => brief ? '${text[0].toLowerCase()}${text.substring(1)}' : text;
  switch (section) {
    case 'pods':
      final n = d.count('pods', 'total') - d.count('pods', 'completed');
      return n > 0 ? all(n, 'pod', 'healthy') : null;
    case 'workloads':
      final n = d.count('deployments', 'total') + d.count('statefulSets', 'total') + d.count('daemonSets', 'total');
      return n > 0 ? all(n, 'workload', 'healthy') : null;
    case 'jobs':
      final n = d.count('jobs', 'total') + d.count('cronJobs', 'total');
      return n > 0 ? line('No failing jobs') : null;
    case 'nodes':
      final n = d.count('nodes', 'total');
      return n > 0 ? all(n, 'node', 'ready') : null;
    case 'storage':
      final n = d.count('pvcs', 'total');
      return n > 0 ? all(n, 'PVC', 'bound') : null;
    case 'network':
      final n = d.count('gateways', 'total') + d.count('routes', 'total');
      return n > 0 ? line('Gateways and routes healthy') : null;
    case 'argocd':
      final n = d.count('argoApps', 'total');
      return n > 0 ? all(n, 'Argo CD app', 'healthy') : null;
  }
  return null;
}

/// Areas in display order: the built-in ones, then modules' and loading ones.
List<String> _sections(OverviewData data) => [
      ..._areaOrder,
      ...{for (final c in data.categories) c.section, ...data.loadingSections}.where((s) => !_areaOrder.contains(s)).toList()..sort(),
    ];

/// The lines of every problem-free, loaded area ("All 7 workloads healthy").
List<String> _healthyLines(OverviewData data, {bool brief = false}) => [
      for (final s in _sections(data))
        if (!data.categories.any((c) => c.section == s) && !data.loadingSections.contains(s)) ?_healthyLine(data, s, brief: brief),
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
    final loading = data.loadingSections;
    final groups = <Widget>[];
    final weights = <int>[];
    for (final s in _sections(data)) {
      final cats = data.categories.where((c) => c.section == s).toList();
      final pending = loading.contains(s);
      if (cats.isEmpty && !pending) continue;
      groups.add(_AreaGroup(
        section: s,
        problems: [for (final c in cats) if (c.severity != IssueSeverity.info) c],
        info: [for (final c in cats) if (c.severity == IssueSeverity.info) c],
        pending: pending,
        data: data,
        selected: selected,
        onSelect: onSelect,
        scope: scope,
      ));
      weights.add(cats.length + (pending ? 1 : 0) + 1);
    }
    if (groups.isEmpty) return const SizedBox.shrink();
    final allHealthy = _allHealthy(data);
    final tally = _Tally(data);
    return EditorialSection(
      title: allHealthy ? 'Worth a look' : 'Needs attention',
      collapsible: false,
      trailing: tally.problems == 0 ? null : Text(plural(tally.problems, 'problem')),
      child: AttentionList(groups: groups, weights: weights),
    );
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

  /// "▎4  CrashLoopBackOff · 4 pods, 2 workloads". Click goes to what the
  /// row names; the count filters the Issues list, as does the whole row
  /// when it has nowhere to go.
  Widget _row(BuildContext context, OverviewCategory c) {
    final target = rowTarget(data, c);
    final isSelected = selected == c.id;
    void filter() => onSelect(c.id);
    // A kind the cluster doesn't serve falls back to the Issues filter.
    final VoidCallback? open = target == null ? null : () => openOverviewTarget(context, target, scope) ? null : onSelect(c.id);
    return AttentionRow(
      key: ValueKey('area-row-${c.id}'),
      severity: c.severity.badge,
      count: '${c.count}',
      label: c.label,
      detail: categorySublabel(data, c),
      selected: isSelected,
      onTap: open ?? filter,
      onCount: open == null ? null : filter,
      countKey: ValueKey('area-count-${c.id}'),
      countTooltip: open == null ? (isSelected ? 'Show all issues' : 'Show only ${c.label}') : (isSelected ? 'Show all issues' : 'Show these in Issues'),
      chevron: open != null,
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
    final rows = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (problems.isEmpty && !pending && healthyLine != null)
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
          child: HealthyLines(lines: [healthyLine], style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
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
    return AttentionGroup(
      key: ValueKey('area-$section'),
      icon: _sectionIcon(section),
      title: sectionLabel(section),
      count: worst == null ? null : total,
      countColor: worst == null ? null : issueColor(context, worst),
      onTitleTap: title == null ? null : () => openOverviewTarget(context, title, scope),
      titleKey: ValueKey('area-title-$section'),
      rows: rows,
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
        return evenGrid([for (final n in shown) _NodeCard(node: n, showRequests: showRequests)], cols, gap: 28, runGap: 14);
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
    final sev = !node.ready ? Severity.error : (node.pressure.isNotEmpty || node.cordoned ? Severity.warn : Severity.ok);
    final c = severityColor(context, sev);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final status = [if (!node.ready) 'NotReady', ...node.pressure, if (node.cordoned) 'Cordoned'];
    final r = node.resources;
    // Unboxed: a hairline down the left, in the node's colour when it
    // isn't plainly ready.
    return HairlineCell(
      accent: sev == Severity.ok ? null : c,
      onTap: () => openObject(context, ObjectRef(kind: 'Node', name: node.name)),
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
        Expanded(child: HairlineBar(frac: frac, color: meterColor(context, frac), height: 4)),
        SizedBox(
          width: 36,
          child: Text(formatPercent(frac), textAlign: TextAlign.right, style: small?.copyWith(color: percentColor(context, frac))),
        ),
      ]),
    );
  }
}
