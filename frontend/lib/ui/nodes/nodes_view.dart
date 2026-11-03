import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../metrics/cache.dart';
import '../../metrics/metrics_api.dart';
import '../../metrics/node_usage.dart';
import '../../metrics/widgets.dart';
import '../../panels/cluster/logic.dart';
import '../../panels/cluster/widgets.dart' show UsageBar;
import '../../panels/panel.dart';
import '../../state/app_state.dart';
import '../../state/poller.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Cluster nodes at a glance: health, allocation and quick cordon actions.
/// Clicking a card opens the full Node panel in the sidebar.
class NodesView extends StatefulWidget {
  const NodesView({super.key});

  @override
  State<NodesView> createState() => _NodesViewState();
}

/// One node plus the pods scheduled on it.
class NodeSummary {
  final Json node;
  final NodeAllocation alloc;
  const NodeSummary(this.node, this.alloc);

  String get name => dig<String>(node, ['metadata', 'name']) ?? '';
  Json get labels => asMap(dig(node, ['metadata', 'labels']));
  Json get allocatable => asMap(dig(node, ['status', 'allocatable']));

  bool get ready => asMapList(dig(node, ['status', 'conditions'])).any((c) => c['type'] == 'Ready' && c['status'] == 'True');
  bool get cordoned => dig<bool>(node, ['spec', 'unschedulable']) == true;

  /// Pressure-type conditions that are currently True.
  List<String> get pressures => [
        for (final c in asMapList(dig(node, ['status', 'conditions'])))
          if (c['type'] != 'Ready' && c['status'] == 'True') '${c['type']}',
      ];

  List<String> get roles {
    final r = [
      for (final k in labels.keys)
        if (k.startsWith('node-role.kubernetes.io/')) k.substring('node-role.kubernetes.io/'.length),
    ];
    return r.isEmpty ? ['worker'] : r;
  }

  List<Json> get taints => asMapList(dig(node, ['spec', 'taints']));

  double get cpuAlloc => parseCpuMillis(allocatable['cpu']) ?? 0;
  double get memAlloc => parseBytes(allocatable['memory']) ?? 0;
  int get podsAlloc => int.tryParse('${allocatable['pods'] ?? ''}') ?? 0;

  double get cpuFrac => cpuAlloc > 0 ? alloc.total.cpuRequest / cpuAlloc : 0;
  double get memFrac => memAlloc > 0 ? alloc.total.memRequest / memAlloc : 0;

  /// Sort key: problems first.
  int get rank => !ready ? 0 : (pressures.isNotEmpty ? 1 : (cordoned ? 2 : 3));

  String? get internalIP {
    for (final a in asMapList(dig(node, ['status', 'addresses']))) {
      if (a['type'] == 'InternalIP') return '${a['address']}';
    }
    return null;
  }
}

/// Group active pods by node and compute allocations (pure, for tests).
List<NodeSummary> summarizeNodes(List<Json> nodes, List<Json> pods) {
  final byNode = <String, List<Json>>{};
  for (final p in pods) {
    final n = dig<String>(p, ['spec', 'nodeName']);
    if (n != null) byNode.putIfAbsent(n, () => []).add(p);
  }
  final out = [for (final n in nodes) NodeSummary(n, nodeAllocation(byNode[dig<String>(n, ['metadata', 'name'])] ?? const []))];
  out.sort((a, b) => a.rank != b.rank ? a.rank.compareTo(b.rank) : a.name.compareTo(b.name));
  return out;
}

class _NodesViewState extends State<NodesView> with PollingState {
  List<NodeSummary>? _nodes;
  String? _error;
  String _filter = '';
  DateTime? _updated;
  Map<String, NodeUsage>? _usage;
  Object? _metricsError;

  ApiClient get _api => context.read<ApiClient>();

  @override
  void initState() {
    super.initState();
    _refresh();
    poll(const Duration(seconds: 10), () async {
      await _refresh();
      return _error == null;
    });
  }

  Future<void> _refresh() async {
    try {
      final results = await Future.wait([
        _api.items(const ResourceRef(resource: 'nodes')),
        _api.items(const ResourceRef(resource: 'pods'), fieldSelector: 'status.phase!=Succeeded,status.phase!=Failed'),
      ]);
      final usage = await MetricsCache.of(_api).nodes().then<Object>((v) => v, onError: (Object e) => e);
      if (!mounted) return;
      setState(() {
        _usage = usage is List<NodeUsage> ? {for (final u in usage) u.name: u} : null;
        _metricsError = usage is List<NodeUsage> ? null : usage;
        _nodes = summarizeNodes(results[0], results[1]);
        _error = null;
        _updated = DateTime.now();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nodes = _nodes;
    final q = _filter.toLowerCase();
    final visible = nodes?.where((n) => q.isEmpty || n.name.toLowerCase().contains(q) || n.roles.any((r) => r.contains(q))).toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        title: 'Nodes',
        subtitle: nodes == null ? null : Text('${nodes.length} node${nodes.length == 1 ? '' : 's'}'),
        actions: [
          if (_updated != null) AgeText(_updated!.toUtc().toIso8601String(), suffix: ' ago'),
          IconButton(tooltip: 'Refresh', iconSize: 18, icon: const Icon(Icons.refresh), onPressed: _refresh),
          SizedBox(
            width: 180,
            height: 26,
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 15), hintText: 'Filter nodes or roles'),
              style: theme.textTheme.bodyMedium,
              onChanged: (v) => setState(() => _filter = v.trim()),
            ),
          ),
        ],
      ),
      const Divider(),
      // Cluster-wide summary strip (wraps on narrow widths).
      if (nodes != null) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 12, 0), child: _Summary(nodes, _usage, _metricsError)),
      if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: InlineMessage(_error!, isError: true)),
      Expanded(
        child: visible == null
            ? const Center(child: CircularProgressIndicator())
            : visible.isEmpty
                ? Center(child: Text('No nodes', style: TextStyle(color: theme.hintColor)))
                : LayoutBuilder(builder: (context, box) {
                    // Responsive grid of ~400px cards.
                    final cols = (box.maxWidth / 400).floor().clamp(1, 6);
                    final w = (box.maxWidth - 24 - (cols - 1) * 12) / cols;
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Wrap(spacing: 12, runSpacing: 12, children: [
                        for (final n in visible) SizedBox(width: w, child: _NodeCard(n, usage: _usage?[n.name]?.usage, onChanged: _refresh)),
                      ]),
                    );
                  }),
      ),
    ]);
  }
}

class _Summary extends StatelessWidget {
  final List<NodeSummary> nodes;
  final Map<String, NodeUsage>? usage;
  final Object? metricsError;
  const _Summary(this.nodes, this.usage, this.metricsError);

  @override
  Widget build(BuildContext context) {
    final ready = nodes.where((n) => n.ready).length;
    final cordoned = nodes.where((n) => n.cordoned).length;
    final pressure = nodes.where((n) => n.pressures.isNotEmpty).length;
    final cpuReq = nodes.fold<double>(0, (a, n) => a + n.alloc.total.cpuRequest);
    final cpuAll = nodes.fold<double>(0, (a, n) => a + n.cpuAlloc);
    final memReq = nodes.fold<double>(0, (a, n) => a + n.alloc.total.memRequest);
    final memAll = nodes.fold<double>(0, (a, n) => a + n.memAlloc);
    String pct(double a, double b) => b > 0 ? '${(a / b * 100).toStringAsFixed(0)}%' : '–';
    return Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      StatusBadge('$ready/${nodes.length} ready', severity: ready == nodes.length ? Severity.ok : Severity.error, dense: true),
      if (cordoned > 0) StatusBadge('$cordoned cordoned', severity: Severity.warn, dense: true),
      if (pressure > 0) StatusBadge('$pressure under pressure', severity: Severity.error, dense: true),
      if (usage != null)
        Text('CPU ${pct(usage!.values.fold(0.0, (a, u) => a + u.usage.cpuMillis), cpuAll)} · Memory ${pct(usage!.values.fold(0.0, (a, u) => a + u.usage.memoryBytes), memAll)} used',
            style: Theme.of(context).textTheme.bodySmall),
      Text('CPU ${pct(cpuReq, cpuAll)} · Memory ${pct(memReq, memAll)} requested', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
      if (usage != null) const MeterLegend() else if (metricsError != null) MetricsUnavailableNote(metricsError),
    ]);
  }
}

class _NodeCard extends StatelessWidget {
  final NodeSummary n;

  /// Live usage from metrics-server; null when unavailable.
  final Usage? usage;
  final VoidCallback onChanged;
  const _NodeCard(this.n, {this.usage, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final type = app.typeFor('', 'Node');
    final selected = app.detail?.type == type && app.detail?.name == n.name;
    final problem = !n.ready || n.pressures.isNotEmpty;
    final border = problem
        ? severityColor(context, Severity.error).withValues(alpha: 0.6)
        : selected
            ? theme.colorScheme.primary
            : theme.colorScheme.outlineVariant.withValues(alpha: 0.5);
    final info = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final zone = n.labels['topology.kubernetes.io/zone'];
    final instance = n.labels['node.kubernetes.io/instance-type'];
    final ctx = type == null ? null : PanelContext(object: n.node, type: type, api: context.read<ApiClient>(), app: app);

    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: border)),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: type == null ? null : () => app.openDetail(DetailTarget(type: type, name: n.name)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.dns_outlined, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(child: Text(n.name, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
              StatusBadge(n.ready ? 'Ready' : 'NotReady', dense: true),
              if (n.cordoned) ...[const SizedBox(width: 4), const StatusBadge('Cordoned', severity: Severity.warn, dense: true)],
            ]),
            const SizedBox(height: 4),
            Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              for (final r in n.roles) Chipish(text: r),
              for (final p in n.pressures) StatusBadge(p, severity: Severity.error, dense: true),
              Text(
                [
                  dig<String>(n.node, ['status', 'nodeInfo', 'kubeletVersion']),
                  n.internalIP,
                  zone,
                  instance,
                ].whereType<String>().join(' · '),
                style: info,
              ),
            ]),
            const SizedBox(height: 8),
            // Usage filled, requests outlined; request-only bars without metrics.
            NodeResourceMeters(usage: usage, requests: n.alloc.total, cpuAllocatable: n.cpuAlloc, memAllocatable: n.memAlloc),
            UsageBar(
              label: 'Pods',
              labelWidth: 100,
              used: n.alloc.activePods.toDouble(),
              total: n.podsAlloc.toDouble(),
              usedText: '${n.alloc.activePods}',
              totalText: '${n.podsAlloc}',
            ),
            const SizedBox(height: 4),
            Row(children: [
              Expanded(
                child: Text(
                  [
                    if (usage != null) 'requests ${formatCpu(n.alloc.total.cpuRequest)} CPU / ${formatBytes(n.alloc.total.memRequest)}',
                    'limits ${formatCpu(n.alloc.total.cpuLimit)} CPU / ${formatBytes(n.alloc.total.memLimit)}',
                    if (n.taints.isNotEmpty) '${n.taints.length} taint${n.taints.length == 1 ? '' : 's'}',
                  ].join(' · '),
                  overflow: TextOverflow.ellipsis,
                  style: info,
                ),
              ),
              if (ctx != null && !app.readOnly)
                ActionButton(
                  ctx,
                  action: n.cordoned ? 'uncordon' : 'cordon',
                  label: n.cordoned ? 'Uncordon' : 'Cordon',
                  icon: n.cordoned ? Icons.lock_open : Icons.block,
                  title: '${n.cordoned ? 'Uncordon' : 'Cordon'} node ${n.name}?',
                  message: n.cordoned ? 'New pods can be scheduled here again.' : 'New pods will not be scheduled here. Existing pods keep running.',
                  destructive: !n.cordoned,
                  onResult: (_) => onChanged(),
                ),
            ]),
          ]),
        ),
      ),
    );
  }
}
