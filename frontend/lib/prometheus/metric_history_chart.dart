/// Metric history from Prometheus: a lean area chart with hover values,
/// plus ready-made CPU/memory sections for pods and nodes.
///
/// Panels add history with one line, e.g. `podHistory(ctx)`. It renders
/// nothing when the cluster has no reachable Prometheus.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../panels/panel.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'pod_markers.dart';
import 'prom_api.dart';
import '../api/error_info.dart' show errorText;

// ---------------------------------------------------------------------------
// One-line entry points for panels
// ---------------------------------------------------------------------------

/// Escapes a value for a double-quoted PromQL string.
String promQuote(String s) => s.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
String _q(String s) => promQuote(s);

/// Escapes regex metacharacters (e.g. the dots in a name) for `=~`.
String _re(String s) => s.replaceAllMapped(RegExp(r'[.*+?^${}()|\[\]\\]'), (m) => '\\${m[0]}');

/// Two series, "receive" and "transmit", labelled `direction`, from a
/// builder taking the counter's name.
String _rxTx(String Function(String metric) rate, String prefix) =>
    'label_replace(${rate('${prefix}_receive_bytes_total')}, "direction", "receive", "", "") or '
    'label_replace(${rate('${prefix}_transmit_bytes_total')}, "direction", "transmit", "", "")';

/// Pod network counters carry no real container label (the sandbox reports
/// them with container="" or "POD", and runtimes may repeat them per
/// container), so take the max per interface to count each NIC once.
String _podNet(String sel, String w, String metric, {String by = ''}) =>
    'max by (${by}interface) (rate($metric{$sel,interface!="lo"}[$w]))';

/// Devices excluded from node throughput: loopback, pod veths, CNI bridges,
/// tunnels and VLAN sub-interfaces (`eth0.10`); their traffic is already
/// counted on the NIC. Keep in step with `virtualIface` in
/// backend/internal/metrics/summary.go.
const nodeVirtualDevices =
    'lo|veth.*|cali.*|flannel.*|cni.*|docker.*|br-.*|virbr.*|vxlan.*|tunl.*|kube-ipvs.*|cilium.*|lxc.*|genev.*|nodelocaldns.*|'
    'dummy.*|sit.*|teql.*|ip6tnl.*|ipip.*|gre.*|erspan.*|ifb.*|nlmon.*|ip_vti.*|ip6_vti.*|ip6gre.*|.+[.].+';

/// Per-device rate of a node_network_* counter, by instance. On a node with
/// an up bond only bond* devices count: its slaves carry the same bytes, and
/// node-exporter doesn't say which NICs are slaves.
String nodeNetRate(String metric, String w) {
  const upBond = '(node_network_up{device=~"bond.*"} == 1)';
  return '((rate($metric{device!~"$nodeVirtualDevices"}[$w]) unless on(instance) $upBond) or '
      '(rate($metric{device=~"bond.*"}[$w]) and on(instance) $upBond))';
}

/// True for pods (or pod templates) on the host network: their counters are
/// the node's, so k8sman never shows them as the pod's own traffic.
bool usesHostNetwork(Map<String, dynamic> podSpec) => podSpec['hostNetwork'] == true;

/// CPU, memory and network history for a pod, with an optional per-container
/// breakdown (CPU and memory only: network is per pod). A hostNetwork pod
/// gets no network chart (see `liveNetworkSection`).
Widget podHistory(PanelContext ctx) {
  final hostNet = usesHostNetwork(ctx.spec);
  final pod = 'namespace="${_q(ctx.namespace ?? '')}",pod="${_q(ctx.name)}"';
  final sel = '$pod,container!="",container!="POD"';
  final res = podChartResources(ctx.spec);
  return MetricHistorySection(
    key: ValueKey('pod-history-${ctx.uid}'),
    api: ctx.api,
    breakdownLabel: 'container',
    markers: (start, end) async {
      final events = ctx.api.events(namespace: ctx.namespace, uid: ctx.uid);
      // Each container instance's start time: the restarts in the window
      // (the pod status only keeps the last one).
      var starts = const <String, List<DateTime>>{};
      try {
        final s = await PromApi.of(ctx.api).queryRange('max by (container) (container_start_time_seconds{$sel})',
            start: start, end: end, step: stepFor(end.difference(start)).step);
        starts = containerStarts(s.series, start, end);
      } catch (_) {}
      return podMarkers(ctx.object, await events, starts: starts);
    },
    charts: [
      MetricChartSpec(
        title: 'CPU',
        unit: MetricUnit.cores,
        resources: res.cpu,
        query: (w, by) => 'sum${by == null ? '' : ' by ($by)'} (rate(container_cpu_usage_seconds_total{$sel}[$w]))',
      ),
      MetricChartSpec(
        title: 'Memory',
        unit: MetricUnit.bytes,
        resources: res.memory,
        query: (w, by) => 'sum${by == null ? '' : ' by ($by)'} (container_memory_working_set_bytes{$sel})',
      ),
      if (!hostNet)
        MetricChartSpec(
          title: 'Network',
          unit: MetricUnit.bytesPerSec,
          seriesLabel: 'direction',
          query: (w, _) => _rxTx((m) => 'sum(${_podNet(pod, w, m)})', 'container_network'),
        ),
    ],
  );
}

/// A pod's CPU (cores) and memory (bytes) requests and limits, summed over
/// the containers that keep running (regular and sidecars). A limit counts
/// only when every one of them sets it (one without leaves the pod
/// unbounded).
({ChartResources cpu, ChartResources memory}) podChartResources(Map<String, dynamic> podSpec) {
  final cs = [
    ...asMapList(podSpec['containers']),
    for (final c in asMapList(podSpec['initContainers'])) if (c['restartPolicy'] == 'Always') c,
  ];
  double? sum(String kind, String res, double? Function(dynamic) parse, {required bool all}) {
    final vs = [for (final c in cs) parse(dig(c, ['resources', kind, res]))];
    final set = vs.whereType<double>();
    if (set.isEmpty || (all && set.length < vs.length)) return null;
    return set.fold<double>(0, (a, b) => a + b);
  }

  double? cores(dynamic q) => parseCpuMillis(q) == null ? null : parseCpuMillis(q)! / 1000;
  return (
    cpu: ChartResources(request: sum('requests', 'cpu', cores, all: false), limit: sum('limits', 'cpu', cores, all: true)),
    memory: ChartResources(request: sum('requests', 'memory', parseBytes, all: false), limit: sum('limits', 'memory', parseBytes, all: true)),
  );
}

/// CPU, memory and network history for a node (node-exporter, joined on
/// nodename).
Widget nodeHistory(PanelContext ctx) {
  final node = 'node_uname_info{nodename="${_q(ctx.name)}"}';
  return MetricHistorySection(
    key: ValueKey('node-history-${ctx.uid}'),
    api: ctx.api,
    charts: [
      MetricChartSpec(
        title: 'CPU',
        unit: MetricUnit.cores,
        query: (w, _) => 'sum(rate(node_cpu_seconds_total{mode!~"idle|iowait|steal"}[$w]) * on(instance) group_left(nodename) $node)',
      ),
      MetricChartSpec(
        title: 'Memory',
        unit: MetricUnit.bytes,
        query: (w, _) => 'sum((node_memory_MemTotal_bytes - node_memory_MemAvailable_bytes) * on(instance) group_left(nodename) $node)',
      ),
      MetricChartSpec(
        title: 'Network',
        unit: MetricUnit.bytesPerSec,
        seriesLabel: 'direction',
        query: (w, _) => _rxTx(
          (m) => 'sum(${nodeNetRate(m, w)} * on(instance) group_left(nodename) $node)',
          'node_network',
        ),
      ),
    ],
  );
}

/// The pods of a workload in PromQL: by owner via kube-state-metrics'
/// `kube_pod_owner` when present, else by the controller's pod-name pattern.
/// Null for kinds that aren't Deployment / StatefulSet / DaemonSet.
({String owner, String podRegex})? workloadPodMatch(String kind, String namespace, String name) {
  final ns = 'namespace="${_q(namespace)}"';
  final n = _q(_re(name));
  return switch (kind) {
    // Pods are owned by ReplicaSets named <deployment>-<pod-template-hash>.
    'Deployment' => (owner: 'kube_pod_owner{$ns,owner_kind="ReplicaSet",owner_name=~"$n-[a-z0-9]+"}', podRegex: '$n-[a-z0-9]+-[a-z0-9]+'),
    'StatefulSet' => (owner: 'kube_pod_owner{$ns,owner_kind="StatefulSet",owner_name="${_q(name)}"}', podRegex: '$n-[0-9]+'),
    'DaemonSet' => (owner: 'kube_pod_owner{$ns,owner_kind="DaemonSet",owner_name="${_q(name)}"}', podRegex: '$n-[a-z0-9]{5}'),
    _ => null,
  };
}

/// CPU, memory and network history summed over a workload's pods (with a
/// per-pod breakdown for CPU and memory). Renders nothing for other kinds.
Widget workloadHistory(PanelContext ctx) {
  final ns = ctx.namespace ?? '';
  final m = workloadPodMatch(ctx.type.kind, ns, ctx.name);
  if (m == null) return const SizedBox.shrink();
  final nsSel = 'namespace="${_q(ns)}"';
  final byNameSel = '$nsSel,pod=~"${m.podRegex}"';

  /// [perPod] yields one series per (namespace, pod) for a pod selector.
  /// Summed via the owner join, or (no kube-state-metrics) the name pattern.
  String overPods(String Function(String sel) perPod, String? by) {
    final agg = by == null ? 'sum' : 'sum by ($by)';
    return '$agg (${perPod(nsSel)} * on (namespace, pod) group_left() max by (namespace, pod) (${m.owner})) or $agg (${perPod(byNameSel)})';
  }

  final hostNet = usesHostNetwork(asMap(dig(ctx.spec, ['template', 'spec'])));
  return MetricHistorySection(
    key: ValueKey('workload-history-${ctx.uid}'),
    api: ctx.api,
    breakdownLabel: 'pod',
    note: hostNet ? 'Pods use the host network, so their traffic is their nodes\' (see the Node panels).' : null,
    charts: [
      MetricChartSpec(
        title: 'CPU',
        unit: MetricUnit.cores,
        query: (w, by) =>
            overPods((s) => 'sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{$s,container!="",container!="POD"}[$w]))', by),
      ),
      MetricChartSpec(
        title: 'Memory',
        unit: MetricUnit.bytes,
        query: (w, by) => overPods((s) => 'sum by (namespace, pod) (container_memory_working_set_bytes{$s,container!="",container!="POD"})', by),
      ),
      if (!hostNet)
        MetricChartSpec(
          title: 'Network',
          unit: MetricUnit.bytesPerSec,
          seriesLabel: 'direction',
          query: (w, _) => _rxTx((metric) => '(${overPods((s) => 'sum by (namespace, pod) (${_podNet(s, w, metric, by: 'namespace, pod, ')})', null)})', 'container_network'),
        ),
    ],
  );
}

/// Used vs capacity history of a PVC (kubelet volume stats).
Widget pvcHistory(PanelContext ctx) {
  final sel = 'namespace="${_q(ctx.namespace ?? '')}",persistentvolumeclaim="${_q(ctx.name)}"';
  return MetricHistorySection(
    key: ValueKey('pvc-history-${ctx.uid}'),
    api: ctx.api,
    title: 'Usage history',
    initialRange: const Duration(days: 1),
    // Some Prometheus setups scrape the kubelet but drop volume stats.
    probe: 'max(last_over_time(kubelet_volume_stats_used_bytes{$sel}[7d]))',
    charts: [
      MetricChartSpec(
        title: 'Used',
        unit: MetricUnit.bytes,
        seriesLabel: 'series',
        query: (w, _) =>
            'label_replace(max(kubelet_volume_stats_used_bytes{$sel}), "series", "used", "", "") or '
            'label_replace(max(kubelet_volume_stats_capacity_bytes{$sel}), "series", "capacity", "", "")',
      ),
    ],
  );
}

// ---------------------------------------------------------------------------
// Specs and formatting
// ---------------------------------------------------------------------------

enum MetricUnit { cores, bytes, bytesPerSec, plain, percent }

String formatMetric(double v, MetricUnit unit) {
  switch (unit) {
    case MetricUnit.cores:
      if (v == 0) return '0';
      if (v < 1) {
        final m = v * 1000;
        return m < 10 ? '${m.toStringAsFixed(1)}m' : '${m.round()}m';
      }
      return v < 10 ? v.toStringAsFixed(2) : v.toStringAsFixed(1);
    case MetricUnit.bytes:
      const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
      var x = v;
      var i = 0;
      while (x >= 1024 && i < units.length - 1) {
        x /= 1024;
        i++;
      }
      return '${x < 10 && i > 0 ? x.toStringAsFixed(1) : x.round()} ${units[i]}';
    case MetricUnit.bytesPerSec:
      return '${formatMetric(v, MetricUnit.bytes)}/s';
    case MetricUnit.percent:
      return '${(v * 100).toStringAsFixed(v < 0.1 ? 1 : 0)}%';
    case MetricUnit.plain:
      if (v.abs() >= 1e6) return '${(v / 1e6).toStringAsFixed(1)}M';
      if (v.abs() >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}k';
      return v == v.roundToDouble() ? '${v.round()}' : v.toStringAsFixed(2);
  }
}

/// One chart: a PromQL builder taking the rate window (e.g. `2m`) and an
/// optional breakdown label (e.g. `container`).
class MetricChartSpec {
  final String title;
  final MetricUnit unit;
  final String Function(String window, String? by) query;

  /// A label that always names the series (e.g. `direction` for receive /
  /// transmit). Such a chart ignores the section's breakdown, shows each
  /// series' latest value in its header, and orders series as the query
  /// mentions their label values.
  final String? seriesLabel;

  /// Requests and limits to measure against (in [unit]): faint labelled
  /// lines on the summed chart and a share beside the "now" value.
  final ChartResources? resources;
  const MetricChartSpec({required this.title, required this.unit, required this.query, this.seriesLabel, this.resources});
}

/// A request and/or limit for a [MetricChartSpec] (either may be null:
/// none set).
class ChartResources {
  final double? request;
  final double? limit;
  const ChartResources({this.request, this.limit});

  bool get isEmpty => request == null && limit == null;

  /// "4% of limit" (else of request), or "no request set".
  String share(double now) {
    final base = limit ?? request;
    if (base == null || base <= 0) return 'no request set';
    final pct = now / base * 100;
    return '${pct < 1 && pct > 0 ? '<1' : pct.round()}% of ${limit != null ? 'limit' : 'request'}';
  }

  /// "request 50m · limit 200m" (or "no request or limit set").
  String describe(MetricUnit unit) => isEmpty
      ? 'no request or limit set'
      : [if (request != null) 'request ${formatMetric(request!, unit)}', if (limit != null) 'limit ${formatMetric(limit!, unit)}'].join(' · ');
}

/// Selectable time ranges.
const historyRanges = <(String, Duration)>[
  ('10m', Duration(minutes: 10)),
  ('15m', Duration(minutes: 15)),
  ('1h', Duration(hours: 1)),
  ('6h', Duration(hours: 6)),
  ('1d', Duration(days: 1)),
  ('1w', Duration(days: 7)),
];

/// The range charts first open with: the Prometheus module's `defaultRange`
/// setting, else 1h.
Future<Duration> defaultHistoryRange(PromApi prom) async {
  final label = await prom.defaultRangeLabel();
  return historyRanges.firstWhere((r) => r.$1 == label, orElse: () => historyRanges[2]).$2;
}

/// Step for ~240 points, and a rate window of at least 4 steps (and 2m, so
/// a 30s scrape interval always has samples).
({Duration step, String window}) stepFor(Duration range) {
  final step = Duration(seconds: math.max(1, range.inSeconds ~/ 240));
  final w = math.max(120, step.inSeconds * 4);
  return (step: step, window: w % 60 == 0 ? '${w ~/ 60}m' : '${w}s');
}

// ---------------------------------------------------------------------------
// Section: availability check, range picker, charts
// ---------------------------------------------------------------------------

/// A "Metrics history" section with a range picker and one chart per spec.
/// Hidden entirely when no reachable Prometheus is discovered.
class MetricHistorySection extends StatefulWidget {
  final ApiClient api;
  final List<MetricChartSpec> charts;

  /// Offer a "per <label>" breakdown (e.g. per container) when set.
  final String? breakdownLabel;
  final String title;
  /// Null = the Prometheus module's default range setting.
  final Duration? initialRange;

  /// An instant query that must return a series, else the section hides
  /// (e.g. Prometheus exists but doesn't have this object's metrics).
  final String? probe;

  /// A hint line under the charts.
  final String? note;

  /// Events to mark on every chart, for the charts' time window; fetched
  /// on open and again with each range change (which re-queries the
  /// charts). Failures just mean no markers.
  final Future<List<ChartMarker>> Function(DateTime start, DateTime end)? markers;

  const MetricHistorySection({
    super.key,
    required this.api,
    required this.charts,
    this.breakdownLabel,
    this.title = 'Metrics history',
    this.initialRange,
    this.probe,
    this.note,
    this.markers,
  });

  @override
  State<MetricHistorySection> createState() => _MetricHistorySectionState();
}

class _MetricHistorySectionState extends State<MetricHistorySection> {
  late final PromApi _prom = PromApi.of(widget.api);
  late final Future<bool> _available = _check();

  Future<bool> _check() async {
    if (!await _prom.hasPrometheus()) return false;
    _range ??= await defaultHistoryRange(_prom);
    final probe = widget.probe;
    if (probe == null) return true;
    try {
      return (await _prom.query(probe)).series.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
  late Duration? _range = widget.initialRange;
  bool _breakdown = false;
  List<ChartMarker> _markers = const [];

  /// One window end for every chart (set with each range), so their time
  /// axes line up exactly.
  DateTime _end = DateTime.now();

  @override
  void initState() {
    super.initState();
    _available.then((ok) {
      if (ok && mounted) _loadMarkers();
    });
  }

  Future<void> _loadMarkers() async {
    final load = widget.markers;
    final range = _range;
    if (load == null || range == null) return;
    final end = _end;
    try {
      final m = await load(end.subtract(range), end);
      if (mounted && end == _end) setState(() => _markers = m);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<bool>(
      future: _available,
      builder: (context, snap) {
        if (snap.data != true) return const SizedBox.shrink();
        final theme = Theme.of(context);
        return DetailSection(
          title: widget.title,
          icon: Icons.show_chart,
          trailing: RangePicker(value: _range!, onChanged: (r) {
            setState(() {
              _range = r;
              _end = DateTime.now();
            });
            _loadMarkers();
          }),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final spec in widget.charts)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: MetricHistoryChart(
                  key: ValueKey('${spec.title}/${_range!.inSeconds}/${_end.millisecondsSinceEpoch}/$_breakdown'),
                  prom: _prom,
                  spec: spec,
                  range: _range!,
                  end: _end,
                  breakdown: _breakdown ? widget.breakdownLabel : null,
                  markers: _markers,
                ),
              ),
            if (widget.note != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(widget.note!, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              ),
            if (widget.breakdownLabel != null)
              Align(
                alignment: Alignment.centerLeft,
                child: Hoverable(
                  onTap: () => setState(() => _breakdown = !_breakdown),
                  builder: (h) => Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(_breakdown ? Icons.check_box_outlined : Icons.check_box_outline_blank, size: 14, color: theme.hintColor),
                    const SizedBox(width: 5),
                    Text('Per ${widget.breakdownLabel}', style: theme.textTheme.bodySmall?.copyWith(color: h ? theme.colorScheme.onSurface : theme.hintColor)),
                  ]),
                ),
              ),
          ]),
        );
      },
    );
  }
}

class RangePicker extends StatelessWidget {
  final Duration value;
  final ValueChanged<Duration> onChanged;
  final List<(String, Duration)> ranges;
  const RangePicker({super.key, required this.value, required this.onChanged, this.ranges = historyRanges});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final (label, d) in ranges)
        Hoverable(
          onTap: () => onChanged(d),
          builder: (h) => Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            margin: const EdgeInsets.only(left: 1),
            decoration: BoxDecoration(
              color: d == value ? colors.selection : (h ? colors.hover : null),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              label,
              style: theme.textTheme.labelSmall?.copyWith(
                color: d == value ? theme.colorScheme.onSurface : theme.hintColor,
                fontWeight: d == value ? FontWeight.w600 : null,
              ),
            ),
          ),
        ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// The chart
// ---------------------------------------------------------------------------

/// Runs a range query once and draws it. Re-key it to refetch.
class MetricHistoryChart extends StatefulWidget {
  final PromApi prom;
  final MetricChartSpec spec;
  final Duration range;
  final String? breakdown;
  final double height;
  final List<ChartMarker> markers;

  /// The window's end (default now); charts in a section share one, so
  /// their time axes line up.
  final DateTime? end;
  const MetricHistoryChart({super.key, required this.prom, required this.spec, required this.range, this.breakdown, this.height = 76, this.markers = const [], this.end});

  @override
  State<MetricHistoryChart> createState() => _MetricHistoryChartState();
}

class _MetricHistoryChartState extends State<MetricHistoryChart> {
  late final Future<QueryData> _data;
  late final String _query;
  late final DateTime _end = widget.end ?? DateTime.now();

  @override
  void initState() {
    super.initState();
    final s = stepFor(widget.range);
    _query = widget.spec.query(s.window, widget.spec.seriesLabel == null ? widget.breakdown : null);
    _data = widget.prom.queryRange(_query, start: _end.subtract(widget.range), end: _end, step: s.step);
  }

  /// Request and limit as faint labelled lines across the window, on the
  /// summed chart only (per-container lines would need one each). A line
  /// far above the data (more than 4× its peak) isn't drawn, so the data
  /// keeps its height; its label sits at the top right with an arrow.
  (List<ChartGuide>, double?) _guides(List<MetricSeries> series) {
    final r = widget.spec.resources;
    if (r == null || r.isEmpty || widget.breakdown != null || series.isEmpty) return (const [], null);
    final start = _end.subtract(widget.range);
    final unit = widget.spec.unit;
    ChartGuide line(String name, double v) =>
        ChartGuide(name, [(start, v), (_end, v)], faint: true, dashed: name == 'request', label: '$name ${formatMetric(v, unit)}');
    final peak = [for (final s in series) for (final p in s.points) p.$2].fold<double>(0, math.max);
    final guides = [if (r.request != null) line('request', r.request!), if (r.limit != null) line('limit', r.limit!)];
    final shown = [for (final g in guides) g.points.first.$2].where((v) => peak <= 0 || v <= peak * 4);
    final yMax = [peak, ...shown].fold<double>(0, math.max);
    return (guides, yMax <= 0 ? null : yMax);
  }

  /// Series in the order the query names their [MetricChartSpec.seriesLabel] values.
  List<MetricSeries> _ordered(List<MetricSeries> series) {
    final k = widget.spec.seriesLabel;
    if (k == null) return series;
    int pos(MetricSeries s) {
      final i = _query.indexOf('"${s.metric[k]}"');
      return i < 0 ? 1 << 30 : i;
    }

    return [...series]..sort((a, b) => pos(a).compareTo(pos(b)));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return FutureBuilder<QueryData>(
      future: _data,
      builder: (context, snap) {
        final data = snap.data;
        final series = _ordered(data?.series.where((s) => s.points.isNotEmpty).toList() ?? const <MetricSeries>[]);
        final latest = series.isEmpty ? null : series.map((s) => s.points.last.$2).fold<double>(0, (a, b) => a + b);
        final k = widget.spec.seriesLabel;
        final res = widget.spec.resources;
        // "now 5.3 MiB · 4% of limit"; with no data yet, what it's held to.
        final nowText = latest == null
            ? (res == null || snap.connectionState != ConnectionState.done ? null : res.describe(widget.spec.unit))
            : k == null
            ? ['now ${formatMetric(latest, widget.spec.unit)}', ?res?.share(latest)].join(' · ')
            : 'now ${series.map((s) => '${s.metric[k] ?? ''} ${formatMetric(s.points.last.$2, widget.spec.unit)}').join(' · ')}';
        final header = Row(children: [
          Text(widget.spec.title, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          const Spacer(),
          if (nowText != null)
            Flexible(
              flex: 6,
              child: Tooltip(
                message: res == null ? '' : res.describe(widget.spec.unit),
                child: Text(nowText, key: ValueKey('chart-now-${widget.spec.title}'), maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: hint),
              ),
            ),
        ]);
        final (guides, yMax) = _guides(series);
        Widget body;
        if (snap.hasError) {
          body = _ChartMessage('Query failed: ${errorText(snap.error!)}', height: widget.height);
        } else if (data == null) {
          body = SizedBox(height: widget.height, child: const Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))));
        } else if (series.isEmpty) {
          body = _ChartMessage('No data in this range', height: widget.height);
        } else {
          body = AreaChart(
            series: series,
            unit: widget.spec.unit,
            height: widget.height,
            labelKey: widget.spec.seriesLabel ?? widget.breakdown,
            range: widget.range,
            seriesName: widget.spec.title,
            markers: widget.markers,
            window: (_end.subtract(widget.range), _end),
            guides: guides,
            yMax: yMax,
            labelGuides: guides.isNotEmpty,
          );
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [header, const SizedBox(height: 4), body]);
      },
    );
  }
}

class _ChartMessage extends StatelessWidget {
  final String text;
  final double height;
  const _ChartMessage(this.text, {required this.height});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      height: height,
      alignment: Alignment.center,
      decoration: BoxDecoration(border: Border.all(color: AppColors.of(context).separator), borderRadius: BorderRadius.circular(6)),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Text(text, maxLines: 2, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
    );
  }
}

/// Series colours: the accent first, then calm, distinguishable hues.
List<Color> seriesColors(BuildContext context) {
  final dark = Theme.of(context).brightness == Brightness.dark;
  return [
    Theme.of(context).colorScheme.primary,
    dark ? const Color(0xFF4CC3B5) : const Color(0xFF138A7E),
    dark ? const Color(0xFFB59CF5) : const Color(0xFF6B4FBB),
    dark ? const Color(0xFFE6A06A) : const Color(0xFFB0602A),
    dark ? const Color(0xFF8FB4D8) : const Color(0xFF4A6E91),
    dark ? const Color(0xFFD48BB0) : const Color(0xFF9E3D6E),
  ];
}

/// A reference line drawn behind an [AreaChart]'s series (e.g. requests,
/// allocatable): always a plain line, never filled.
class ChartGuide {
  final String name;
  final List<(DateTime, double)> points;
  final bool dashed;

  /// Thin and faint (a ceiling) rather than a normal-weight line.
  final bool faint;

  /// Its label on the chart (with `labelGuides`), e.g. "limit 128 MiB";
  /// default [name].
  final String? label;
  const ChartGuide(this.name, this.points, {this.dashed = false, this.faint = false, this.label});
}

/// Area (one series) or stacked lines (several) with a hover readout.
class AreaChart extends StatefulWidget {
  final List<MetricSeries> series;
  final MetricUnit unit;
  final double height;

  /// Label naming each series in the legend/tooltip (e.g. `container`).
  final String? labelKey;
  final Duration range;

  /// Name of a single unlabelled series in the tooltip.
  final String seriesName;

  /// Reference lines; they count towards the scale and show in the hover.
  final List<ChartGuide> guides;

  /// Fixes the top of the scale (rounded up to a tidy value) instead of fitting every line.
  final double? yMax;

  /// Names each guide at its right end instead of in a legend. A guide
  /// above [yMax] isn't drawn (it would be clamped to the top); its name
  /// and latest value sit at the top right with an arrow ("requested
  /// 240 cores ↑").
  final bool labelGuides;

  /// Events on the time axis: ticks along the bottom edge, below the data.
  /// Hovering one shows its tooltip instead of the value readout. A
  /// restart also draws a faint line up through the data.
  final List<ChartMarker> markers;

  /// The time axis' extent; default the data's. Stacked charts pass the
  /// same window so their axes (and restart lines) line up exactly.
  final (DateTime, DateTime)? window;
  const AreaChart({
    this.window,
    super.key,
    required this.series,
    required this.unit,
    required this.range,
    this.height = 76,
    this.labelKey,
    this.seriesName = 'value',
    this.guides = const [],
    this.yMax,
    this.labelGuides = false,
    this.markers = const [],
  });

  @override
  State<AreaChart> createState() => _AreaChartState();
}

class _AreaChartState extends State<AreaChart> {
  double? _hoverX;
  double? _hoverY;

  String _name(MetricSeries s, int i) {
    final k = widget.labelKey;
    if (k != null && s.metric[k] != null) return s.metric[k]!;
    if (s.metric.isEmpty) return widget.series.length == 1 ? widget.seriesName : 'series ${i + 1}';
    return s.metric.entries.map((e) => '${e.key}=${e.value}').join(',');
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = seriesColors(context);
    final hint = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontSize: 10);
    final all = [for (final s in widget.series) ...s.points];
    // The window, widened only if the data somehow falls outside it.
    final window = widget.window;
    final dMin = all.map((p) => p.$1.millisecondsSinceEpoch).reduce(math.min);
    final dMax = all.map((p) => p.$1.millisecondsSinceEpoch).reduce(math.max);
    final tMin = (window == null ? dMin : math.min(dMin, window.$1.millisecondsSinceEpoch)).toDouble();
    final tMax = (window == null ? dMax : math.max(dMax, window.$2.millisecondsSinceEpoch)).toDouble();
    final vMax = widget.yMax != null ? _niceMax(widget.yMax!) : _niceMax([...all, for (final g in widget.guides) ...g.points].map((p) => p.$2).fold<double>(0, math.max));
    final multi = widget.series.length > 1;
    final onScale = [for (final g in widget.guides) if (!widget.labelGuides || g.points.isEmpty || g.points.last.$2 <= vMax) g];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, box) {
        final width = box.maxWidth;
        final sync = ChartHoverSync.maybeOf(context);
        DateTime timeAt(double x) => DateTime.fromMillisecondsSinceEpoch((tMin + (x / width).clamp(0.0, 1.0) * (tMax - tMin)).round());
        // Hovered here, or following another chart's hover when its time
        // falls inside this chart's range.
        double? hoverX = _hoverX;
        final shared = sync?.value;
        if (hoverX == null && shared != null && tMax > tMin) {
          final ms = shared.millisecondsSinceEpoch.toDouble();
          if (ms >= tMin && ms <= tMax) hoverX = (ms - tMin) / (tMax - tMin) * width;
        }
        // Markers: clustered by pixel distance, hit-tested only in the band.
        final clusters = tMax > tMin ? _cluster(widget.markers, tMin, tMax, width) : const <_MarkerCluster>[];
        final band = clusters.isEmpty ? 0.0 : _markerBand;
        final total = widget.height + band;
        _MarkerCluster? active;
        if (_hoverX != null && _hoverY != null && _hoverY! >= widget.height - 4) active = _clusterAt(clusters, _hoverX!);
        if (active != null) hoverX = null;
        final hoverT = hoverX == null || tMax <= tMin ? null : timeAt(hoverX);
        final readout = hoverT == null ? null : _readout(hoverT);
        return MouseRegion(
          onHover: (e) {
            setState(() {
              _hoverX = e.localPosition.dx;
              _hoverY = e.localPosition.dy;
            });
            if (tMax <= tMin) return;
            final c = _hoverY! >= widget.height - 4 ? _clusterAt(clusters, _hoverX!) : null;
            sync?.value = c?.time ?? timeAt(e.localPosition.dx);
          },
          onExit: (_) {
            setState(() => _hoverX = _hoverY = null);
            sync?.value = null;
          },
          child: SizedBox(
            height: total,
            child: Stack(clipBehavior: Clip.none, children: [
              Positioned.fill(
                child: CustomPaint(
                  painter: _AreaPainter(
                    series: widget.series,
                    colors: colors,
                    tMin: tMin,
                    tMax: tMax,
                    vMax: vMax,
                    grid: AppColors.of(context).separator,
                    hoverX: hoverX,
                    fill: !multi,
                    guides: onScale,
                    guideColor: theme.hintColor,
                    band: band,
                    clusters: clusters,
                    active: active,
                    severityColors: _severityColors(context),
                    badge: hint?.copyWith(fontSize: 8.5),
                  ),
                ),
              ),
              if (active != null)
                Positioned(
                  bottom: band + 3,
                  left: (active.x + 8 + 220 > width) ? null : math.max(0, active.x - 8),
                  right: (active.x + 8 + 220 > width) ? math.max(0, width - active.x - 8) : null,
                  child: _MarkerTooltip(cluster: active, colors: _severityColors(context)),
                ),
              Positioned(left: 0, top: -1, child: Text(formatMetric(vMax, widget.unit), style: hint)),
              if (widget.labelGuides) ..._guideLabels(vMax, onScale, hint),
              if (readout != null && active == null)
                Positioned(
                  top: 2,
                  left: (hoverX! + 8 + 150 > width) ? null : hoverX + 8,
                  right: (hoverX + 8 + 150 > width) ? width - hoverX + 8 : null,
                  child: _Tooltip(
                    time: hoverT!,
                    rows: [
                      for (final (i, v) in readout)
                        (colors[i % colors.length], _name(widget.series[i], i), formatMetric(v, widget.unit)),
                      for (final g in widget.guides)
                        if (_nearest(g.points, hoverT) case final v?) (theme.hintColor, g.name, formatMetric(v, widget.unit)),
                    ],
                  ),
                ),
            ]),
          ),
        );
      }),
      const SizedBox(height: 2),
      Row(children: [
        Text(_timeLabel(DateTime.fromMillisecondsSinceEpoch(tMin.round())), style: hint),
        const Spacer(),
        Text(_timeLabel(DateTime.fromMillisecondsSinceEpoch(tMax.round())), style: hint),
      ]),
      if (multi)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Wrap(spacing: 10, runSpacing: 2, children: [
            for (final (i, s) in widget.series.indexed)
              Row(mainAxisSize: MainAxisSize.min, children: [
                Container(width: 8, height: 2, color: colors[i % colors.length]),
                const SizedBox(width: 4),
                Text(_name(s, i), style: hint),
              ]),
          ]),
        ),
    ]);
  }

  /// Markers inside the time range, sorted, merged when their ticks are
  /// within [_clusterPx] of the cluster's first one.
  static List<_MarkerCluster> _cluster(List<ChartMarker> markers, double tMin, double tMax, double width) {
    final inRange = [
      for (final m in markers)
        if (m.time.millisecondsSinceEpoch >= tMin && m.time.millisecondsSinceEpoch <= tMax) m
    ]..sort((a, b) => a.time.compareTo(b.time));
    final out = <_MarkerCluster>[];
    double? startX;
    for (final m in inRange) {
      final x = (m.time.millisecondsSinceEpoch - tMin) / (tMax - tMin) * width;
      if (out.isNotEmpty && x - startX! <= _clusterPx) {
        out.last.items.add(m);
      } else {
        startX = x;
        out.add(_MarkerCluster(x, [m]));
      }
    }
    return out;
  }

  /// The cluster nearest [x] within [_markerHitPx] (binary search on the sorted xs).
  static _MarkerCluster? _clusterAt(List<_MarkerCluster> cs, double x) {
    var lo = 0, hi = cs.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      cs[mid].x < x ? lo = mid + 1 : hi = mid;
    }
    _MarkerCluster? best;
    for (final i in [lo - 1, lo]) {
      if (i < 0 || i >= cs.length) continue;
      if ((cs[i].x - x).abs() <= _markerHitPx && (best == null || (cs[i].x - x).abs() < (best.x - x).abs())) best = cs[i];
    }
    return best;
  }

  /// Names at the right end of the guides on the scale (above the line,
  /// nudged apart), and name, value and an arrow for those above it.
  List<Widget> _guideLabels(double vMax, List<ChartGuide> onScale, TextStyle? hint) {
    final h = widget.height;
    double y(double v) => h - 1 - (v / vMax).clamp(0.0, 1.0) * (h - 1 - _chartTopPad);
    final unit = widget.unit == MetricUnit.cores ? ' cores' : '';
    final out = <Widget>[];
    var top = -1.0;
    for (final g in widget.guides) {
      if (g.points.isEmpty || onScale.contains(g)) continue;
      out.add(Positioned(right: 0, top: top, child: Text('${g.label ?? '${g.name} ${formatMetric(g.points.last.$2, widget.unit)}$unit'} ↑', style: hint)));
      top += 12;
    }
    final placed = <double>[];
    final ordered = [for (final g in onScale) if (g.points.isNotEmpty) (g, y(g.points.last.$2))]..sort((a, b) => a.$2.compareTo(b.$2));
    for (final (g, gy) in ordered) {
      var t = gy - 15;
      if (t < top) t = gy + 2; // under the line when there's no room above
      for (final p in placed) {
        if ((t - p).abs() < 12) t = p + 12;
      }
      placed.add(t);
      out.add(Positioned(right: 0, top: t, child: Text(g.label ?? g.name, style: hint)));
    }
    return out;
  }

  static double? _nearest(List<(DateTime, double)> points, DateTime t) {
    (DateTime, double)? best;
    for (final p in points) {
      if (best == null || p.$1.difference(t).abs() < best.$1.difference(t).abs()) best = p;
    }
    return best?.$2;
  }

  /// Nearest point of each series to [t].
  List<(int, double)> _readout(DateTime t) {
    final out = <(int, double)>[];
    for (final (i, s) in widget.series.indexed) {
      (DateTime, double)? best;
      for (final p in s.points) {
        if (best == null || (p.$1.difference(t).abs() < best.$1.difference(t).abs())) best = p;
      }
      if (best != null) out.add((i, best.$2));
    }
    return out;
  }

  String _timeLabel(DateTime t) {
    final l = t.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final hm = '${two(l.hour)}:${two(l.minute)}';
    return widget.range > const Duration(days: 1) ? '${l.month}/${l.day} $hm' : hm;
  }

  static double _niceMax(double v) {
    if (v <= 0) return 1;
    final exp = math.pow(10, (math.log(v) / math.ln10).floor()).toDouble();
    for (final m in const [1.0, 1.2, 1.5, 2.0, 2.5, 3.0, 4.0, 5.0, 6.0, 8.0, 10.0]) {
      if (v <= m * exp) return m * exp;
    }
    return 10 * exp;
  }
}

class _Tooltip extends StatelessWidget {
  final DateTime time;
  final List<(Color, String, String)> rows;
  const _Tooltip({required this.time, required this.rows});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = time.toLocal();
    String two(int n) => n.toString().padLeft(2, '0');
    final small = theme.textTheme.labelSmall?.copyWith(fontSize: 10.5);
    return IgnorePointer(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 200),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: AppColors.of(context).separator),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${two(l.hour)}:${two(l.minute)}:${two(l.second)}', style: small?.copyWith(color: theme.hintColor)),
          for (final (c, name, v) in rows)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
              const SizedBox(width: 4),
              Flexible(child: Text(name, overflow: TextOverflow.ellipsis, style: small?.copyWith(color: theme.hintColor))),
              const SizedBox(width: 6),
              Text(v, style: small?.copyWith(fontWeight: FontWeight.w600)),
            ]),
        ]),
      ),
    );
  }
}

/// Space above the max gridline for its label.
const _chartTopPad = 14.0;

class _AreaPainter extends CustomPainter {
  final List<MetricSeries> series;
  final List<Color> colors;
  final double tMin, tMax, vMax;
  final Color grid;
  final double? hoverX;
  final bool fill;
  final List<ChartGuide> guides;
  final Color guideColor;
  final double band;
  final List<_MarkerCluster> clusters;
  final _MarkerCluster? active;
  final Map<ChartSeverity, Color> severityColors;
  final TextStyle? badge;

  _AreaPainter({
    required this.series,
    required this.colors,
    required this.tMin,
    required this.tMax,
    required this.vMax,
    required this.grid,
    required this.hoverX,
    required this.fill,
    this.guides = const [],
    this.guideColor = Colors.grey,
    this.band = 0,
    this.clusters = const [],
    this.active,
    this.severityColors = const {},
    this.badge,
  });

  @override
  void paint(Canvas canvas, Size fullSize) {
    final size = Size(fullSize.width, fullSize.height - band);
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    // Baseline, plus faint lines at the max (under its label) and midway.
    const top = _chartTopPad;
    final faint = Paint()
      ..color = grid.withValues(alpha: grid.a * 0.5)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), gridPaint);
    canvas.drawLine(Offset(0, top), Offset(size.width, top), faint);
    canvas.drawLine(Offset(0, (top + size.height) / 2), Offset(size.width, (top + size.height) / 2), faint);

    final span = tMax - tMin;
    double x(DateTime t) => span <= 0 ? size.width : (t.millisecondsSinceEpoch - tMin) / span * size.width;
    double y(double v) => size.height - 1 - (v / vMax).clamp(0.0, 1.0) * (size.height - 1 - top);

    for (final g in guides) {
      if (g.points.isEmpty) continue;
      final paint = Paint()
        ..color = guideColor.withValues(alpha: g.faint ? 0.4 : 0.85)
        ..style = PaintingStyle.stroke
        ..strokeWidth = g.faint ? 1 : 1.2;
      final path = Path();
      for (final (j, p) in g.points.indexed) {
        final o = Offset(x(p.$1), y(p.$2));
        j == 0 ? path.moveTo(o.dx, o.dy) : path.lineTo(o.dx, o.dy);
      }
      if (!g.dashed) {
        canvas.drawPath(path, paint);
        continue;
      }
      for (final m in path.computeMetrics()) {
        for (var d = 0.0; d < m.length; d += 7) {
          canvas.drawPath(m.extractPath(d, math.min(d + 4, m.length)), paint);
        }
      }
    }

    for (final (i, s) in series.indexed) {
      if (s.points.isEmpty) continue;
      final c = colors[i % colors.length];
      final line = Path();
      for (final (j, p) in s.points.indexed) {
        final o = Offset(x(p.$1), y(p.$2));
        j == 0 ? line.moveTo(o.dx, o.dy) : line.lineTo(o.dx, o.dy);
      }
      if (fill) {
        final area = Path.from(line)
          ..lineTo(x(s.points.last.$1), size.height)
          ..lineTo(x(s.points.first.$1), size.height)
          ..close();
        canvas.drawPath(
          area,
          Paint()
            ..shader = LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [c.withValues(alpha: 0.28), c.withValues(alpha: 0.03)],
            ).createShader(Offset.zero & size),
        );
      }
      canvas.drawPath(
        line,
        Paint()
          ..color = c
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..strokeJoin = StrokeJoin.round,
      );
    }
    if (hoverX != null) {
      canvas.drawLine(Offset(hoverX!, 0), Offset(hoverX!, size.height), Paint()..color = grid.withValues(alpha: 1)..strokeWidth = 1);
    }
    // Restarts: a faint line through the data (every stacked chart draws
    // its own at the same x, so they read as one).
    for (final c in clusters) {
      if (!c.restart || identical(c, active)) continue;
      canvas.drawLine(Offset(c.x, top), Offset(c.x, size.height), Paint()..color = severityColors[c.severity]!.withValues(alpha: 0.22)..strokeWidth = 1);
    }
    if (active != null) {
      // A faint guide up through the chart at the hovered marker's time.
      canvas.drawLine(Offset(active!.x, 0), Offset(active!.x, size.height), Paint()..color = severityColors[active!.severity]!.withValues(alpha: 0.45)..strokeWidth = 1);
    }
    for (final c in clusters) {
      final on = identical(c, active);
      final paint = Paint()..color = severityColors[c.severity]!.withValues(alpha: on ? 1 : 0.8);
      final top = size.height + 2;
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(c.x - (on ? 1.5 : 1), top, on ? 3 : 2, _markerTick), const Radius.circular(1)), paint);
      if (c.items.length > 1) {
        final tp = TextPainter(text: TextSpan(text: '${c.items.length}', style: badge?.copyWith(color: paint.color)), textDirection: TextDirection.ltr)..layout();
        tp.paint(canvas, Offset(math.min(c.x + 3, fullSize.width - tp.width), top - 1));
      }
    }
  }

  @override
  bool shouldRepaint(_AreaPainter old) =>
      old.series != series || old.guides != guides || old.hoverX != hoverX || old.vMax != vMax || old.colors != colors || old.clusters != clusters || old.active != active || old.band != band;
}


/// The time under the pointer on any chart, shared so every other chart in
/// scope draws its cursor and readout at the same moment (hover CPU, see
/// memory then too). Charts publish while hovered and follow it otherwise;
/// a chart whose range doesn't include the time shows nothing.
///
/// Put a [ChartHoverScope] around everything that should move together
/// (the app shell has one, so all charts on screen are linked).
class ChartHoverSync extends InheritedNotifier<ValueNotifier<DateTime?>> {
  const ChartHoverSync({super.key, required ValueNotifier<DateTime?> super.notifier, required super.child});

  static ValueNotifier<DateTime?>? maybeOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<ChartHoverSync>()?.notifier;
}

/// Owns the shared hover time for the charts below it.
class ChartHoverScope extends StatefulWidget {
  final Widget child;
  const ChartHoverScope({super.key, required this.child});

  @override
  State<ChartHoverScope> createState() => _ChartHoverScopeState();
}

class _ChartHoverScopeState extends State<ChartHoverScope> {
  final _time = ValueNotifier<DateTime?>(null);

  @override
  void dispose() {
    _time.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ChartHoverSync(notifier: _time, child: widget.child);
}

// ---------------------------------------------------------------------------
// Event markers
// ---------------------------------------------------------------------------

enum ChartSeverity { info, warn, error }

/// A point event on a chart's time axis (a pod event, a restart).
class ChartMarker {
  final DateTime time;
  final ChartSeverity severity;
  final String title;

  /// Lines under the title (message, container); shown to two lines each.
  final List<String> details;

  /// How many times the event repeated ("×5" when above 1).
  final int count;

  /// A container restart: also drawn as a faint line through the data,
  /// its tooltip one line ("Restart · exit 0 · 14:32").
  final bool restart;
  const ChartMarker({required this.time, required this.title, this.severity = ChartSeverity.info, this.details = const [], this.count = 1, this.restart = false});
}

/// Tick band under the chart, tick height, merge distance and hit distance (px).
const _markerBand = 10.0;
const _markerTick = 6.0;
const _clusterPx = 5.0;
const _markerHitPx = 6.0;

class _MarkerCluster {
  final double x;
  final List<ChartMarker> items;
  _MarkerCluster(this.x, this.items);

  DateTime get time => items.first.time;
  bool get restart => items.any((m) => m.restart);
  ChartSeverity get severity => items.map((m) => m.severity).reduce((a, b) => a.index >= b.index ? a : b);
}

Map<ChartSeverity, Color> _severityColors(BuildContext context) {
  final theme = Theme.of(context);
  final dark = theme.brightness == Brightness.dark;
  return {
    ChartSeverity.info: dark ? const Color(0xFF9096A0) : const Color(0xFF7A808A),
    ChartSeverity.warn: dark ? const Color(0xFFE0A93B) : const Color(0xFFB7791F),
    ChartSeverity.error: theme.colorScheme.error,
  };
}

class _MarkerTooltip extends StatelessWidget {
  final _MarkerCluster cluster;
  final Map<ChartSeverity, Color> colors;
  const _MarkerTooltip({required this.cluster, required this.colors});

  static const _maxRows = 6;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    String two(int n) => n.toString().padLeft(2, '0');
    String at(DateTime t) {
      final l = t.toLocal();
      return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
    }

    final small = theme.textTheme.labelSmall?.copyWith(fontSize: 10.5);
    final hint = small?.copyWith(color: theme.hintColor);
    Widget dot(ChartSeverity s) => Container(width: 6, height: 6, margin: const EdgeInsets.only(right: 5), decoration: BoxDecoration(color: colors[s], shape: BoxShape.circle));
    final items = cluster.items;
    final rows = <Widget>[];
    if (items.length == 1 && items.single.restart) {
      final m = items.single;
      final hm = at(m.time).substring(0, 5);
      rows.add(Row(mainAxisSize: MainAxisSize.min, children: [
        dot(m.severity),
        Flexible(child: Text('${m.title} · $hm', overflow: TextOverflow.ellipsis, style: small?.copyWith(fontWeight: FontWeight.w600))),
      ]));
      for (final d in m.details) {
        rows.add(Text(d, maxLines: 2, overflow: TextOverflow.ellipsis, style: hint));
      }
    } else if (items.length == 1) {
      final m = items.single;
      rows.add(Row(mainAxisSize: MainAxisSize.min, children: [
        dot(m.severity),
        Flexible(child: Text(m.title, overflow: TextOverflow.ellipsis, style: small?.copyWith(fontWeight: FontWeight.w600))),
        if (m.count > 1) Text('  ×${m.count}', style: hint),
      ]));
      rows.add(Text(at(m.time), style: hint));
      for (final d in m.details) {
        rows.add(Text(d, maxLines: 2, overflow: TextOverflow.ellipsis, style: small));
      }
    } else {
      for (final m in items.take(_maxRows)) {
        rows.add(Row(mainAxisSize: MainAxisSize.min, children: [
          dot(m.severity),
          Text('${at(m.time)}  ', style: hint),
          Flexible(child: Text(m.title + (m.count > 1 ? ' ×${m.count}' : ''), overflow: TextOverflow.ellipsis, style: small)),
        ]));
      }
      if (items.length > _maxRows) rows.add(Text('+${items.length - _maxRows} more', style: hint));
    }
    return IgnorePointer(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 220),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 5),
        decoration: BoxDecoration(
          color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.96),
          borderRadius: BorderRadius.circular(5),
          border: Border.all(color: AppColors.of(context).separator),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: rows),
      ),
    );
  }
}
