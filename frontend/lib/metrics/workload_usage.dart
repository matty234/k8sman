import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../panels/cluster/logic.dart' show PodResources, podResources, isTerminalPod;
import '../panels/panel.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'cache.dart';
import 'metrics_api.dart';
import 'pod_usage.dart' show usageAgainst;
import 'quantity.dart';
import 'widgets.dart';
import '../state/poller.dart';

/// "Usage" section for a workload panel (Deployment, StatefulSet, DaemonSet):
/// the summed usage of its pods vs their requests, the per-pod spread and the
/// busiest pods. Drop into `buildSections` with one line.
Widget workloadUsageSection(PanelContext ctx) => DetailSection(
  title: 'Usage',
  icon: Icons.query_stats,
  child: WorkloadUsage(key: ValueKey('usage-${ctx.uid}'), api: ctx.api, namespace: ctx.namespace ?? '', selector: selectorToString(ctx.spec['selector'])),
);

/// One pod's usage joined with its requests/limits.
class PodUsageRow {
  final Json pod;
  final PodResources resources;
  final Usage? usage;
  const PodUsageRow(this.pod, this.resources, this.usage);
  String get name => dig<String>(pod, ['metadata', 'name']) ?? '';
  String? get namespace => dig<String>(pod, ['metadata', 'namespace']);
}

/// Totals over pods that have a sample (requests over the same pods, so the
/// percentage compares like with like).
class WorkloadTotals {
  final int pods;
  final int sampled;
  final Usage used;
  final PodResources resources;
  const WorkloadTotals({required this.pods, required this.sampled, required this.used, required this.resources});

  static WorkloadTotals of(List<PodUsageRow> rows) {
    var used = Usage.zero;
    var res = const PodResources();
    var sampled = 0;
    for (final r in rows) {
      final u = r.usage;
      if (u == null) continue;
      sampled++;
      used = used + u;
      res = res + r.resources;
    }
    return WorkloadTotals(pods: rows.length, sampled: sampled, used: used, resources: res);
  }
}

class WorkloadUsage extends StatefulWidget {
  final ApiClient api;
  final String namespace;
  final String selector;
  const WorkloadUsage({super.key, required this.api, required this.namespace, required this.selector});

  @override
  State<WorkloadUsage> createState() => _WorkloadUsageState();
}

class _WorkloadUsageState extends State<WorkloadUsage> with PollingState {
  List<PodUsageRow>? _rows;
  Object? _metricsError;
  Object? _error;
  bool _showAll = false;

  @override
  void initState() {
    super.initState();
    _load();
    poll(const Duration(seconds: 15), () async {
      await _load();
      return _error == null;
    });
  }

  @override
  void didUpdateWidget(WorkloadUsage old) {
    super.didUpdateWidget(old);
    if (old.selector != widget.selector || old.namespace != widget.namespace) _load();
  }

  Future<void> _load() async {
    if (widget.selector.isEmpty) return;
    try {
      final pods = await widget.api.items(
        const ResourceRef(resource: 'pods'),
        namespace: widget.namespace,
        labelSelector: widget.selector,
      );
      Object? metricsError;
      var usage = <String, PodUsage>{};
      try {
        usage = {for (final u in await MetricsCache.of(widget.api).pods(widget.namespace)) u.name: u};
      } catch (e) {
        metricsError = e;
      }
      if (!mounted) return;
      setState(() {
        _rows = [
          for (final p in pods)
            if (!isTerminalPod(p)) PodUsageRow(p, podResources(p), usage[dig<String>(p, ['metadata', 'name'])]?.usage),
        ]..sort((a, b) => (b.usage?.cpuMillis ?? -1).compareTo(a.usage?.cpuMillis ?? -1));
        _metricsError = metricsError;
        _error = null;
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    if (widget.selector.isEmpty) return Text('No selector', style: hint);
    if (_error != null) return InlineMessage('$_error', isError: true);
    final rows = _rows;
    if (rows == null) {
      return const SizedBox(
        height: 24,
        child: Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))),
      );
    }
    if (_metricsError != null) return MetricsUnavailableNote(_metricsError);
    if (rows.isEmpty) return Text('No running pods', style: hint);
    final t = WorkloadTotals.of(rows);
    if (t.sampled == 0) return Text('No samples yet for these pods', style: hint);
    final r = t.resources;
    final cpuSpread = Spread.of([for (final x in rows) ?x.usage?.cpuMillis]);
    final memSpread = Spread.of([for (final x in rows) ?x.usage?.memoryBytes]);
    final shown = _showAll ? rows : rows.take(6).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('${t.sampled == t.pods ? '${t.pods}' : '${t.sampled} of ${t.pods}'} pod${t.pods == 1 ? '' : 's'} · total vs their requests', style: hint),
        const SizedBox(height: 4),
        ResourceMeter(
          label: 'CPU',
          labelWidth: 64,
          valueWidth: 150,
          used: t.used.cpuMillis,
          requested: r.cpuRequest,
          percentBase: r.cpuRequest > 0 ? r.cpuRequest : null,
          percentOf: 'requests',
          valueText: usageAgainst(formatCpuUsage(t.used.cpuMillis), request: r.cpuRequest > 0 ? formatCpu(r.cpuRequest) : null),
          format: (v) => formatCpuUsage(v),
        ),
        ResourceMeter(
          label: 'Memory',
          labelWidth: 64,
          valueWidth: 150,
          used: t.used.memoryBytes,
          requested: r.memRequest,
          percentBase: r.memRequest > 0 ? r.memRequest : null,
          percentOf: 'requests',
          valueText: usageAgainst(formatBytes(t.used.memoryBytes), request: r.memRequest > 0 ? formatBytes(r.memRequest) : null),
          format: formatBytes,
        ),
        if (t.sampled > 1 && cpuSpread != null && memSpread != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              'per pod  CPU ${formatCpuUsage(cpuSpread.min)} – ${formatCpuUsage(cpuSpread.median)} – ${formatCpuUsage(cpuSpread.max)}'
              '  ·  Memory ${formatBytes(memSpread.min)} – ${formatBytes(memSpread.median)} – ${formatBytes(memSpread.max)}'
              '  (min – median – max)',
              style: hint?.copyWith(fontSize: 11),
            ),
          ),
        const SizedBox(height: 8),
        _PodRow.header(context),
        for (final row in shown) _PodRow(row),
        if (rows.length > shown.length)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(onPressed: () => setState(() => _showAll = true), child: Text('Show all ${rows.length} pods')),
          ),
      ],
    );
  }
}

/// pod | CPU | % req | Memory | % req
class _PodRow extends StatelessWidget {
  final PodUsageRow? row;
  const _PodRow(this.row);
  static Widget header(BuildContext context) => const _PodRow(null);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final head = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600);
    final r = row;
    Widget num(String text, {Color? color, TextStyle? style}) => Text(
      text,
      textAlign: TextAlign.right,
      overflow: TextOverflow.clip,
      maxLines: 1,
      style: style ?? monoStyle(context, size: 11, color: color),
    );
    final u = r?.usage;
    final cpuFrac = r == null ? null : fraction(u?.cpuMillis, r.resources.cpuRequest);
    final memFrac = r == null ? null : fraction(u?.memoryBytes, r.resources.memRequest);
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 3),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: theme.dividerColor.withValues(alpha: r == null ? 1 : 0.4)),
        ),
      ),
      child: Row(
        children: [
          Expanded(
            child: r == null
                ? Text('POD', style: head)
                : Align(
                    alignment: Alignment.centerLeft,
                    child: ResourceLink(
                      ObjectRef(kind: 'Pod', name: r.name, namespace: r.namespace),
                      label: r.name,
                    ),
                  ),
          ),
          SizedBox(width: 58, child: r == null ? num('CPU', style: head) : num(u == null ? '—' : formatCpuUsage(u.cpuMillis))),
          SizedBox(
            width: 44,
            child: r == null ? num('%REQ', style: head) : num(formatPercent(cpuFrac), color: percentColor(context, cpuFrac) ?? theme.hintColor),
          ),
          SizedBox(width: 70, child: r == null ? num('MEMORY', style: head) : num(u == null ? '—' : formatBytes(u.memoryBytes))),
          SizedBox(
            width: 44,
            child: r == null ? num('%REQ', style: head) : num(formatPercent(memFrac), color: percentColor(context, memFrac) ?? theme.hintColor),
          ),
        ],
      ),
    );
  }
}
