/// Network throughput without Prometheus: live receive/transmit rates from
/// the kubelet Summary API for the Pod and Node panels. With Prometheus the
/// history charts already show network, so this stays hidden.
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../panels/panel.dart';
import '../api/models.dart';
import '../prometheus/metric_history_chart.dart' show formatMetric, MetricUnit, usesHostNetwork;
import '../prometheus/prom_api.dart';
import '../state/poller.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'cache.dart';
import 'kubelet_summary.dart';

String formatRate(double? bytesPerSec) => bytesPerSec == null ? '—' : formatMetric(bytesPerSec, MetricUnit.bytesPerSec);

/// Live network section for a Pod (on its node) or a Node panel; nothing for
/// other kinds, unscheduled pods, or when Prometheus is available. A
/// hostNetwork pod gets a note pointing at its node instead: its counters
/// are the node's traffic, not its own.
Widget liveNetworkSection(PanelContext ctx) {
  final isNode = ctx.type.kind == 'Node';
  final node = isNode ? ctx.name : dig<String>(ctx.spec, ['nodeName']);
  if (node == null || node.isEmpty) return const SizedBox.shrink();
  if (!isNode && usesHostNetwork(ctx.spec)) return HostNetworkNote(node: node);
  return LiveNetwork(
    key: ValueKey('live-net-${ctx.uid}/$node'),
    api: ctx.api,
    node: node,
    namespace: isNode ? null : ctx.namespace,
    pod: isNode ? null : ctx.name,
  );
}

class LiveNetwork extends StatefulWidget {
  final ApiClient api;
  final String node;

  /// Pod namespace/name; null for the node itself.
  final String? namespace;
  final String? pod;
  const LiveNetwork({super.key, required this.api, required this.node, this.namespace, this.pod});

  @override
  State<LiveNetwork> createState() => _LiveNetworkState();
}

class _LiveNetworkState extends State<LiveNetwork> with PollingState {
  /// Null until known. With Prometheus the section stays hidden for good.
  bool? _prom;
  NetThroughput? _net;

  @override
  void initState() {
    super.initState();
    _load();
    poll(const Duration(seconds: 15), () async {
      await _load();
      return true;
    });
  }

  Future<void> _load() async {
    // Prometheus' history charts cover network; don't repeat it.
    _prom ??= await PromApi.of(widget.api).hasPrometheus();
    if (_prom!) return;
    final s = await MetricsCache.of(widget.api).summary(widget.namespace, nodes: [widget.node]);
    if (!mounted) return;
    NetThroughput? net;
    if (s.available) {
      final want = widget.pod == null ? widget.node : '${widget.namespace}/${widget.pod}';
      net = (widget.pod == null ? s.nodeNetwork : s.pods).where((n) => n.key == want).firstOrNull;
    }
    // Hidden (quietly) while the kubelet can't be read.
    setState(() => _net = net);
  }

  @override
  Widget build(BuildContext context) {
    final net = _net;
    if (_prom != false || net == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final big = theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600);
    Widget stat(IconData icon, String label, double? v) => Padding(
      padding: const EdgeInsets.only(right: 24),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(icon, size: 14, color: theme.hintColor),
        const SizedBox(width: 4),
        Text(net.measured ? formatRate(v) : '…', style: big),
        const SizedBox(width: 6),
        Text(label, style: hint),
      ]),
    );
    return DetailSection(
      title: 'Network',
      icon: Icons.swap_vert,
      trailing: Text(net.measured ? 'live, from the kubelet' : 'measuring…', style: hint),
      child: Wrap(children: [
        stat(Icons.south, 'receive', net.rx),
        stat(Icons.north, 'transmit', net.tx),
      ]),
    );
  }
}

/// Monospace rate text for tables.
Widget rateCell(BuildContext context, double? v) =>
    Text(formatRate(v), maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5, color: v == null ? Theme.of(context).hintColor : null));

/// "Uses the host network — see node `x`", for hostNetwork pods.
class HostNetworkNote extends StatelessWidget {
  final String node;
  const HostNetworkNote({super.key, required this.node});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return DetailSection(
      title: 'Network',
      icon: Icons.swap_vert,
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, children: [
        Text('Uses the host network \u2014 see node', style: hint),
        ResourceLink(ObjectRef(kind: 'Node', name: node), label: node),
      ]),
    );
  }
}
