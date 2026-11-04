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
import 'prom_api.dart';

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
  return MetricHistorySection(
    key: ValueKey('pod-history-${ctx.uid}'),
    api: ctx.api,
    breakdownLabel: 'container',
    charts: [
      MetricChartSpec(
        title: 'CPU',
        unit: MetricUnit.cores,
        query: (w, by) => 'sum${by == null ? '' : ' by ($by)'} (rate(container_cpu_usage_seconds_total{$sel}[$w]))',
      ),
      MetricChartSpec(
        title: 'Memory',
        unit: MetricUnit.bytes,
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
  const MetricChartSpec({required this.title, required this.unit, required this.query, this.seriesLabel});
}

/// Selectable time ranges.
const historyRanges = <(String, Duration)>[
  ('15m', Duration(minutes: 15)),
  ('1h', Duration(hours: 1)),
  ('6h', Duration(hours: 6)),
  ('1d', Duration(days: 1)),
  ('7d', Duration(days: 7)),
];

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
  final Duration initialRange;

  /// An instant query that must return a series, else the section hides
  /// (e.g. Prometheus exists but doesn't have this object's metrics).
  final String? probe;

  /// A hint line under the charts.
  final String? note;

  const MetricHistorySection({
    super.key,
    required this.api,
    required this.charts,
    this.breakdownLabel,
    this.title = 'Metrics history',
    this.initialRange = const Duration(hours: 1),
    this.probe,
    this.note,
  });

  @override
  State<MetricHistorySection> createState() => _MetricHistorySectionState();
}

class _MetricHistorySectionState extends State<MetricHistorySection> {
  late final PromApi _prom = PromApi.of(widget.api);
  late final Future<bool> _available = _check();

  Future<bool> _check() async {
    if (!await _prom.hasPrometheus()) return false;
    final probe = widget.probe;
    if (probe == null) return true;
    try {
      return (await _prom.query(probe)).series.isNotEmpty;
    } catch (_) {
      return false;
    }
  }
  late Duration _range = widget.initialRange;
  bool _breakdown = false;

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
          trailing: _RangePicker(value: _range, onChanged: (r) => setState(() => _range = r)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final spec in widget.charts)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: MetricHistoryChart(
                  key: ValueKey('${spec.title}/${_range.inSeconds}/$_breakdown'),
                  prom: _prom,
                  spec: spec,
                  range: _range,
                  breakdown: _breakdown ? widget.breakdownLabel : null,
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

class _RangePicker extends StatelessWidget {
  final Duration value;
  final ValueChanged<Duration> onChanged;
  const _RangePicker({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      for (final (label, d) in historyRanges)
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
  const MetricHistoryChart({super.key, required this.prom, required this.spec, required this.range, this.breakdown, this.height = 76});

  @override
  State<MetricHistoryChart> createState() => _MetricHistoryChartState();
}

class _MetricHistoryChartState extends State<MetricHistoryChart> {
  late final Future<QueryData> _data;
  late final String _query;

  @override
  void initState() {
    super.initState();
    final end = DateTime.now();
    final s = stepFor(widget.range);
    _query = widget.spec.query(s.window, widget.spec.seriesLabel == null ? widget.breakdown : null);
    _data = widget.prom.queryRange(_query, start: end.subtract(widget.range), end: end, step: s.step);
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
        final nowText = latest == null
            ? null
            : k == null
            ? 'now ${formatMetric(latest, widget.spec.unit)}'
            : 'now ${series.map((s) => '${s.metric[k] ?? ''} ${formatMetric(s.points.last.$2, widget.spec.unit)}').join(' · ')}';
        final header = Row(children: [
          Text(widget.spec.title, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(width: 8),
          const Spacer(),
          if (nowText != null) Flexible(flex: 6, child: Text(nowText, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.right, style: hint)),
        ]);
        Widget body;
        if (snap.hasError) {
          body = _ChartMessage('Query failed: ${snap.error is ApiException ? (snap.error as ApiException).message : snap.error}', height: widget.height);
        } else if (data == null) {
          body = SizedBox(height: widget.height, child: const Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))));
        } else if (series.isEmpty) {
          body = _ChartMessage('No data in this range', height: widget.height);
        } else {
          body = AreaChart(series: series, unit: widget.spec.unit, height: widget.height, labelKey: widget.spec.seriesLabel ?? widget.breakdown, range: widget.range, seriesName: widget.spec.title);
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
  const AreaChart({super.key, required this.series, required this.unit, required this.range, this.height = 76, this.labelKey, this.seriesName = 'value'});

  @override
  State<AreaChart> createState() => _AreaChartState();
}

class _AreaChartState extends State<AreaChart> {
  double? _hoverX;

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
    final tMin = all.map((p) => p.$1.millisecondsSinceEpoch).reduce(math.min).toDouble();
    final tMax = all.map((p) => p.$1.millisecondsSinceEpoch).reduce(math.max).toDouble();
    final vMax = _niceMax(all.map((p) => p.$2).fold<double>(0, math.max));
    final multi = widget.series.length > 1;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      LayoutBuilder(builder: (context, box) {
        final width = box.maxWidth;
        DateTime? hoverT;
        if (_hoverX != null && tMax > tMin) {
          hoverT = DateTime.fromMillisecondsSinceEpoch((tMin + (_hoverX! / width).clamp(0.0, 1.0) * (tMax - tMin)).round());
        }
        final readout = hoverT == null ? null : _readout(hoverT);
        return MouseRegion(
          onHover: (e) => setState(() => _hoverX = e.localPosition.dx),
          onExit: (_) => setState(() => _hoverX = null),
          child: SizedBox(
            height: widget.height,
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
                    hoverX: _hoverX,
                    fill: !multi,
                  ),
                ),
              ),
              Positioned(left: 0, top: -1, child: Text(formatMetric(vMax, widget.unit), style: hint)),
              if (readout != null)
                Positioned(
                  top: 2,
                  left: (_hoverX! + 8 + 150 > width) ? null : _hoverX! + 8,
                  right: (_hoverX! + 8 + 150 > width) ? width - _hoverX! + 8 : null,
                  child: _Tooltip(
                    time: hoverT!,
                    rows: [
                      for (final (i, v) in readout)
                        (colors[i % colors.length], _name(widget.series[i], i), formatMetric(v, widget.unit)),
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

  _AreaPainter({
    required this.series,
    required this.colors,
    required this.tMin,
    required this.tMax,
    required this.vMax,
    required this.grid,
    required this.hoverX,
    required this.fill,
  });

  @override
  void paint(Canvas canvas, Size size) {
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
  }

  @override
  bool shouldRepaint(_AreaPainter old) => old.series != series || old.hoverX != hoverX || old.vMax != vMax || old.colors != colors;
}
