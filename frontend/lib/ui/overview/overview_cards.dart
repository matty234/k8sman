/// The Overview's summary blocks: stat blocks, cluster capacity, problem
/// cards per area, the all-healthy banner and node cards.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../metrics/metrics_api.dart' show Usage;
import '../../metrics/quantity.dart' show formatPercent;
import '../../metrics/widgets.dart' show meterColor, percentColor;
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../../modules/modules.dart' show enabledPages;
import 'capacity_history.dart';
import 'overview_api.dart';
import 'overview_nav.dart';
import 'overview_widgets.dart' show SkeletonBar, issueColor, issueIcon, openObject;

const _gap = 10.0;

/// The quiet container every Overview card uses.
BoxDecoration _panel(BuildContext context) => BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerLow,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: AppColors.of(context).separator),
    );

const _tabular = [FontFeature.tabularFigures()];

/// Lays [children] out in rows of [cols] equal-width cells, each row as tall
/// as its tallest cell.
Widget _grid(List<Widget> children, int cols) {
  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    for (var r = 0; r < children.length; r += cols) ...[
      if (r > 0) const SizedBox(height: _gap),
      IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var c = 0; c < cols; c++) ...[
            if (c > 0) const SizedBox(width: _gap),
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
    final track = Theme.of(context).colorScheme.surfaceContainerHighest;
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
// Stat blocks: ready/total per type
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
  Widget build(BuildContext context) {
    final stats = _stats();
    if (stats.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(builder: (context, box) {
      final fit = ((box.maxWidth + _gap) / (128 + _gap)).floor().clamp(1, 8);
      final n = stats.length;
      // A few blocks stay small and left-aligned rather than stretching;
      // more than fit spread evenly over the rows.
      final cols = n <= fit ? (n >= fit - 2 ? n : fit) : (n / (n / fit).ceil()).ceil();
      return _grid([for (final s in stats) _StatBlock(stat: s, scope: scope)], cols);
    });
  }
}

class _StatBlock extends StatelessWidget {
  final _Stat stat;
  final NamespaceScope scope;
  const _StatBlock({required this.stat, required this.scope});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final good = stat.good ?? 0;
    final total = stat.total ?? 0;
    final frac = total == 0 ? 1.0 : good / total;
    // Red only when none are ready/bound/succeeded (an outage); partly
    // ready is amber, so a busy cluster isn't a wall of red.
    final color = !stat.bad ? theme.colorScheme.onSurface.withValues(alpha: 0.28) : issueColor(context, good == 0 && total > 0 ? IssueSeverity.critical : IssueSeverity.warning);
    final target = stat.target;
    if (stat.pending || target == null) return _block(context, color, frac, hovered: false);
    return Hoverable(
      key: ValueKey('stat-${stat.label}'),
      onTap: () => openOverviewTarget(context, target, scope),
      builder: (hovered) => _block(context, color, frac, hovered: hovered),
    );
  }

  Widget _block(BuildContext context, Color color, double frac, {required bool hovered}) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final faint = AppColors.of(context).faint;
    final good = stat.good ?? 0;
    final total = stat.total ?? 0;
    return Container(
      key: stat.pending ? ValueKey('pending-inventory-${stat.label}') : null,
      decoration: hovered ? _panel(context).copyWith(color: AppColors.of(context).hover) : _panel(context),
      padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        SizedBox(
          height: 24,
          child: stat.pending
              ? const Align(alignment: Alignment.centerLeft, child: SkeletonBar(width: 40, height: 16))
              : Text.rich(
                  TextSpan(children: [
                    TextSpan(
                      text: '$good',
                      style: theme.textTheme.headlineSmall?.copyWith(fontFeatures: _tabular, color: stat.bad ? color : null, height: 1.25),
                    ),
                    TextSpan(text: '/$total', style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor, fontFeatures: _tabular)),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
        ),
        const SizedBox(height: 2),
        Text.rich(
          TextSpan(children: [
            TextSpan(text: stat.label),
            if (stat.note != null) TextSpan(text: ' · ${stat.note}', style: TextStyle(color: faint)),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: hint,
        ),
        const SizedBox(height: 7),
        stat.pending ? const SkeletonBar(height: 3) : _Bar(frac: frac, color: color),
      ]),
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
    final bars = LayoutBuilder(builder: (context, box) {
      final wide = box.maxWidth >= 620;
      final children = [cpu ?? const _PendingMeter(), mem ?? const _PendingMeter()];
      if (wide) {
        return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(child: children[0]),
          const SizedBox(width: 28),
          Expanded(child: children[1]),
        ]);
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [children[0], const SizedBox(height: 10), children[1]]);
    });
    return Container(
      key: c == null ? const ValueKey('pending-capacity') : null,
      decoration: _panel(context),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      child: c == null ? bars : ClusterHistory(capacity: c, fallback: bars),
    );
  }
}

class _PendingMeter extends StatelessWidget {
  const _PendingMeter();

  @override
  Widget build(BuildContext context) => const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SkeletonBar(width: 160, height: 12),
        SizedBox(height: 9),
        SkeletonBar(height: 5),
      ]);
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
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontFeatures: _tabular);
    final req = allocatable > 0 ? requested / allocatable : null;
    final use = allocatable > 0 && used != null ? used! / allocatable : null;
    // Colour follows the larger of the two (thresholds only; neutral below).
    final color = meterColor(context, [req ?? 0, use ?? 0].reduce((a, b) => a > b ? a : b));
    return Tooltip(
      message: [
        '$label requested $where: $amount${req == null ? '' : ' (${formatPercent(req)})'}',
        if (usedText != null) 'In use: $usedText${use == null ? '' : ' (${formatPercent(use)})'}',
      ].join('\n'),
      waitDuration: const Duration(milliseconds: 400),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.baseline, textBaseline: TextBaseline.alphabetic, children: [
          Text(label, style: theme.textTheme.titleSmall),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: amount, style: TextStyle(color: theme.colorScheme.onSurface)),
                const TextSpan(text: ' requested'),
                if (req != null) ...[
                  const TextSpan(text: ' · '),
                  TextSpan(text: formatPercent(req), style: TextStyle(color: percentColor(context, req) ?? theme.colorScheme.onSurface, fontWeight: FontWeight.w600)),
                ],
                if (usedText != null) TextSpan(text: '   $usedText in use${use == null ? '' : ' · ${formatPercent(use)}'}'),
              ]),
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: hint,
            ),
          ),
        ]),
        const SizedBox(height: 7),
        _Bar(frac: use ?? req ?? 0, under: use == null ? null : req, color: color, height: 5),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Problem cards per area
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

/// One card per area (Pods, Workloads, Jobs, Nodes, Storage, then modules)
/// that has problems or is still loading; problem-free areas fold into one
/// quiet line. With nothing wrong and nothing loading, a calm banner.
class AreaCards extends StatelessWidget {
  final OverviewData data;
  final String? selected;
  final ValueChanged<String> onSelect;
  final DateTime? checkedAt;

  /// The Overview's namespaces: tables opened from a card show these.
  final NamespaceScope scope;
  const AreaCards({super.key, required this.data, required this.selected, required this.onSelect, this.checkedAt, this.scope = NamespaceScope.all});

  @override
  Widget build(BuildContext context) {
    final loading = data.loadingSections;
    final sections = <String>[
      ..._areaOrder,
      ...{for (final c in data.categories) c.section, ...loading}.where((s) => !_areaOrder.contains(s)).toList()..sort(),
    ];
    final cards = <Widget>[];
    final healthy = <String>[];
    for (final s in sections) {
      final cats = data.categories.where((c) => c.section == s).toList();
      final pending = loading.contains(s);
      if (cats.isEmpty && !pending) {
        final line = _healthyLine(data, s);
        if (line != null) healthy.add(line);
        continue;
      }
      cards.add(_AreaCard(
        section: s,
        problems: [for (final c in cats) if (c.severity != IssueSeverity.info) c],
        info: [for (final c in cats) if (c.severity == IssueSeverity.info) c],
        pending: pending,
        healthyLine: _healthyLine(data, s),
        data: data,
        selected: selected,
        onSelect: onSelect,
        scope: scope,
      ));
    }
    // Never "All healthy" while a source is loading: its problems are unknown.
    final allHealthy = loading.isEmpty && !data.categories.any((c) => c.severity != IssueSeverity.info);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (allHealthy) ...[
        _HealthyBanner(checkedAt: checkedAt, lines: healthy),
        if (cards.isNotEmpty) const SizedBox(height: _gap),
      ],
      if (cards.isNotEmpty)
        LayoutBuilder(builder: (context, box) {
          // At least two columns where they fit, so a lone card takes half
          // the width rather than stretching across the page.
          final fit = (box.maxWidth / 300).floor().clamp(1, 4);
          final cols = fit >= 2 ? cards.length.clamp(2, fit) : 1;
          return _grid(cards, cols);
        }),
      if (!allHealthy && healthy.isNotEmpty) ...[
        const SizedBox(height: 10),
        _HealthyLines(lines: healthy),
      ],
    ]);
  }
}

class _HealthyLines extends StatelessWidget {
  final List<String> lines;
  const _HealthyLines({required this.lines});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = severityColor(context, Severity.ok).withValues(alpha: 0.8);
    return Wrap(spacing: 18, runSpacing: 4, children: [
      for (final l in lines)
        Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.check, size: 13, color: ok),
          const SizedBox(width: 5),
          Text(l, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ]),
    ]);
  }
}

class _HealthyBanner extends StatelessWidget {
  final DateTime? checkedAt;
  final List<String> lines;
  const _HealthyBanner({required this.checkedAt, required this.lines});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ok = severityColor(context, Severity.ok);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
      decoration: BoxDecoration(
        color: ok.withValues(alpha: theme.brightness == Brightness.dark ? 0.07 : 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ok.withValues(alpha: 0.22)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.check_circle, size: 16, color: ok),
          const SizedBox(width: 8),
          Text('All healthy', style: theme.textTheme.titleSmall),
          if (checkedAt != null) ...[
            Text(' · checked ', style: hint),
            AgeText(checkedAt!.toUtc().toIso8601String(), suffix: ' ago'),
          ],
        ]),
        if (lines.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 24, top: 3),
            child: Text(lines.join(' · '), style: hint),
          ),
      ]),
    );
  }
}

class _AreaCard extends StatelessWidget {
  final String section;
  final List<OverviewCategory> problems;
  final List<OverviewCategory> info;
  final bool pending;
  final String? healthyLine;
  final OverviewData data;
  final String? selected;
  final ValueChanged<String> onSelect;
  final NamespaceScope scope;
  const _AreaCard({
    required this.section,
    required this.problems,
    required this.info,
    required this.pending,
    required this.healthyLine,
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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final worst = problems.isEmpty ? null : problems.map((c) => c.severity).reduce((a, b) => a.index <= b.index ? a : b);
    final total = problems.fold<int>(0, (n, c) => n + c.count);
    final ok = severityColor(context, Severity.ok).withValues(alpha: 0.8);
    final page = enabledPages(context.read<AppState>()).any((p) => p.view.name == section) ? OverviewTarget.page(MainView(section)) : null;
    final title = titleTarget(data, section) ?? page;
    final titleRow = Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(_sectionIcon(section), size: 15, color: theme.hintColor),
      const SizedBox(width: 7),
      Flexible(child: Text(sectionLabel(section), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall)),
    ]);
    return Container(
      key: ValueKey('area-$section'),
      decoration: _panel(context),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(6, 0, 4, 4),
          child: Row(children: [
            Expanded(
              child: Align(
                alignment: Alignment.centerLeft,
                child: title == null
                    ? titleRow
                    : Hoverable(
                        key: ValueKey('area-title-$section'),
                        onTap: () => openOverviewTarget(context, title, scope),
                        builder: (hovered) => Tooltip(
                          message: 'Open ${sectionLabel(section)}',
                          waitDuration: const Duration(milliseconds: 600),
                          child: Row(mainAxisSize: MainAxisSize.min, children: [
                            Flexible(
                              child: DefaultTextStyle.merge(
                                style: TextStyle(decoration: hovered ? TextDecoration.underline : null, decorationColor: theme.hintColor),
                                child: titleRow,
                              ),
                            ),
                            Icon(Icons.chevron_right, size: 15, color: hovered ? theme.hintColor : Colors.transparent),
                          ]),
                        ),
                      ),
              ),
            ),
            if (worst != null) ...[
              Icon(issueIcon(worst), size: 14, color: issueColor(context, worst)),
              const SizedBox(width: 4),
              Text('$total', style: theme.textTheme.labelLarge?.copyWith(color: issueColor(context, worst), fontWeight: FontWeight.w600, fontFeatures: _tabular)),
            ],
          ]),
        ),
        if (problems.isEmpty && !pending && healthyLine != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 3, 6, 3),
            child: Row(children: [
              Icon(Icons.check, size: 13, color: ok),
              const SizedBox(width: 6),
              Expanded(child: Text(healthyLine!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
            ]),
          ),
        for (final c in problems) _row(context, c),
        if (pending)
          Padding(
            key: ValueKey('pending-tile-$section'),
            padding: const EdgeInsets.fromLTRB(6, 5, 6, 5),
            child: Row(children: [
              const SkeletonBar(width: 90, height: 10),
              const SizedBox(width: 8),
              Text('Checking…', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ]),
          ),
        for (final c in info) _row(context, c),
      ]),
    );
  }
}

/// "● 4  CrashLoopBackOff · 4 pods, 2 workloads". Click goes to what the row
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
      textAlign: TextAlign.right,
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
        padding: const EdgeInsets.fromLTRB(6, 3, 6, 3),
        decoration: BoxDecoration(
          color: selected ? colors.selection : (hovered ? colors.hover : null),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(children: [
          Container(
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: info ? null : c,
              border: info ? Border.all(color: colors.faint) : null,
            ),
          ),
          const SizedBox(width: 8),
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
          const SizedBox(width: 8),
          // One line: the detail is what an ellipsis cuts first.
          Expanded(
            child: Text.rich(
              TextSpan(children: [
                TextSpan(text: category.label, style: TextStyle(color: info ? theme.hintColor : theme.colorScheme.onSurface)),
                if (sublabel.isNotEmpty) TextSpan(text: ' · $sublabel', style: hint),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodySmall,
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
        final cols = (box.maxWidth / 230).floor().clamp(1, 6);
        return _grid([for (final n in shown) _NodeCard(node: n, showRequests: showRequests)], cols);
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
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: colors.separator)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => openObject(context, ObjectRef(kind: 'Node', name: node.name)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 9, 12, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Tooltip(
                message: status.isEmpty ? 'Ready' : status.join(', '),
                child: Container(width: 7, height: 7, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
              ),
              const SizedBox(width: 8),
              Expanded(child: Text(node.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
            ]),
            const SizedBox(height: 2),
            Padding(
              padding: const EdgeInsets.only(left: 15),
              child: Text.rich(
                TextSpan(children: [
                  if (status.isNotEmpty) TextSpan(text: '${status.join(', ')} · ', style: TextStyle(color: c)),
                  if (node.roles.isNotEmpty) TextSpan(text: '${node.roles.join(', ')} · '),
                  TextSpan(text: plural(node.pods, 'pod')),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: hint,
              ),
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
