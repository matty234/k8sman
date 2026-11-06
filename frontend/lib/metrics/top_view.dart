import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../panels/cluster/logic.dart' show PodResources, podResources, isTerminalPod;
import '../state/app_state.dart';
import '../state/cluster_error.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../ui/widgets/partial_banner.dart';
import '../util/k8s.dart';
import 'cache.dart';
import 'metrics_api.dart';
import 'quantity.dart';
import 'sortable_table.dart';
import 'widgets.dart';
import '../state/poller.dart';

/// A node's usage joined with its allocatable.
class TopNode {
  final String name;
  final Usage usage;
  final double? cpuAllocatable;
  final double? memAllocatable;
  const TopNode(this.name, this.usage, {this.cpuAllocatable, this.memAllocatable});
  double? get cpuFrac => fraction(usage.cpuMillis, cpuAllocatable);
  double? get memFrac => fraction(usage.memoryBytes, memAllocatable);
}

/// A pod's usage joined with its requests and limits (null when the pod has
/// none, e.g. no limits set).
class TopPod {
  final String name;
  final String namespace;
  final Usage usage;
  final PodResources? resources;
  const TopPod(this.name, this.namespace, this.usage, this.resources);

  double? _of(double used, double? base) => base == null || base <= 0 ? null : used / base;
  double? get cpuReqFrac => _of(usage.cpuMillis, resources?.cpuRequest);
  double? get cpuLimFrac => _of(usage.cpuMillis, resources?.cpuLimit);
  double? get memReqFrac => _of(usage.memoryBytes, resources?.memRequest);
  double? get memLimFrac => _of(usage.memoryBytes, resources?.memLimit);
}

/// Joins pod metrics with pod specs (pure, for tests). Pods without a
/// matching spec keep null resources.
List<TopPod> joinTopPods(List<PodUsage> usage, List<Json> pods) {
  final specs = {
    for (final p in pods) '${dig(p, ['metadata', 'namespace'])}/${dig(p, ['metadata', 'name'])}': p,
  };
  return [
    for (final u in usage)
      TopPod(u.name, u.namespace, u.usage, specs[u.key] == null || isTerminalPod(specs[u.key]!) ? null : limitAwareResources(specs[u.key]!)),
  ];
}

/// [podResources], but a limit only counts when every container sets one
/// (otherwise the pod is unbounded and "% of limit" would mislead).
PodResources limitAwareResources(Json pod) {
  final r = podResources(pod);
  final cs = asMapList(dig(pod, ['spec', 'containers']));
  bool all(String res) => cs.isNotEmpty && cs.every((c) => dig(c, ['resources', 'limits', res]) != null);
  return PodResources(cpuRequest: r.cpuRequest, memRequest: r.memRequest, cpuLimit: all('cpu') ? r.cpuLimit : 0, memLimit: all('memory') ? r.memLimit : 0);
}

List<TopNode> joinTopNodes(List<NodeUsage> usage, List<Json> nodes) {
  final alloc = {
    for (final n in nodes) '${dig(n, ['metadata', 'name'])}': asMap(dig(n, ['status', 'allocatable'])),
  };
  return [
    for (final u in usage)
      TopNode(u.name, u.usage, cpuAllocatable: parseCpuMillis(alloc[u.name]?['cpu']), memAllocatable: parseBytes(alloc[u.name]?['memory'])),
  ];
}

/// Top nodes and pods by usage, following the namespace filter, refreshed
/// every 15s.
class TopView extends StatefulWidget {
  final NamespaceScope scope;
  final MetricsApiStatus? status;
  const TopView({super.key, required this.scope, this.status});

  @override
  State<TopView> createState() => _TopViewState();
}

class _TopViewState extends State<TopView> with AutomaticKeepAliveClientMixin, PollingState {
  List<TopNode>? _nodes;
  List<TopPod>? _pods;
  Map<String, ClusterError> _partial = const {};
  Object? _error;
  DateTime? _updated;

  ApiClient get _api => context.read<ApiClient>();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    poll(const Duration(seconds: 15), () async {
      await _load();
      return _error == null;
    });
  }

  Future<void> _load() async {
    final cache = MetricsCache.of(_api);
    try {
      final r = await Future.wait<Object>([
        cache.nodes(),
        cache.pods(widget.scope.param),
        _api.items(const ResourceRef(resource: 'nodes')),
        _api.itemsWithPartial(const ResourceRef(resource: 'pods'), scope: widget.scope),
      ]);
      final podList = r[3] as ({List<Json> items, Object? partialErrors});
      if (!mounted) return;
      setState(() {
        _nodes = joinTopNodes(r[0] as List<NodeUsage>, r[2] as List<Json>);
        _pods = joinTopPods(r[1] as List<PodUsage>, podList.items);
        _partial = parsePartialErrors(podList.partialErrors);
        _error = null;
        _updated = DateTime.now();
      });
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  void _open(String kind, String name, String? namespace) {
    final app = context.read<AppState>();
    final t = app.typeFor('', kind);
    if (t != null) app.openDetail(DetailTarget(type: t, name: name, namespace: t.namespaced ? namespace : null));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final app = context.watch<AppState>();
    final e = _error;
    if (e != null && _nodes == null) {
      if (e is MetricsUnavailable) {
        return Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MetricsUnavailableNote(e),
              const SizedBox(height: 6),
              Text(e.message, style: hint),
            ],
          ),
        );
      }
      return Padding(padding: const EdgeInsets.all(16), child: InlineMessage('$e', isError: true));
    }
    final nodes = _nodes, pods = _pods;
    if (nodes == null || pods == null) return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
    final detail = app.detail;
    bool isSelected(String kind, String name, String? ns) => detail?.type.kind == kind && detail?.name == name && (detail?.namespace ?? '') == (ns ?? '');

    Widget pct(double? f) =>
        Text(formatPercent(f), style: monoStyle(context, size: 11.5, color: percentColor(context, f) ?? (f == null ? theme.hintColor : null)));
    Widget mono(String s) => Text(s, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5));
    Comparable<Object>? n(double? v) => v;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      children: [
        if (_partial.isNotEmpty) ...[PartialBanner(errors: _partial), const SizedBox(height: 10)],
        _SectionTitle('Nodes', '${nodes.length}', trailing: _updated == null ? null : 'updated ${formatAge(_updated!.toUtc())} ago'),
        SortableTable<TopNode>(
          rows: nodes,
          initialSort: 1,
          initialAscending: false,
          onTap: (r) => _open('Node', r.name, null),
          selected: (r) => isSelected('Node', r.name, null),
          columns: [
            MetricColumn(
              label: 'Name',
              sortKey: (r) => r.name,
              cell: (c, r) => Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
            ),
            MetricColumn(label: 'CPU', width: 76, numeric: true, sortKey: (r) => r.usage.cpuMillis, cell: (c, r) => mono(formatCpuUsage(r.usage.cpuMillis))),
            MetricColumn(
              label: 'CPU %',
              width: 64,
              numeric: true,
              hideBelow: 420,
              sortKey: (r) => n(r.cpuFrac),
              tooltip: 'of allocatable',
              cell: (c, r) => pct(r.cpuFrac),
            ),
            MetricColumn(
              label: 'Memory',
              width: 86,
              numeric: true,
              sortKey: (r) => r.usage.memoryBytes,
              cell: (c, r) => mono(formatBytes(r.usage.memoryBytes)),
            ),
            MetricColumn(
              label: 'Mem %',
              width: 64,
              numeric: true,
              hideBelow: 420,
              sortKey: (r) => n(r.memFrac),
              tooltip: 'of allocatable',
              cell: (c, r) => pct(r.memFrac),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _SectionTitle('Pods', '${pods.length}${widget.scope.isAll ? '' : ' in ${widget.scope.label}'}'),
        if (pods.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('No pod samples', style: hint),
          )
        else
          SortableTable<TopPod>(
            rows: pods,
            initialSort: 1,
            initialAscending: false,
            limit: 50,
            onTap: (r) => _open('Pod', r.name, r.namespace),
            selected: (r) => isSelected('Pod', r.name, r.namespace),
            columns: [
              MetricColumn(
                label: 'Pod',
                sortKey: (r) => '${r.namespace}/${r.name}',
                cell: (c, r) => Text.rich(
                  TextSpan(
                    children: [
                      if (widget.scope.single == null)
                        TextSpan(
                          text: '${r.namespace}/',
                          style: TextStyle(color: theme.hintColor),
                        ),
                      TextSpan(text: r.name),
                    ],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              MetricColumn(label: 'CPU', width: 70, numeric: true, sortKey: (r) => r.usage.cpuMillis, cell: (c, r) => mono(formatCpuUsage(r.usage.cpuMillis))),
              MetricColumn(
                label: '% req',
                width: 60,
                numeric: true,
                hideBelow: 470,
                sortKey: (r) => n(r.cpuReqFrac),
                tooltip: 'CPU of requests',
                cell: (c, r) => pct(r.cpuReqFrac),
              ),
              MetricColumn(
                label: '% lim',
                width: 60,
                numeric: true,
                hideBelow: 760,
                sortKey: (r) => n(r.cpuLimFrac),
                tooltip: 'CPU of limits',
                cell: (c, r) => pct(r.cpuLimFrac),
              ),
              MetricColumn(
                label: 'Memory',
                width: 80,
                numeric: true,
                sortKey: (r) => r.usage.memoryBytes,
                cell: (c, r) => mono(formatBytes(r.usage.memoryBytes)),
              ),
              MetricColumn(
                label: '% req',
                width: 60,
                numeric: true,
                hideBelow: 560,
                sortKey: (r) => n(r.memReqFrac),
                tooltip: 'Memory of requests',
                cell: (c, r) => pct(r.memReqFrac),
              ),
              MetricColumn(
                label: '% lim',
                width: 60,
                numeric: true,
                hideBelow: 660,
                sortKey: (r) => n(r.memLimFrac),
                tooltip: 'Memory of limits',
                cell: (c, r) => pct(r.memLimFrac),
              ),
            ],
          ),
        if (e != null) Padding(padding: const EdgeInsets.only(top: 8), child: InlineMessage('Refresh failed: $e', isError: true)),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  final String count;
  final String? trailing;
  const _SectionTitle(this.title, this.count, {this.trailing});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Text(title, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(count, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint),
          ),
          if (trailing != null) Text(trailing!, style: hint),
        ],
      ),
    );
  }
}
