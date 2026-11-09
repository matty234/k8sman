/// The Capacity section's history charts: cluster CPU and memory in use over
/// time (Prometheus), with requests and allocatable as reference lines.
/// Shows [fallback] (the plain bars) whenever Prometheus isn't there, the
/// query fails or returns nothing.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../metrics/quantity.dart' show formatPercent;
import '../../metrics/widgets.dart' show percentColor;
import '../../prometheus/metric_history_chart.dart';
import '../../prometheus/prom_api.dart';
import '../../state/poller.dart';
import '../../util/k8s.dart';
import 'overview_api.dart';
import 'overview_cards.dart' show CapacityColumns, capacityFigure, capacityLabel, formatCores, requestedLine;
import 'overview_widgets.dart' show OverviewSection, SkeletonBar;

/// Remembered for the session.
Duration? _rememberedRange;

/// How often a range's data is refetched.
Duration refreshEvery(Duration range) => range <= const Duration(hours: 1)
    ? const Duration(seconds: 60)
    : range <= const Duration(hours: 6)
    ? const Duration(minutes: 2)
    : range <= const Duration(days: 1)
    ? const Duration(minutes: 5)
    : const Duration(minutes: 10);

/// One query per chart: usage, requests and allocatable as three series
/// told apart by a `series` label (requests and allocatable come from
/// kube-state-metrics and are simply absent without it).
String capacityQuery({required bool cpu, required String window}) {
  String tag(String q, String name) => 'label_replace($q, "series", "$name", "", "")';
  final usage = cpu ? 'sum(rate(container_cpu_usage_seconds_total{container!="",container!="POD"}[$window]))' : 'sum(container_memory_working_set_bytes{container!="",container!="POD"})';
  final r = cpu ? 'cpu' : 'memory';
  return [tag(usage, 'usage'), tag('sum(kube_pod_container_resource_requests{resource="$r"})', 'requests'), tag('sum(kube_node_status_allocatable{resource="$r"})', 'allocatable')].join(' or ');
}

class _Lines {
  final List<(DateTime, double)> usage;
  final List<(DateTime, double)>? requests;
  final List<(DateTime, double)>? allocatable;
  const _Lines(this.usage, this.requests, this.allocatable);

  static _Lines? from(QueryData d) {
    List<(DateTime, double)>? pick(String name) {
      for (final s in d.series) {
        if (s.metric['series'] == name && s.points.isNotEmpty) return s.points;
      }
      return null;
    }

    final u = pick('usage');
    return u == null ? null : _Lines(u, pick('requests'), pick('allocatable'));
  }
}

enum _State { checking, loading, ready, unavailable }

class ClusterHistory extends StatefulWidget {
  final ResourceTotals capacity;

  /// What stands in without history (the CPU and memory bars).
  final Widget fallback;

  /// Beside the section title ("across 3 nodes").
  final String note;
  const ClusterHistory({super.key, required this.capacity, required this.fallback, this.note = ''});

  @override
  State<ClusterHistory> createState() => _ClusterHistoryState();
}

class _ClusterHistoryState extends State<ClusterHistory> with PollingState {
  PromApi? _prom;
  _State _state = _State.checking;
  Duration _range = _rememberedRange ?? const Duration(hours: 1);
  _Lines? _cpu, _mem;
  Poll? _poll;
  int _seq = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_prom == null) {
      _prom = PromApi.of(context.read<ApiClient>());
      _start();
    }
  }

  Future<void> _start() async {
    final ok = await _prom!.hasPrometheus();
    if (!mounted) return;
    if (!ok) return setState(() => _state = _State.unavailable);
    if (_rememberedRange == null) {
      final r = await defaultHistoryRange(_prom!);
      if (!mounted) return;
      _range = r;
    }
    setState(() => _state = _State.loading);
    _arm();
    await _fetch();
  }

  void _arm() {
    _poll?.dispose();
    _poll = poll(refreshEvery(_range), () async {
      if (mounted && _state != _State.unavailable) await _fetch();
      return _state != _State.unavailable;
    });
    if (mounted) _poll!.attach(context);
  }

  /// One range query per chart; a response for an older request or range is dropped.
  Future<void> _fetch() async {
    final seq = ++_seq;
    final prom = _prom!;
    final end = DateTime.now();
    final s = stepFor(_range);
    Future<_Lines?> one(bool cpu) async {
      final q = capacityQuery(cpu: cpu, window: s.window);
      return _Lines.from(await prom.queryRange(q, start: end.subtract(_range), end: end, step: s.step));
    }

    try {
      final (cpu, mem) = await (one(true), one(false)).wait;
      if (!mounted || seq != _seq) return;
      setState(() {
        _cpu = cpu;
        _mem = mem;
        _state = cpu == null && mem == null ? _State.unavailable : _State.ready;
      });
    } catch (_) {
      if (!mounted || seq != _seq) return;
      // Keep the last charts through a blip; without any, fall back.
      if (_cpu == null && _mem == null) setState(() => _state = _State.unavailable);
    }
  }

  void _setRange(Duration r) {
    if (r == _range) return;
    _rememberedRange = r;
    setState(() {
      _range = r;
      _state = _State.loading;
      _cpu = _mem = null;
    });
    _arm();
    _fetch();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final note = Text(widget.note);
    Widget section(Widget body, {Widget? picker}) => OverviewSection(
          title: 'Capacity',
          collapsible: false,
          trailing: picker == null ? note : Row(mainAxisSize: MainAxisSize.min, children: [note, const SizedBox(width: 14), picker]),
          child: body,
        );
    // While checking, reserve the charts' space if Prometheus was there
    // last time, so the section doesn't grow once the answer comes back.
    if (_state == _State.unavailable || (_state == _State.checking && _prom?.knownHasPrometheus != true)) return section(widget.fallback);
    final c = widget.capacity;
    final ready = _state == _State.ready;
    final cpu = ready && _cpu != null
        ? _HistoryMeter(
            key: const ValueKey('history-cpu'),
            label: 'CPU',
            unit: MetricUnit.cores,
            lines: _cpu!,
            range: _range,
            requested: c.cpuRequests / 1000,
            allocatable: c.cpuAllocatable / 1000,
            amount: '${formatCores(c.cpuRequests)} / ${formatCores(c.cpuAllocatable)} cores',
            figure: (v) => (formatCores(v * 1000), 'cores in use'),
          )
        : null;
    final mem = ready && _mem != null
        ? _HistoryMeter(
            key: const ValueKey('history-mem'),
            label: 'Memory',
            unit: MetricUnit.bytes,
            lines: _mem!,
            range: _range,
            requested: c.memoryRequests,
            allocatable: c.memoryAllocatable,
            amount: '${formatBytes(c.memoryRequests)} / ${formatBytes(c.memoryAllocatable)}',
            figure: (v) {
              final t = formatBytes(v);
              final i = t.lastIndexOf(' ');
              return i < 0 ? (t, 'in use') : (t.substring(0, i), '${t.substring(i + 1)} in use');
            },
          )
        : null;
    // Every cell (chart, skeleton or empty) is the chart's height, so
    // nothing below moves as data arrives.
    Widget cell(Widget? chart) => SizedBox(height: historyMeterHeight, child: chart ?? (ready ? null : const _ChartSkeleton()));
    return section(
      CapacityColumns(children: [cell(cpu), cell(mem)]),
      picker: DefaultTextStyle.merge(style: TextStyle(color: theme.hintColor), child: RangePicker(value: _range, onChanged: _setRange)),
    );
  }
}

/// The height of one history meter (caption, figures, chart, time axis).
const double historyMeterHeight = 196;

/// Placeholders the size of the two history meters, for while the
/// capacity itself is still loading on a cluster with Prometheus.
class HistoryPlaceholder extends StatelessWidget {
  const HistoryPlaceholder({super.key});

  @override
  Widget build(BuildContext context) => const CapacityColumns(children: [
        SizedBox(height: historyMeterHeight, child: _ChartSkeleton()),
        SizedBox(height: historyMeterHeight, child: _ChartSkeleton()),
      ]);
}

class _ChartSkeleton extends StatelessWidget {
  const _ChartSkeleton();

  @override
  Widget build(BuildContext context) => const Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Align(alignment: Alignment.centerLeft, child: SkeletonBar(width: 50, height: 10)),
        SizedBox(height: 8),
        Align(alignment: Alignment.centerLeft, child: SkeletonBar(width: 130, height: 24)),
        SizedBox(height: 8),
        Align(alignment: Alignment.centerLeft, child: SkeletonBar(width: 190, height: 10)),
        SizedBox(height: 14),
        Expanded(child: SkeletonBar()),
        SizedBox(height: 16),
      ]);
}

/// How far above peak usage the requested line may sit and still be drawn;
/// further up it would flatten usage into the floor, so it becomes a label.
const requestsOnScaleWithin = 3.0;

/// The top of a capacity chart's scale: fitted to usage (with headroom),
/// stretched to take in requests only when they are within
/// [requestsOnScaleWithin] times peak usage.
double capacityScale(double peakUsage, double peakRequests) {
  final onScale = peakUsage <= 0 || peakRequests <= peakUsage * requestsOnScaleWithin;
  final top = onScale ? math.max(peakUsage, peakRequests) : peakUsage;
  return (top > 0 ? top : 1) * 1.15;
}

class _HistoryMeter extends StatelessWidget {
  final String label;
  final MetricUnit unit;
  final _Lines lines;
  final Duration range;
  final double requested;
  final double allocatable;
  final String amount;

  /// The current usage as a big figure and its unit ("1.8", "cores in use").
  final (String, String) Function(double) figure;
  const _HistoryMeter({
    super.key,
    required this.label,
    required this.unit,
    required this.lines,
    required this.range,
    required this.requested,
    required this.allocatable,
    required this.amount,
    required this.figure,
  });

  List<(DateTime, double)> _flat(double v) => [(lines.usage.first.$1, v), (lines.usage.last.$1, v)];

  @override
  Widget build(BuildContext context) {
    final req = allocatable > 0 ? requested / allocatable : null;
    final now = lines.usage.last.$2;
    final use = allocatable > 0 ? now / allocatable : null;
    // Prometheus history when kube-state-metrics has it, else flat at the current value.
    final reqPoints = lines.requests ?? _flat(requested);
    final allocPoints = lines.allocatable ?? _flat(allocatable);
    double peak(List<(DateTime, double)> p) => p.fold<double>(0, (a, b) => math.max(a, b.$2));
    // Scaled to usage: requests far above it (and allocatable above the
    // scale) are labelled at the top right instead of drawn.
    final yMax = capacityScale(peak(lines.usage), peak(reqPoints));
    final guides = [
      ChartGuide(lines.requests == null ? 'requested (now)' : 'requested', reqPoints, dashed: true),
      if (peak(allocPoints) <= yMax) ChartGuide(lines.allocatable == null ? 'allocatable (now)' : 'allocatable', allocPoints, faint: true),
    ];
    final (value, unitText) = figure(now);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        capacityLabel(context, label),
        const SizedBox(height: 2),
        capacityFigure(context, value, unitText, suffix: use == null ? null : '${formatPercent(use)} of allocatable', color: percentColor(context, use)),
        const SizedBox(height: 2),
        requestedLine(context, amount, req),
        const SizedBox(height: 12),
        AreaChart(
          series: [MetricSeries(const {}, lines.usage)],
          guides: guides,
          labelGuides: true,
          unit: unit,
          range: range,
          height: 100,
          seriesName: 'in use',
          yMax: yMax,
        ),
      ],
    );
  }
}

