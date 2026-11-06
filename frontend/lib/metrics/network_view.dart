import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../prometheus/metric_history_chart.dart' show promQuote, nodeNetRate;
import '../prometheus/prom_api.dart';
import '../state/app_state.dart';
import '../state/poller.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'cache.dart';
import 'kubelet_summary.dart';
import 'network_usage.dart';
import 'sortable_table.dart';

/// Network throughput by node and the busiest pods ("top talkers"), from
/// Prometheus when available, else live from the kubelets.
class NetworkView extends StatefulWidget {
  final NamespaceScope scope;
  const NetworkView({super.key, required this.scope});

  @override
  State<NetworkView> createState() => _NetworkViewState();
}

/// Prometheus rates as [NetThroughput]s: nodes and pods. Null when there is
/// no Prometheus or it has no network series.
Future<(List<NetThroughput>, List<NetThroughput>)?> promNetwork(ApiClient api, String? namespace) async {
  final prom = PromApi.of(api);
  if (!await prom.hasPrometheus()) return null;
  final set = namespace?.split(',') ?? const <String>[];
  final ns = switch (set.length) {
    0 => '',
    1 => 'namespace="${promQuote(set.first)}",',
    _ => 'namespace=~"${promQuote(set.map(RegExp.escape).join('|'))}",',
  };
  // hostNetwork pods see the node's traffic: drop them (needs kube-state-metrics;
  // without it `unless` matches nothing and the caller's spec filter applies).
  String pods(String dir) =>
      'topk(150, sum by (namespace, pod) (max by (namespace, pod, interface) (rate(container_network_${dir}_bytes_total{${ns}interface!="lo"}[2m])))'
      ' unless on (namespace, pod) kube_pod_info{${ns}host_network="true"})';
  String nodes(String dir) =>
      'sum by (nodename) (${nodeNetRate('node_network_${dir}_bytes_total', '2m')} * on(instance) group_left(nodename) node_uname_info)';
  try {
    final r = await Future.wait([
      prom.query(pods('receive')),
      prom.query(pods('transmit')),
      prom.query(nodes('receive')),
      prom.query(nodes('transmit')),
    ]);
    List<NetThroughput> join(QueryData rx, QueryData tx, String Function(Map<String, String>) key, NetThroughput Function(String key, double? rx, double? tx) make) {
      final a = {for (final s in rx.series) if (s.points.isNotEmpty) key(s.metric): s.points.last.$2};
      final b = {for (final s in tx.series) if (s.points.isNotEmpty) key(s.metric): s.points.last.$2};
      return [for (final k in {...a.keys, ...b.keys}) make(k, a[k] ?? 0, b[k] ?? 0)];
    }

    final podList = join(r[0], r[1], (m) => '${m['namespace']}/${m['pod']}', (k, rx, tx) {
      final i = k.indexOf('/');
      return NetThroughput(namespace: k.substring(0, i), name: k.substring(i + 1), rx: rx, tx: tx);
    });
    final nodeList = join(r[2], r[3], (m) => m['nodename'] ?? '', (k, rx, tx) => NetThroughput(name: k, rx: rx, tx: tx));
    if (podList.isEmpty && nodeList.isEmpty) return null;
    return (nodeList, podList);
  } catch (_) {
    return null;
  }
}

class _NetworkViewState extends State<NetworkView> with AutomaticKeepAliveClientMixin, PollingState {
  List<NetThroughput>? _nodes;
  List<NetThroughput>? _pods;
  bool _prom = false;
  String? _unavailable;

  ApiClient get _api => context.read<ApiClient>();

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
    poll(const Duration(seconds: 15), () async {
      await _load();
      return true;
    });
  }

  /// `namespace/name` of hostNetwork pods: their counters are the node's.
  Future<Set<String>> _hostNetworkPods() async {
    try {
      return {
        for (final p in await _api.items(const ResourceRef(resource: 'pods'), scope: widget.scope))
          if (dig(p, ['spec', 'hostNetwork']) == true) '${dig(p, ['metadata', 'namespace'])}/${dig(p, ['metadata', 'name'])}',
      };
    } catch (_) {
      return const {};
    }
  }

  Future<void> _load() async {
    final hostF = _hostNetworkPods();
    final p = await promNetwork(_api, widget.scope.param);
    final host = await hostF;
    List<NetThroughput> own(List<NetThroughput> pods) => [for (final x in pods) if (!host.contains(x.key)) x];
    if (p != null) {
      if (mounted) {
        setState(() {
          _nodes = p.$1;
          _pods = own(p.$2);
          _prom = true;
          _unavailable = null;
        });
      }
      return;
    }
    final s = await MetricsCache.of(_api).summary(widget.scope.param);
    if (!mounted) return;
    setState(() {
      _prom = false;
      _nodes = s.nodeNetwork;
      _pods = own(s.pods);
      _unavailable = s.available ? null : (s.message ?? 'kubelet stats unavailable');
    });
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
    final nodes = _nodes, pods = _pods;
    if (nodes == null || pods == null) return const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)));
    if (_unavailable != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Network throughput is not available', style: theme.textTheme.titleSmall),
          const SizedBox(height: 6),
          Text('It needs Prometheus (cAdvisor and node-exporter metrics), or permission to read kubelet stats (get nodes/proxy). '
              '${_unavailable!}.', style: hint),
        ]),
      );
    }
    final detail = context.watch<AppState>().detail;
    final measuring = !_prom && pods.isNotEmpty && pods.every((p) => !p.measured);
    final source = _prom ? 'rates over 2m, via Prometheus' : (measuring ? 'measuring…' : 'live, via kubelet stats');

    List<MetricColumn<NetThroughput>> rateColumns() => [
      MetricColumn(label: 'Receive', width: 96, numeric: true, sortKey: (r) => r.rx, cell: (c, r) => rateCell(c, r.rx)),
      MetricColumn(label: 'Transmit', width: 96, numeric: true, sortKey: (r) => r.tx, cell: (c, r) => rateCell(c, r.tx)),
      MetricColumn(
        label: 'Total',
        width: 96,
        numeric: true,
        hideBelow: 420,
        sortKey: (r) => r.measured ? r.total : null,
        cell: (c, r) => rateCell(c, r.measured ? r.total : null),
      ),
    ];

    Widget title(String t, String count, {String? trailing}) => Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        Text(t, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
        const SizedBox(width: 8),
        Expanded(child: Text(count, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint)),
        if (trailing != null) Text(trailing, style: hint),
      ]),
    );

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 24),
      children: [
        title('Nodes', '${nodes.length}', trailing: source),
        SortableTable<NetThroughput>(
          rows: nodes,
          initialSort: 3,
          initialAscending: false,
          onTap: (r) => _open('Node', r.name, null),
          selected: (r) => detail?.type.kind == 'Node' && detail?.name == r.name,
          columns: [
            MetricColumn(label: 'Name', sortKey: (r) => r.name, cell: (c, r) => Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
            ...rateColumns(),
          ],
        ),
        const SizedBox(height: 18),
        title('Top pods', '${pods.length} · host-network pods excluded'),
        if (pods.isEmpty)
          Padding(padding: const EdgeInsets.only(top: 8), child: Text('No pod samples', style: hint))
        else
          SortableTable<NetThroughput>(
            rows: pods,
            initialSort: 3,
            initialAscending: false,
            limit: 50,
            onTap: (r) => _open('Pod', r.name, r.namespace),
            selected: (r) => detail?.type.kind == 'Pod' && detail?.name == r.name && detail?.namespace == r.namespace,
            columns: [
              MetricColumn(
                label: 'Pod',
                sortKey: (r) => r.key,
                cell: (c, r) => Text.rich(
                  TextSpan(children: [
                    if (widget.scope.single == null) TextSpan(text: '${r.namespace}/', style: TextStyle(color: theme.hintColor)),
                    TextSpan(text: r.name),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
              ...rateColumns(),
            ],
          ),
        if (!_prom && measuring)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: InlineMessage('Rates appear after the second sample from each kubelet (about 15 seconds).'),
          ),
      ],
    );
  }
}
