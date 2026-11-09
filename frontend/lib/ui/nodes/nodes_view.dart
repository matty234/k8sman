import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../metrics/cache.dart';
import '../../metrics/metrics_api.dart';
import '../../metrics/quantity.dart';
import '../../metrics/widgets.dart';
import '../../panels/cluster/logic.dart';
import '../../panels/panel.dart';
import '../../state/app_state.dart';
import '../../state/poller.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import 'drain_dialog.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart';

/// Cluster nodes as a sortable list, grouped by role: health, utilisation
/// bars and a per-node menu (cordon / uncordon). Clicking a row opens the
/// full Node panel in the sidebar.
class NodesView extends StatefulWidget {
  const NodesView({super.key});

  @override
  State<NodesView> createState() => _NodesViewState();
}

/// One node plus the pods scheduled on it.
///
/// Derived fields are computed once: they feed sorting, grouping, filtering
/// and row builds, and re-walking the node JSON on every access adds up with
/// hundreds of nodes.
class NodeSummary {
  final Json node;
  final NodeAllocation alloc;
  NodeSummary(this.node, this.alloc);

  late final String name = dig<String>(node, ['metadata', 'name']) ?? '';
  late final Json labels = asMap(dig(node, ['metadata', 'labels']));
  late final Json allocatable = asMap(dig(node, ['status', 'allocatable']));

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

  /// The role group this node is listed under ("control-plane", "worker",
  /// or several roles joined).
  String get roleGroup => roles.join(', ');

  late final List<Json> taints = asMapList(dig(node, ['spec', 'taints']));

  late final double cpuAlloc = parseCpuMillis(allocatable['cpu']) ?? 0;
  late final double memAlloc = parseBytes(allocatable['memory']) ?? 0;
  late final int podsAlloc = int.tryParse('${allocatable['pods'] ?? ''}') ?? 0;

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

/// Splits already-sorted [nodes] into role groups: control-plane first,
/// then other roles alphabetically, plain workers last.
List<(String, List<NodeSummary>)> groupNodesByRole(List<NodeSummary> nodes) {
  final groups = <String, List<NodeSummary>>{};
  for (final n in nodes) {
    groups.putIfAbsent(n.roleGroup, () => []).add(n);
  }
  int weight(String g) => g.contains('control-plane') || g.contains('master') ? 0 : (g == 'worker' ? 2 : 1);
  final keys = groups.keys.toList()..sort((a, b) => weight(a) != weight(b) ? weight(a).compareTo(weight(b)) : a.compareTo(b));
  return [for (final k in keys) (k, groups[k]!)];
}

class _NodesViewState extends State<NodesView> with PollingState {
  List<NodeSummary>? _nodes;
  String? _error;
  String _filter = '';
  DateTime? _updated;
  Map<String, NodeUsage>? _usage;
  Object? _metricsError;

  NodeSort _sort = NodeSort.status;
  bool _ascending = true;
  bool _grouped = true;
  final _collapsed = <String>{};

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

  void _sortBy(NodeSort s) => setState(() {
        if (_sort == s) {
          _ascending = !_ascending;
        } else {
          _sort = s;
          // Utilisation reads most usefully busiest-first.
          _ascending = !const {NodeSort.cpu, NodeSort.memory, NodeSort.pods}.contains(s);
        }
      });

  /// Flattened list items: group headers (String) and nodes.
  List<Object> _items(List<NodeSummary> visible) {
    final sorted = sortNodes(visible, _sort, ascending: _ascending, usage: _usage);
    if (!_grouped) return sorted;
    final groups = groupNodesByRole(sorted);
    if (groups.length < 2) return sorted;
    return [
      for (final (role, nodes) in groups) ...[
        _Group(role, nodes),
        if (!_collapsed.contains(role)) ...nodes,
      ],
    ];
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
          IconButton(
            tooltip: _grouped ? 'Don\'t group by role' : 'Group by role',
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
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 15), hintText: 'Filter nodes or roles'),
              style: theme.textTheme.bodyMedium,
              onChanged: (v) => setState(() => _filter = v.trim()),
            ),
          ),
        ],
      ),
      const Divider(),
      // Cluster-wide summary strip (wraps on narrow widths).
      if (nodes != null) Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 8), child: _Summary(nodes, _usage, _metricsError)),
      if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: InlineMessage(_error!, isError: true)),
      Expanded(
        child: visible == null
            ? const Center(child: CircularProgressIndicator())
            : visible.isEmpty
                ? Center(child: Text('No nodes', style: TextStyle(color: theme.hintColor)))
                : LayoutBuilder(builder: (context, box) {
                    final layout = _Layout.forWidth(box.maxWidth);
                    final items = _items(visible);
                    final metrics = _usage != null;
                    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      _HeaderRow(layout: layout, sort: _sort, ascending: _ascending, metrics: metrics, onSort: _sortBy),
                      Expanded(
                        // Lazy: only the rows on screen are built, laid out
                        // and painted.
                        child: ListView.builder(
                          padding: const EdgeInsets.only(bottom: 12),
                          itemCount: items.length,
                          itemBuilder: (context, i) {
                            final it = items[i];
                            if (it is _Group) {
                              return _GroupHeader(
                                key: ValueKey('group:${it.role}'),
                                group: it,
                                collapsed: _collapsed.contains(it.role),
                                onToggle: () => setState(() => _collapsed.contains(it.role) ? _collapsed.remove(it.role) : _collapsed.add(it.role)),
                              );
                            }
                            final n = it as NodeSummary;
                            return _NodeRow(n, key: ValueKey(n.name), layout: layout, usage: _usage?[n.name]?.usage, onChanged: _refresh);
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
  final String role;
  final List<NodeSummary> nodes;
  const _Group(this.role, this.nodes);
}

/// Column widths for a given list width (shared by the header and rows).
class _Layout {
  static const hPad = 16.0;
  static const menuW = 32.0;
  static const gap = 16.0;

  /// Leading status dot (7) and its gap (8), shown without a Status column.
  static const dotW = 15.0;

  final double statusW;
  final double meterW;

  /// Meters shown: CPU, then memory, then pods as width allows.
  final int meters;

  /// Absolute values ("1.2 / 4") next to the bars when there's room.
  final double valueW;

  const _Layout({required this.statusW, required this.meterW, required this.meters, required this.valueW});

  bool get showMemory => meters >= 2;
  bool get showPods => meters >= 3;

  factory _Layout.forWidth(double width) {
    final inner = width - 2 * _Layout.hPad - _Layout.menuW;
    // The Status column replaces the leading status dot when there's room.
    final statusW = inner >= 700 ? 92.0 : 0.0;
    final lead = statusW > 0 ? 0.0 : dotW;
    const nameMin = 280.0;
    var meters = 3;
    var meterW = 0.0;
    for (; meters > 1; meters--) {
      meterW = ((inner - lead - statusW - nameMin) / meters - gap).clamp(0, 320);
      if (meterW >= 150) break;
    }
    // Narrow: CPU only, sharing the width evenly with the name.
    if (meters == 1) meterW = ((inner - lead - statusW) / 2 - gap).clamp(90, 320);
    // "used / allocatable" beside the bar only while the bar stays long.
    final valueW = meterW >= 280 ? 112.0 : 0.0;
    return _Layout(statusW: statusW, meterW: meterW, meters: meters, valueW: valueW);
  }
}

class _HeaderRow extends StatelessWidget {
  final _Layout layout;
  final NodeSort sort;
  final bool ascending;
  final bool metrics;
  final ValueChanged<NodeSort> onSort;
  const _HeaderRow({required this.layout, required this.sort, required this.ascending, required this.metrics, required this.onSort});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(color: theme.hintColor);
    Widget cell(String label, NodeSort s) => Hoverable(
          cursor: SystemMouseCursors.basic,
          onTap: () => onSort(s),
          builder: (hovered) => Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: style?.copyWith(
                  color: hovered || sort == s ? theme.colorScheme.onSurface : null,
                  fontWeight: sort == s ? FontWeight.w600 : null,
                ),
              ),
            ),
            if (sort == s) ...[
              const SizedBox(width: 2),
              Icon(ascending ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down, size: 14, color: theme.hintColor),
            ],
          ]),
        );
    Widget meter(String label, NodeSort s) => SizedBox(
          width: layout.meterW + _Layout.gap,
          child: Padding(padding: const EdgeInsets.only(left: _Layout.gap), child: Align(alignment: Alignment.centerLeft, child: cell(label, s))),
        );
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: _Layout.hPad),
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: AppColors.of(context).separator))),
      child: Row(children: [
        if (layout.statusW == 0) const SizedBox(width: _Layout.dotW),
        Expanded(child: Align(alignment: Alignment.centerLeft, child: cell('Node', NodeSort.name))),
        if (layout.statusW > 0) SizedBox(width: layout.statusW, child: Align(alignment: Alignment.centerLeft, child: cell('Status', NodeSort.status))),
        meter(metrics ? 'CPU' : 'CPU requests', NodeSort.cpu),
        if (layout.showMemory) meter(metrics ? 'Memory' : 'Memory requests', NodeSort.memory),
        if (layout.showPods) meter('Pods', NodeSort.pods),
        const SizedBox(width: _Layout.menuW),
      ]),
    );
  }
}

class _GroupHeader extends StatelessWidget {
  final _Group group;
  final bool collapsed;
  final VoidCallback onToggle;
  const _GroupHeader({super.key, required this.group, required this.collapsed, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notReady = group.nodes.where((n) => !n.ready).length;
    final cordoned = group.nodes.where((n) => n.cordoned).length;
    // The app's section heading: the role, a hairline, the count (and any
    // trouble, in its colour) at the end.
    return Hoverable(
      cursor: SystemMouseCursors.basic,
      onTap: onToggle,
      builder: (hovered) => Container(
        height: 34,
        padding: const EdgeInsets.fromLTRB(_Layout.hPad - 4, 10, _Layout.hPad, 2),
        child: TitleRule(
          title: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 16, color: hovered || collapsed ? theme.hintColor : AppColors.of(context).faint),
            const SizedBox(width: 3),
            Flexible(child: Text(group.role, maxLines: 1, overflow: TextOverflow.ellipsis, style: sectionTitleStyle(context))),
          ]),
          trailing: Text.rich(
            TextSpan(children: [
              if (notReady > 0) TextSpan(text: '$notReady not ready  ·  ', style: TextStyle(color: severityColor(context, Severity.error))),
              if (cordoned > 0) TextSpan(text: '$cordoned cordoned  ·  ', style: TextStyle(color: severityColor(context, Severity.warn))),
              TextSpan(text: '${group.nodes.length}'),
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
        if (u != null) ...[
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

class _NodeRow extends StatelessWidget {
  final NodeSummary n;
  final _Layout layout;

  /// Live usage from metrics-server; null when unavailable.
  final Usage? usage;
  final VoidCallback onChanged;
  const _NodeRow(this.n, {super.key, required this.layout, this.usage, required this.onChanged});

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
    final sev = problem ? Severity.error : (n.cordoned ? Severity.warn : Severity.ok);
    final u = usage;
    final req = n.alloc.total;
    final cpuAlloc = n.cpuAlloc > 0 ? n.cpuAlloc : null;
    final memAlloc = n.memAlloc > 0 ? n.memAlloc : null;
    final podsAlloc = n.podsAlloc > 0 ? n.podsAlloc.toDouble() : null;

    Widget meter({required double? used, double? requested, required double? scale, required String valueText, required String Function(double) format}) =>
        Padding(
          padding: const EdgeInsets.only(left: _Layout.gap),
          child: SizedBox(
            width: layout.meterW,
            child: ResourceMeter(
              label: '',
              labelWidth: 0,
              valueWidth: layout.valueW,
              compact: true,
              used: used,
              requested: requested,
              scale: scale,
              percentBase: scale,
              percentOf: 'allocatable',
              valueText: valueText,
              format: format,
            ),
          ),
        );

    final meta = [
      n.kubeletVersion,
      n.internalIP,
      n.zone,
      n.instanceType,
      if (n.taints.isNotEmpty) '${n.taints.length} taint${n.taints.length == 1 ? '' : 's'}',
    ].whereType<String>().join(' · ');

    return Hoverable(
      cursor: SystemMouseCursors.basic,
      onTap: type == null ? null : () => app.openDetail(DetailTarget(type: type, name: n.name)),
      builder: (hovered) => Container(
        height: 44,
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.only(left: _Layout.hPad - 6, right: _Layout.hPad - 6),
        decoration: BoxDecoration(
          color: selected
              ? colors.selection
              : hovered
                  ? colors.hover
                  : null,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(children: [
          if (layout.statusW == 0) ...[
            Container(width: 7, height: 7, decoration: BoxDecoration(color: severityColor(context, sev), shape: BoxShape.circle)),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(
                  flex: 3,
                  child: Text(n.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                ),
                // Without a Status column, NotReady / Cordoned ride along the name.
                if (layout.statusW == 0 && (!n.ready || n.cordoned)) ...[const SizedBox(width: 10), Flexible(flex: 2, child: _statusBadge())],
                for (final p in n.pressures) ...[const SizedBox(width: 10), Flexible(flex: 2, child: StatusBadge(p, severity: Severity.error, dense: true))],
              ]),
              if (meta.isNotEmpty) Text(meta, maxLines: 1, overflow: TextOverflow.ellipsis, style: info),
            ]),
          ),
          if (layout.statusW > 0) SizedBox(width: layout.statusW, child: Align(alignment: Alignment.centerLeft, child: _statusBadge())),
          if (u != null)
            meter(
              used: u.cpuMillis,
              requested: req.cpuRequest,
              scale: cpuAlloc,
              valueText: '${formatCpuUsage(u.cpuMillis)} / ${formatCpu(cpuAlloc)}',
              format: formatCpuUsage,
            )
          else
            meter(used: req.cpuRequest, scale: cpuAlloc, valueText: '${formatCpu(req.cpuRequest)} / ${formatCpu(cpuAlloc)}', format: formatCpu),
          if (layout.showMemory)
            if (u != null)
              meter(
                used: u.memoryBytes,
                requested: req.memRequest,
                scale: memAlloc,
                valueText: '${formatBytes(u.memoryBytes)} / ${formatBytes(memAlloc)}',
                format: formatBytes,
              )
            else
              meter(used: req.memRequest, scale: memAlloc, valueText: '${formatBytes(req.memRequest)} / ${formatBytes(memAlloc)}', format: formatBytes),
          if (layout.showPods)
            meter(
              used: n.alloc.activePods.toDouble(),
              scale: podsAlloc,
              valueText: '${n.alloc.activePods} / ${n.podsAlloc}',
              format: (v) => v.toStringAsFixed(0),
            ),
          SizedBox(
            width: _Layout.menuW,
            child: type == null ? null : _NodeMenu(n: n, ctx: PanelContext(object: n.node, type: type, api: context.read<ApiClient>(), app: app), readOnly: readOnly, onChanged: onChanged),
          ),
        ]),
      ),
    );
  }

  Widget _statusBadge() => n.cordoned && n.ready
      ? const StatusBadge('Cordoned', severity: Severity.warn, dense: true)
      : StatusBadge(n.ready ? 'Ready' : 'NotReady', dense: true);
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
