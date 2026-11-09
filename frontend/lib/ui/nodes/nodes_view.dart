import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../metrics/cache.dart';
import '../../metrics/metrics_api.dart';
import '../../metrics/quantity.dart';
import '../../metrics/quantity_cell.dart';
import '../../metrics/widgets.dart';
import '../../panels/cluster/logic.dart';
import '../../panels/panel.dart';
import '../../state/app_state.dart';
import '../../state/poller.dart';
import '../../util/k8s.dart';
import '../../util/node_os.dart';
import '../../util/pod.dart';
import '../theme.dart';
import 'drain_dialog.dart';
import '../row_context_menu.dart' show showRowContextMenu;
import '../widgets/common.dart';
import '../widgets/editorial.dart';
import '../widgets/node_os_icon.dart';
import '../widgets/page_mode_switch.dart';

/// The Nodes page's Overview: the cluster at a glance, then a table of
/// nodes (grouped by node pool where nodes carry a pool label) that expand
/// into their pods, like the GPUs page. Clicking a node or a pod opens it in
/// the inspector; the ⋮ menu cordons, uncordons and drains. The page's
/// Table mode is the Node kind's table (see [PageModeSwitch]).
class NodesView extends StatefulWidget {
  const NodesView({super.key});

  @override
  State<NodesView> createState() => _NodesViewState();
}

/// Labels naming a node's pool, in the order they are looked for (EKS,
/// GKE, Karpenter, AKS). Instance types are not pools.
const nodePoolLabels = [
  'eks.amazonaws.com/nodegroup',
  'cloud.google.com/gke-nodepool',
  'karpenter.sh/nodepool',
  'kubernetes.azure.com/agentpool',
];

/// One node plus the pods scheduled on it.
///
/// Derived fields are computed once: they feed sorting, grouping, filtering
/// and row builds, and re-walking the node JSON on every access adds up with
/// hundreds of nodes.
class NodeSummary {
  final Json node;
  final NodeAllocation alloc;

  /// The node's non-terminal pods.
  final List<Json> pods;
  NodeSummary(this.node, this.alloc, [this.pods = const []]);

  late final String name = dig<String>(node, ['metadata', 'name']) ?? '';
  late final Json labels = asMap(dig(node, ['metadata', 'labels']));
  late final Json allocatable = asMap(dig(node, ['status', 'allocatable']));
  late final String? created = dig<String>(node, ['metadata', 'creationTimestamp']);

  late final List<Json> _conditions = asMapList(dig(node, ['status', 'conditions']));
  late final bool ready = _conditions.any((c) => c['type'] == 'Ready' && c['status'] == 'True');
  late final bool cordoned = dig<bool>(node, ['spec', 'unschedulable']) == true;

  /// Pressure-type conditions that are currently True.
  late final List<String> pressures = [
    for (final c in _conditions)
      if (c['type'] != 'Ready' && c['status'] == 'True') '${c['type']}',
  ];

  late final List<String> roles = () {
    final r = [
      for (final k in labels.keys)
        if (k.startsWith('node-role.kubernetes.io/')) k.substring('node-role.kubernetes.io/'.length),
    ]..sort();
    return r.isEmpty ? const ['worker'] : r;
  }();

  /// The node pool, from the first of [nodePoolLabels] it carries.
  late final String? pool = () {
    for (final k in nodePoolLabels) {
      final v = labels[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }();

  late final List<Json> taints = asMapList(dig(node, ['spec', 'taints']));

  late final double cpuAlloc = parseCpuMillis(allocatable['cpu']) ?? 0;
  late final double memAlloc = parseBytes(allocatable['memory']) ?? 0;
  late final int podsAlloc = int.tryParse('${allocatable['pods'] ?? ''}') ?? 0;

  /// NVIDIA GPUs: allocatable, and requested by the node's pods.
  late final int gpuAlloc = int.tryParse('${allocatable['nvidia.com/gpu'] ?? ''}') ?? 0;
  late final int gpuUsed = gpuAlloc == 0
      ? 0
      : pods.fold(0, (a, p) {
          var n = 0;
          for (final c in asMapList(dig(p, ['spec', 'containers']))) {
            n += int.tryParse('${dig(c, ['resources', 'limits', 'nvidia.com/gpu']) ?? dig(c, ['resources', 'requests', 'nvidia.com/gpu']) ?? 0}') ?? 0;
          }
          return a + n;
        });

  double get cpuFrac => cpuAlloc > 0 ? alloc.total.cpuRequest / cpuAlloc : 0;
  double get memFrac => memAlloc > 0 ? alloc.total.memRequest / memAlloc : 0;
  double get podsFrac => podsAlloc > 0 ? alloc.activePods / podsAlloc : 0;

  /// Sort key: problems first.
  int get rank => !ready ? 0 : (pressures.isNotEmpty ? 1 : (cordoned ? 2 : 3));

  late final String? internalIP = () {
    for (final a in asMapList(dig(node, ['status', 'addresses']))) {
      if (a['type'] == 'InternalIP') return '${a['address']}';
    }
    return null;
  }();

  late final String? kubeletVersion = dig<String>(node, ['status', 'nodeInfo', 'kubeletVersion']);
  late final String? zone = labels['topology.kubernetes.io/zone'] as String?;
  late final String? instanceType = labels['node.kubernetes.io/instance-type'] as String?;

  /// Base OS and platform, e.g. Bottlerocket · EKS.
  late final NodeOs? os = nodeOsOf(node);
}

/// Group active pods by node and compute allocations (pure, for tests).
List<NodeSummary> summarizeNodes(List<Json> nodes, List<Json> pods) {
  final byNode = <String, List<Json>>{};
  for (final p in pods) {
    final n = dig<String>(p, ['spec', 'nodeName']);
    if (n != null) byNode.putIfAbsent(n, () => []).add(p);
  }
  final out = [
    for (final n in nodes)
      () {
        final on = byNode[dig<String>(n, ['metadata', 'name'])] ?? const <Json>[];
        return NodeSummary(n, nodeAllocation(on), [for (final p in on) if (!isTerminalPod(p)) p]);
      }(),
  ];
  out.sort((a, b) => a.rank != b.rank ? a.rank.compareTo(b.rank) : a.name.compareTo(b.name));
  return out;
}

/// Sortable columns of the nodes list.
enum NodeSort { name, status, cpu, memory, pods }

/// Sorts [nodes] by [by] (ties by name). CPU and memory sort by live usage
/// when [usage] has the node, by requests otherwise.
List<NodeSummary> sortNodes(List<NodeSummary> nodes, NodeSort by, {bool ascending = true, Map<String, NodeUsage>? usage}) {
  double cpu(NodeSummary n) {
    final u = usage?[n.name]?.usage;
    return n.cpuAlloc <= 0 ? 0 : (u?.cpuMillis ?? n.alloc.total.cpuRequest) / n.cpuAlloc;
  }

  double mem(NodeSummary n) {
    final u = usage?[n.name]?.usage;
    return n.memAlloc <= 0 ? 0 : (u?.memoryBytes ?? n.alloc.total.memRequest) / n.memAlloc;
  }

  int key(NodeSummary a, NodeSummary b) => switch (by) {
        NodeSort.name => 0,
        NodeSort.status => a.rank.compareTo(b.rank),
        NodeSort.cpu => cpu(a).compareTo(cpu(b)),
        NodeSort.memory => mem(a).compareTo(mem(b)),
        NodeSort.pods => a.podsFrac.compareTo(b.podsFrac),
      };
  final dir = ascending ? 1 : -1;
  return [...nodes]..sort((a, b) {
      final k = key(a, b);
      return k != 0 ? k * dir : a.name.compareTo(b.name) * (by == NodeSort.name ? dir : 1);
    });
}

/// Splits already-sorted [nodes] into node pools, by name, with nodes
/// outside any pool last (pool null). Empty when no node has a pool label:
/// the list is then flat.
List<(String?, List<NodeSummary>)> groupNodesByPool(List<NodeSummary> nodes) {
  if (!nodes.any((n) => n.pool != null)) return const [];
  final groups = <String?, List<NodeSummary>>{};
  for (final n in nodes) {
    groups.putIfAbsent(n.pool, () => []).add(n);
  }
  final keys = groups.keys.whereType<String>().toList()..sort();
  return [for (final k in keys) (k, groups[k]!), if (groups.containsKey(null)) (null, groups[null]!)];
}

/// Whether [pod] needs a look: not running, not ready, or restarting.
bool podHasProblem(Json pod) {
  final status = podKubectlStatus(pod);
  if (status != 'Running' && status != 'Succeeded' && status != 'Completed') return true;
  return !podReady(pod) || podRestarts(pod) >= 5;
}

/// [pods] of [n] in display order: problem pods first, then the busiest
/// (the larger of their CPU and memory share of the node, from [usage]
/// keyed `namespace/name`, else their requests), then by name.
List<Json> orderNodePods(NodeSummary n, List<Json> pods, Map<String, PodUsage>? usage) {
  double load(Json p) {
    final u = usage?['${dig(p, ['metadata', 'namespace'])}/${dig(p, ['metadata', 'name'])}']?.usage;
    final r = podResources(p);
    final cpu = n.cpuAlloc > 0 ? (u?.cpuMillis ?? r.cpuRequest) / n.cpuAlloc : 0.0;
    final mem = n.memAlloc > 0 ? (u?.memoryBytes ?? r.memRequest) / n.memAlloc : 0.0;
    return cpu > mem ? cpu : mem;
  }

  final keyed = [for (final p in pods) (p, podHasProblem(p), load(p), '${dig(p, ['metadata', 'name'])}')];
  keyed.sort((a, b) {
    if (a.$2 != b.$2) return a.$2 ? -1 : 1;
    final l = b.$3.compareTo(a.$3);
    return l != 0 ? l : a.$4.compareTo(b.$4);
  });
  return [for (final k in keyed) k.$1];
}

class _NodesViewState extends State<NodesView> with PollingState {
  List<NodeSummary>? _nodes;
  String? _error;
  String _filter = '';
  DateTime? _updated;
  Map<String, NodeUsage>? _usage;
  Map<String, PodUsage>? _podUsage;
  Object? _metricsError;

  /// Node and pod usage haven't answered yet (the first time): their cells
  /// show placeholders rather than requests or "—".
  bool _usageLoading = true;
  bool _podUsageLoading = true;

  NodeSort _sort = NodeSort.status;
  bool _ascending = true;
  bool _grouped = true;
  final _collapsed = <String?>{};

  /// Nodes showing their pods, and those showing all of them.
  final _expanded = <String>{};
  final _showAll = <String>{};

  /// Pods listed under a node before "Show all".
  static const podsShown = 15;

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

  /// Lists nodes and pods (from the backend's watch cache: quick) and shows
  /// them at once; node and pod usage from metrics-server fill in as each
  /// answers, without holding up the list.
  Future<void> _refresh() async {
    final metrics = MetricsCache.of(_api);
    final usage = metrics.nodes().then<Object>((v) => v, onError: (Object e) => e).then((u) {
      if (!mounted) return;
      setState(() {
        _usage = u is List<NodeUsage> ? {for (final x in u) x.name: x} : null;
        _metricsError = u is List<NodeUsage> ? null : u;
        _usageLoading = false;
      });
    });
    final podUsage = metrics.pods(null).then<Object>((v) => v, onError: (Object e) => e).then((u) {
      if (!mounted) return;
      setState(() {
        _podUsage = u is List<PodUsage> ? {for (final x in u) x.key: x} : null;
        _podUsageLoading = false;
      });
    });
    try {
      final results = await Future.wait([
        _api.items(const ResourceRef(resource: 'nodes')),
        _api.items(const ResourceRef(resource: 'pods'), fieldSelector: 'status.phase!=Succeeded,status.phase!=Failed'),
      ]);
      if (!mounted) return;
      setState(() {
        _nodes = summarizeNodes(results[0], results[1]);
        _error = null;
        _updated = DateTime.now();
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
    await Future.wait([usage, podUsage]);
  }

  void _sortBy(NodeSort s) => setState(() {
        if (_sort == s) {
          _ascending = !_ascending;
        } else {
          _sort = s;
          // Utilisation reads most usefully busiest-first.
          _ascending = !const {NodeSort.cpu, NodeSort.memory, NodeSort.pods}.contains(s);
        }
      });

  /// Flattened list items: pool headers, nodes and, under expanded nodes,
  /// their pods and a "Show all" line.
  List<Object> _items(List<NodeSummary> visible) {
    final sorted = sortNodes(visible, _sort, ascending: _ascending, usage: _usage);
    final out = <Object>[];
    void addNode(NodeSummary n) {
      out.add(n);
      if (!_expanded.contains(n.name) || n.pods.isEmpty) return;
      final pods = orderNodePods(n, n.pods, _podUsage);
      final all = _showAll.contains(n.name) || pods.length <= podsShown + 2;
      for (final p in all ? pods : pods.take(podsShown)) {
        out.add(_PodItem(n, p));
      }
      if (!all) out.add(_ShowAll(n, pods.length));
    }

    final groups = _grouped ? groupNodesByPool(sorted) : const <(String?, List<NodeSummary>)>[];
    if (groups.isEmpty) {
      sorted.forEach(addNode);
      return out;
    }
    for (final (pool, nodes) in groups) {
      out.add(_Group(pool, nodes));
      if (!_collapsed.contains(pool)) nodes.forEach(addNode);
    }
    return out;
  }

  void _toggle(NodeSummary n) => setState(() => _expanded.contains(n.name) ? _expanded.remove(n.name) : _expanded.add(n.name));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nodes = _nodes;
    final q = _filter.toLowerCase();
    final visible = nodes
        ?.where((n) => q.isEmpty || n.name.toLowerCase().contains(q) || n.roles.any((r) => r.contains(q)) || (n.pool?.toLowerCase().contains(q) ?? false) || (n.os?.label.toLowerCase().contains(q) ?? false))
        .toList();
    final pools = nodes != null && nodes.any((n) => n.pool != null);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        title: 'Nodes',
        // Overview | Table (the Node kind's table, in place).
        afterTitle: context.select<AppState, bool>((a) => a.homeKindOf(MainView.nodes) != null) ? const PageModeSwitch(page: MainView.nodes) : null,
        subtitle: nodes == null ? null : Text('${nodes.length} node${nodes.length == 1 ? '' : 's'}'),
        actions: [
          if (_updated != null) AgeText(_updated!.toUtc().toIso8601String(), suffix: ' ago'),
          if (pools)
            IconButton(
              tooltip: _grouped ? 'Don\'t group by node pool' : 'Group by node pool',
              iconSize: 18,
              isSelected: _grouped,
              icon: const Icon(Icons.workspaces_outline),
              selectedIcon: const Icon(Icons.workspaces),
              onPressed: () => setState(() => _grouped = !_grouped),
            ),
          IconButton(tooltip: 'Refresh', iconSize: 18, icon: const Icon(Icons.refresh), onPressed: _refresh),
          SizedBox(
            width: 180,
            height: 26,
            child: TextField(
              decoration: InputDecoration(prefixIcon: const Icon(Icons.search, size: 15), hintText: pools ? 'Filter nodes, roles or pools' : 'Filter nodes or roles'),
              style: theme.textTheme.bodyMedium,
              onChanged: (v) => setState(() => _filter = v.trim()),
            ),
          ),
        ],
      ),
      const Divider(),
      // Cluster-wide summary strip (wraps on narrow widths).
      if (nodes != null) Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 10), child: _Summary(nodes, _usage, _metricsError, loading: _usageLoading)),
      if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: InlineMessage(_error!, isError: true)),
      Expanded(
        child: visible == null
            ? const Center(child: CircularProgressIndicator())
            : visible.isEmpty
                ? Center(child: Text('No nodes', style: TextStyle(color: theme.hintColor)))
                : LayoutBuilder(builder: (context, box) {
                    final layout = NodeLayout.forWidth(box.maxWidth);
                    final items = _items(visible);
                    // Until usage answers, assume it will (no "requests" flip).
                    final metrics = _usage != null || _usageLoading;
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _HeaderRow(layout: layout, sort: _sort, ascending: _ascending, metrics: metrics, onSort: _sortBy),
                      Expanded(
                        // Lazy: only the rows on screen are built, laid out
                        // and painted.
                        child: ListView.builder(
                          padding: const EdgeInsets.only(bottom: 12),
                          itemCount: items.length,
                          itemBuilder: (context, i) => switch (items[i]) {
                            final _Group g => _GroupHeader(
                                key: ValueKey('group:${g.pool}'),
                                group: g,
                                usage: _usage,
                                collapsed: _collapsed.contains(g.pool),
                                onToggle: () => setState(() => _collapsed.contains(g.pool) ? _collapsed.remove(g.pool) : _collapsed.add(g.pool)),
                              ),
                            final _PodItem p => _PodRow(
                                key: ValueKey('pod:${p.node.name}/${dig(p.pod, ['metadata', 'namespace'])}/${dig(p.pod, ['metadata', 'name'])}'),
                                pod: p.pod,
                                node: p.node,
                                layout: layout,
                                usage: _podUsage?['${dig(p.pod, ['metadata', 'namespace'])}/${dig(p.pod, ['metadata', 'name'])}']?.usage,
                                loading: _podUsageLoading,
                              ),
                            final _ShowAll s => _ShowAllRow(
                                key: ValueKey('showall:${s.node.name}'),
                                count: s.count,
                                onTap: () => setState(() => _showAll.add(s.node.name)),
                              ),
                            final n as NodeSummary => _NodeRow(
                                n,
                                key: ValueKey(n.name),
                                layout: layout,
                                usage: _usage?[n.name]?.usage,
                                metrics: _usage != null,
                                loading: _usageLoading,
                                expanded: _expanded.contains(n.name),
                                onToggle: () => _toggle(n),
                                onChanged: _refresh,
                              ),
                          },
                        ),
                      ),
                    ]);
                  }),
      ),
    ]);
  }
}

class _Group {
  final String? pool;
  final List<NodeSummary> nodes;
  const _Group(this.pool, this.nodes);
}

class _PodItem {
  final NodeSummary node;
  final Json pod;
  const _PodItem(this.node, this.pod);
}

class _ShowAll {
  final NodeSummary node;
  final int count;
  const _ShowAll(this.node, this.count);
}

/// Column widths for a given list width (shared by the header, node rows
/// and pod rows). Columns drop in reverse priority as the width shrinks:
/// CPU stays, then memory, pods, roles, age and version.
class NodeLayout {
  static const hPad = 16.0;
  static const chevronW = 22.0;
  static const indent = 24.0;
  static const menuW = 32.0;
  static const nameMin = 220.0;
  static const gap = 12.0;

  static const rolesW = 120.0, versionW = 92.0, ageW = 56.0, podsW = 78.0, usageW = 156.0;

  final double cpuW;
  final bool showMem, showPods, showRoles, showAge, showVersion;
  const NodeLayout({required this.cpuW, this.showMem = false, this.showPods = false, this.showRoles = false, this.showAge = false, this.showVersion = false});

  factory NodeLayout.forWidth(double width) {
    var room = width - 2 * hPad - chevronW - menuW - nameMin;
    // Narrow: CPU shares what is left with the name.
    if (room < usageW + gap) {
      final cpu = ((width - 2 * hPad - chevronW - menuW) / 2 - gap).clamp(60.0, usageW);
      return NodeLayout(cpuW: cpu);
    }
    room -= usageW + gap;
    bool take(double w) {
      if (room < w + gap) return false;
      room -= w + gap;
      return true;
    }

    final mem = take(usageW);
    final pods = mem && take(podsW);
    final roles = pods && take(rolesW);
    final age = roles && take(ageW);
    final version = age && take(versionW);
    return NodeLayout(cpuW: usageW, showMem: mem, showPods: pods, showRoles: roles, showAge: age, showVersion: version);
  }
}

/// A fixed-width column with the gap before it.
Widget _col(double w, Widget child, {Alignment align = Alignment.centerLeft}) =>
    SizedBox(width: w + NodeLayout.gap, child: Padding(padding: const EdgeInsets.only(left: NodeLayout.gap), child: Align(alignment: align, child: child)));

class _HeaderRow extends StatelessWidget {
  final NodeLayout layout;
  final NodeSort sort;
  final bool ascending;
  final bool metrics;
  final ValueChanged<NodeSort> onSort;
  const _HeaderRow({required this.layout, required this.sort, required this.ascending, required this.metrics, required this.onSort});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(color: theme.hintColor);
    Widget cell(String label, [NodeSort? s]) {
      if (s == null) return Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: style);
      return Hoverable(
        cursor: SystemMouseCursors.basic,
        onTap: () => onSort(s),
        builder: (hovered) => Row(mainAxisSize: MainAxisSize.min, children: [
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: style?.copyWith(color: hovered || sort == s ? theme.colorScheme.onSurface : null, fontWeight: sort == s ? FontWeight.w600 : null),
            ),
          ),
          if (sort == s) ...[
            const SizedBox(width: 2),
            Icon(ascending ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 14, color: theme.hintColor),
          ],
        ]),
      );
    }

    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: NodeLayout.hPad),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.of(context).separator))),
      child: Row(children: [
        const SizedBox(width: NodeLayout.chevronW),
        Expanded(child: Align(alignment: Alignment.centerLeft, child: cell('Node', NodeSort.name))),
        if (layout.showRoles) _col(NodeLayout.rolesW, cell('Roles')),
        if (layout.showVersion) _col(NodeLayout.versionW, cell('Version')),
        if (layout.showAge) _col(NodeLayout.ageW, cell('Age')),
        _col(layout.cpuW, cell(metrics ? 'CPU' : 'CPU requests', NodeSort.cpu)),
        if (layout.showMem) _col(NodeLayout.usageW, cell(metrics ? 'Memory' : 'Memory requests', NodeSort.memory)),
        if (layout.showPods) _col(NodeLayout.podsW, cell('Pods', NodeSort.pods), align: Alignment.centerRight),
        const SizedBox(width: NodeLayout.menuW),
      ]),
    );
  }
}

/// A node pool's heading: the pool, a hairline, and its totals (nodes,
/// trouble in its colour, CPU and memory in use) at the end.
class _GroupHeader extends StatelessWidget {
  final _Group group;
  final Map<String, NodeUsage>? usage;
  final bool collapsed;
  final VoidCallback onToggle;
  const _GroupHeader({super.key, required this.group, required this.usage, required this.collapsed, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final nodes = group.nodes;
    final notReady = nodes.where((n) => !n.ready).length;
    final cordoned = nodes.where((n) => n.cordoned).length;
    final cpuAll = nodes.fold<double>(0, (a, n) => a + n.cpuAlloc);
    final memAll = nodes.fold<double>(0, (a, n) => a + n.memAlloc);
    final u = usage;
    String? pct(String what, double used, double of) => of <= 0 ? null : '$what ${formatPercent(used / of)}';
    final totals = [
      if (u != null) ...[
        pct('CPU', nodes.fold(0.0, (a, n) => a + (u[n.name]?.usage.cpuMillis ?? 0)), cpuAll),
        pct('memory', nodes.fold(0.0, (a, n) => a + (u[n.name]?.usage.memoryBytes ?? 0)), memAll),
      ],
      '${nodes.length} node${nodes.length == 1 ? '' : 's'}',
    ].whereType<String>();
    return Hoverable(
      cursor: SystemMouseCursors.basic,
      onTap: onToggle,
      builder: (hovered) => Container(
        height: 34,
        padding: const EdgeInsets.fromLTRB(NodeLayout.hPad - 4, 10, NodeLayout.hPad, 2),
        child: TitleRule(
          title: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 16, color: hovered || collapsed ? theme.hintColor : AppColors.of(context).faint),
            const SizedBox(width: 3),
            Flexible(child: Text(group.pool ?? 'No pool', maxLines: 1, overflow: TextOverflow.ellipsis, style: sectionTitleStyle(context))),
          ]),
          trailing: Text.rich(
            TextSpan(children: [
              if (notReady > 0) TextSpan(text: '$notReady not ready  ·  ', style: TextStyle(color: severityColor(context, Severity.error))),
              if (cordoned > 0) TextSpan(text: '$cordoned cordoned  ·  ', style: TextStyle(color: severityColor(context, Severity.warn))),
              TextSpan(text: totals.join('  ·  ')),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontFeatures: tabularFigures),
          ),
        ),
      ),
    );
  }
}

/// The cluster at a glance: large figures divided by hairlines (ready,
/// cordoned, under pressure, then usage and requests), coloured only when
/// something is wrong, with the metrics legend or note under them.
class _Summary extends StatelessWidget {
  final List<NodeSummary> nodes;
  final Map<String, NodeUsage>? usage;
  final Object? metricsError;

  /// Usage hasn't answered yet: its figures are placeholders.
  final bool loading;
  const _Summary(this.nodes, this.usage, this.metricsError, {this.loading = false});

  @override
  Widget build(BuildContext context) {
    final ready = nodes.where((n) => n.ready).length;
    final cordoned = nodes.where((n) => n.cordoned).length;
    final pressure = nodes.where((n) => n.pressures.isNotEmpty).length;
    final cpuReq = nodes.fold<double>(0, (a, n) => a + n.alloc.total.cpuRequest);
    final cpuAll = nodes.fold<double>(0, (a, n) => a + n.cpuAlloc);
    final memReq = nodes.fold<double>(0, (a, n) => a + n.alloc.total.memRequest);
    final memAll = nodes.fold<double>(0, (a, n) => a + n.memAlloc);
    StatItem pct(String label, double a, double b) {
      if (b <= 0) return StatItem(label, '–');
      final f = a / b;
      final sev = thresholdSeverity(f);
      return StatItem(label, '${(f * 100).toStringAsFixed(0)}%', tone: sev == Severity.neutral ? null : sev, frac: f);
    }

    final total = nodes.length;
    final u = usage;
    final note = u != null ? const MeterLegend() : (metricsError != null ? MetricsUnavailableNote(metricsError) : null);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      StatStrip(minCell: 110, maxCell: 170, items: [
        StatItem(
          'nodes ready',
          '$ready',
          of: ready < total ? '/ $total' : null,
          // Red only when none are ready; some is amber, as on the Overview.
          tone: ready < total ? (ready == 0 ? Severity.error : Severity.warn) : null,
          frac: total > 0 ? ready / total : null,
        ),
        if (cordoned > 0) StatItem('cordoned', '$cordoned', tone: Severity.warn),
        if (pressure > 0) StatItem('under pressure', '$pressure', tone: Severity.error),
        if (loading) ...[
          const StatItem('CPU in use', null),
          const StatItem('memory in use', null),
        ] else if (u != null) ...[
          pct('CPU in use', u.values.fold(0.0, (a, x) => a + x.usage.cpuMillis), cpuAll),
          pct('memory in use', u.values.fold(0.0, (a, x) => a + x.usage.memoryBytes), memAll),
        ],
        pct('CPU requested', cpuReq, cpuAll),
        pct('memory requested', memReq, memAll),
      ]),
      if (note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Align(alignment: Alignment.centerLeft, child: note)),
    ]);
  }
}


/// A usage cell's value: [used] of [base] (millicores when [cpu], else
/// bytes), against [basis] ("allocatable", "limit", "request").
UsageValue? _usage(double? used, double? base, String? basis, {required bool cpu}) {
  if (used == null) return null;
  final scale = cpu ? 1000 : 1;
  final b = base != null && base > 0 ? base / scale : null;
  return UsageValue(raw: used / scale, base: b, percent: b == null ? null : used / scale / b * 100, basis: b == null ? null : basis, unit: cpu ? 'cpu' : 'bytes');
}

TextStyle? _cellStyle(BuildContext context) => Theme.of(context).textTheme.bodySmall;

class _NodeRow extends StatelessWidget {
  final NodeSummary n;
  final NodeLayout layout;

  /// Live usage from metrics-server; null when unavailable.
  final Usage? usage;

  /// Metrics are available: a node without a sample shows "—" rather
  /// than its requests.
  final bool metrics;

  /// Usage hasn't answered yet: placeholders in the usage cells.
  final bool loading;
  final bool expanded;
  final VoidCallback onToggle;
  final VoidCallback onChanged;
  const _NodeRow(this.n, {super.key, required this.layout, this.usage, this.metrics = false, this.loading = false, required this.expanded, required this.onToggle, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    // Select only what the row shows, so unrelated AppState changes (and
    // selecting some other node) don't rebuild every row.
    final app = context.read<AppState>();
    final type = context.select<AppState, ResourceType?>((a) => a.typeFor('', 'Node'));
    final selected = context.select<AppState, bool>((a) => a.detail?.type == type && a.detail?.name == n.name);
    final readOnly = context.select<AppState, bool>((a) => a.readOnly);
    final info = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final problem = !n.ready || n.pressures.isNotEmpty;
    final err = severityColor(context, Severity.error);
    final sev = problem ? Severity.error : (n.cordoned ? Severity.warn : Severity.ok);
    final u = usage;
    final req = n.alloc.total;
    final style = _cellStyle(context);
    // Live usage, or requests without metrics-server.
    final cpu = _usage(metrics ? u?.cpuMillis : req.cpuRequest, n.cpuAlloc, 'allocatable', cpu: true);
    final mem = _usage(metrics ? u?.memoryBytes : req.memRequest, n.memAlloc, 'allocatable', cpu: false);
    final podsSev = thresholdSeverity(n.podsAlloc > 0 ? n.podsFrac : null);

    final meta = [
      if (!layout.showRoles) n.roles.join(', '),
      if (!layout.showVersion) n.kubeletVersion,
      n.internalIP,
      n.zone,
      n.instanceType,
    ].whereType<String>().join(' · ');
    final hasMeta = meta.isNotEmpty || n.os != null;
    // The IP line's height, to line the chevron up with the name above it.
    final metaLineHeight = (TextPainter(text: TextSpan(text: 'x', style: info), textDirection: TextDirection.ltr, textScaler: MediaQuery.textScalerOf(context))..layout()).height;
    final taints = n.taints.map((t) => '${t['key']}${t['value'] == null ? '' : '=${t['value']}'}:${t['effect']}').join('\n');

    Widget mini(IconData icon, String text, String tooltip) => Padding(
          padding: const EdgeInsets.only(left: 8),
          child: Tooltip(
            message: tooltip,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 12, color: theme.hintColor),
              const SizedBox(width: 3),
              Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontFeatures: const [FontFeature.tabularFigures()])),
            ]),
          ),
        );

    Widget chip(String text, Severity severity, {String? tooltip}) {
      final c = StatusBadge(text, severity: severity, dense: true);
      return Padding(padding: const EdgeInsets.only(left: 8), child: tooltip == null ? c : Tooltip(message: tooltip, child: c));
    }

    return Hoverable(
      cursor: SystemMouseCursors.basic,
      onTap: type == null ? null : () => app.openDetail(DetailTarget(type: type, name: n.name)),
      // The same menu as a table row: cordon, drain, copy link, kubectl…
      onSecondaryTapUp: type == null
          ? null
          : (d) => showRowContextMenu(context, d.globalPosition, type, TableRowData(uid: n.name, name: n.name, resourceVersion: '', cells: const [])),
      builder: (hovered) => Container(
        height: 44,
        margin: const EdgeInsets.fromLTRB(6, 2, 6, 0),
        padding: const EdgeInsets.only(left: NodeLayout.hPad - 6, right: NodeLayout.hPad - 6),
        decoration: BoxDecoration(
          color: selected
              ? colors.selection
              : hovered
                  ? colors.hover
                  : (problem ? err.withValues(alpha: 0.06) : null),
          border: problem ? Border(left: BorderSide(color: err, width: 3)) : null,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(children: [
          SizedBox(
            width: NodeLayout.chevronW,
            child: n.pods.isEmpty
                ? null
                : Padding(
                    // Line up with the name, not the middle of name + IP.
                    padding: EdgeInsets.only(bottom: hasMeta ? metaLineHeight : 0),
                    child: InkResponse(
                      key: ValueKey('expand:${n.name}'),
                      onTap: onToggle,
                      radius: 12,
                      child: Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 18, color: theme.hintColor),
                    ),
                  ),
          ),
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Container(width: 7, height: 7, decoration: BoxDecoration(color: severityColor(context, sev), shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Flexible(
                  flex: 3,
                  child: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
                ),
                // Chips: what is unusual about the node.
                Flexible(
                  flex: 2,
                  child: ClipRect(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      physics: const NeverScrollableScrollPhysics(),
                      child: Row(children: [
                        if (!n.ready) chip('NotReady', Severity.error),
                        for (final p in n.pressures) chip(p, Severity.error),
                        if (n.cordoned) chip('Cordoned', Severity.warn),
                        // Routine facts as compact icon + count, so they fit
                        // beside long names; the details are in the tooltips.
                        if (n.taints.isNotEmpty) mini(Icons.block, '${n.taints.length}', '${n.taints.length} taint${n.taints.length == 1 ? '' : 's'}\n$taints'),
                        if (n.gpuAlloc > 0) mini(Icons.memory, '${n.gpuUsed}/${n.gpuAlloc}', 'NVIDIA GPUs requested by pods / allocatable'),
                      ]),
                    ),
                  ),
                ),
              ]),
              if (hasMeta)
                Row(children: [
                  // The OS glyph sits centred under the status dot, so the
                  // meta text keeps lining up with the name.
                  SizedBox(
                    width: 15,
                    child: n.os == null ? null : Transform.translate(offset: const Offset(-3.5, 0), child: Align(alignment: Alignment.centerLeft, child: NodeOsIcon(n.node))),
                  ),
                  Flexible(child: Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: info)),
                ]),
            ]),
          ),
          if (layout.showRoles) _col(NodeLayout.rolesW, Text(n.roles.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
          if (layout.showVersion) _col(NodeLayout.versionW, Text(n.kubeletVersion ?? '–', maxLines: 1, overflow: TextOverflow.ellipsis, style: info)),
          if (layout.showAge) _col(NodeLayout.ageW, n.created == null ? Text('–', style: info) : AgeText(n.created, style: info)),
          _col(layout.cpuW, loading ? const _UsagePlaceholder() : UsageCell(value: cpu, style: style)),
          if (layout.showMem) _col(NodeLayout.usageW, loading ? const _UsagePlaceholder() : UsageCell(value: mem, style: style)),
          if (layout.showPods)
            _col(
              NodeLayout.podsW,
              Text(
                '${n.alloc.activePods} / ${n.podsAlloc}',
                maxLines: 1,
                style: style?.copyWith(fontFeatures: tabularFigures, color: podsSev == Severity.neutral ? null : severityColor(context, podsSev)),
              ),
              align: Alignment.centerRight,
            ),
          SizedBox(
            width: NodeLayout.menuW,
            child: type == null ? null : _NodeMenu(n: n, ctx: PanelContext(object: n.node, type: type, api: context.read<ApiClient>(), app: app), readOnly: readOnly, onChanged: onChanged),
          ),
        ]),
      ),
    );
  }
}

/// One pod under an expanded node: its status, namespace and usage
/// against its limit (else request). Clicking it opens it in the inspector.
class _PodRow extends StatelessWidget {
  final Json pod;
  final NodeSummary node;
  final NodeLayout layout;
  final Usage? usage;
  final bool loading;
  const _PodRow({super.key, required this.pod, required this.node, required this.layout, this.usage, this.loading = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final app = context.read<AppState>();
    final name = dig<String>(pod, ['metadata', 'name']) ?? '';
    final ns = dig<String>(pod, ['metadata', 'namespace']);
    final type = context.select<AppState, ResourceType?>((a) => a.typeFor('', 'Pod'));
    final selected = context.select<AppState, bool>((a) => a.detail?.type == type && a.detail?.name == name && a.detail?.namespace == ns);
    final info = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final style = _cellStyle(context);
    final status = podKubectlStatus(pod);
    final restarts = podRestarts(pod);
    final problem = podHasProblem(pod);
    final sev = !problem ? Severity.ok : (status == 'Pending' || status == 'ContainerCreating' || status == 'Terminating' || (status == 'Running' && podReady(pod)) ? Severity.warn : Severity.error);
    final r = podResources(pod);
    final u = usage;
    final cpu = u == null ? null : _usage(u.cpuMillis, r.cpuLimit > 0 ? r.cpuLimit : r.cpuRequest, r.cpuLimit > 0 ? 'limit' : 'request', cpu: true);
    final mem = u == null ? null : _usage(u.memoryBytes, r.memLimit > 0 ? r.memLimit : r.memRequest, r.memLimit > 0 ? 'limit' : 'request', cpu: false);
    final statusText = Text(status, maxLines: 1, overflow: TextOverflow.ellipsis, style: style?.copyWith(color: sev == Severity.ok ? theme.hintColor : severityColor(context, sev)));

    return Hoverable(
      cursor: SystemMouseCursors.basic,
      onTap: type == null ? null : () => app.openDetail(DetailTarget(type: type, name: name, namespace: ns)),
      onSecondaryTapUp: type == null
          ? null
          : (d) => showRowContextMenu(context, d.globalPosition, type, TableRowData(uid: '$ns/$name', name: name, namespace: ns, resourceVersion: '', cells: const [])),
      builder: (hovered) => Container(
        height: 30,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.only(left: NodeLayout.hPad - 6, right: NodeLayout.hPad - 6),
        decoration: BoxDecoration(color: selected ? colors.selection : (hovered ? colors.hover : null), borderRadius: BorderRadius.circular(5)),
        child: Row(children: [
          const SizedBox(width: NodeLayout.chevronW),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(left: NodeLayout.indent),
              child: Row(children: [
                Container(width: 6, height: 6, decoration: BoxDecoration(color: severityColor(context, sev), shape: BoxShape.circle)),
                const SizedBox(width: 8),
                Flexible(
                  flex: 3,
                  child: Text(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurface.withValues(alpha: 0.85))),
                ),
                if (ns != null) ...[
                  const SizedBox(width: 8),
                  Flexible(flex: 2, child: Text(ns, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: colors.faint))),
                ],
                // Without a Roles column, the status rides along the name.
                if (!layout.showRoles && sev != Severity.ok) ...[const SizedBox(width: 8), Flexible(flex: 2, child: statusText)],
              ]),
            ),
          ),
          if (layout.showRoles) _col(NodeLayout.rolesW, statusText),
          if (layout.showVersion)
            _col(
              NodeLayout.versionW,
              restarts == 0
                  ? const SizedBox.shrink()
                  : Text('$restarts restart${restarts == 1 ? '' : 's'}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: info?.copyWith(color: restarts >= 5 ? severityColor(context, Severity.warn) : null)),
            ),
          if (layout.showAge) _col(NodeLayout.ageW, AgeText(dig(pod, ['metadata', 'creationTimestamp']), style: info)),
          _col(layout.cpuW, loading ? const _UsagePlaceholder() : UsageCell(value: cpu, style: style)),
          if (layout.showMem) _col(NodeLayout.usageW, loading ? const _UsagePlaceholder() : UsageCell(value: mem, style: style)),
          if (layout.showPods) const SizedBox(width: NodeLayout.podsW + NodeLayout.gap),
          const SizedBox(width: NodeLayout.menuW),
        ]),
      ),
    );
  }
}

/// Stands in for a usage cell until metrics answer: a faint bar where the
/// value sits, the cell's height, so nothing moves when it fills in.
class _UsagePlaceholder extends StatelessWidget {
  const _UsagePlaceholder();

  @override
  Widget build(BuildContext context) => const SizedBox(
        height: 16,
        child: Align(alignment: Alignment.centerRight, child: FractionallySizedBox(widthFactor: 0.55, child: SkeletonBar(height: 8))),
      );
}

class _ShowAllRow extends StatelessWidget {
  final int count;
  final VoidCallback onTap;
  const _ShowAllRow({super.key, required this.count, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: 28,
      padding: const EdgeInsets.only(left: NodeLayout.hPad + NodeLayout.chevronW + NodeLayout.indent + 8, right: NodeLayout.hPad),
      alignment: Alignment.centerLeft,
      child: Hoverable(
        onTap: onTap,
        builder: (hovered) => Text(
          'Show all $count',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary, decoration: hovered ? TextDecoration.underline : null),
        ),
      ),
    );
  }
}

/// Per-node actions behind a "⋮" button.
class _NodeMenu extends StatelessWidget {
  final NodeSummary n;
  final PanelContext ctx;
  final bool readOnly;
  final VoidCallback onChanged;
  const _NodeMenu({required this.n, required this.ctx, required this.readOnly, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    PopupMenuItem<String> item(String value, IconData icon, String label, {Color? color}) => PopupMenuItem(
          value: value,
          height: 32,
          child: Row(children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 8),
            Text(label, style: color == null ? null : TextStyle(color: color)),
          ]),
        );
    return PopupMenuButton<String>(
      popUpAnimationStyle: AnimationStyle.noAnimation,
      tooltip: 'Node actions',
      padding: EdgeInsets.zero,
      iconSize: 16,
      icon: Icon(Icons.more_vert, size: 16, color: theme.hintColor),
      style: IconButton.styleFrom(visualDensity: VisualDensity.compact, minimumSize: const Size(24, 24), padding: EdgeInsets.zero),
      onSelected: (v) async {
        switch (v) {
          case 'open':
            ctx.app.openDetail(DetailTarget(type: ctx.type, name: n.name));
          case 'cordon':
            final res = await runResourceAction(context, ctx, 'cordon',
                title: 'Cordon node ${n.name}?',
                message: 'New pods will not be scheduled here. Existing pods keep running.',
                destructive: true,
                confirmLabel: 'Cordon');
            if (res != null) onChanged();
          case 'uncordon':
            final res = await runResourceAction(context, ctx, 'uncordon',
                title: 'Uncordon node ${n.name}?', message: 'New pods can be scheduled here again.', confirmLabel: 'Uncordon');
            if (res != null) onChanged();
          case 'drain':
            if (await showDrainDialog(context, n.name) != null) onChanged();
        }
      },
      itemBuilder: (_) => [
        item('open', Icons.open_in_new, 'Show details'),
        if (!readOnly) ...[
          const PopupMenuDivider(height: 8),
          if (n.cordoned) item('uncordon', Icons.lock_open, 'Uncordon') else item('cordon', Icons.block, 'Cordon', color: theme.colorScheme.error),
          item('drain', Icons.move_down, 'Drain…', color: theme.colorScheme.error),
        ],
      ],
    );
  }
}
