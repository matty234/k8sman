/// The capacity strip's history charts: cluster CPU and memory in use over
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
import 'overview_cards.dart' show formatCores;
import 'overview_widgets.dart' show SkeletonBar;

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
  const ClusterHistory({super.key, required this.capacity, required this.fallback});

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
    // While checking, reserve the charts' space if Prometheus was there
    // last time, so the panel doesn't grow once the answer comes back.
    if (_state == _State.unavailable || (_state == _State.checking && _prom?.knownHasPrometheus != true)) return widget.fallback;
    final c = widget.capacity;
    final ready = _state == _State.ready;
    final cpu = ready && _cpu != null
        ? _HistoryMeter(
            key: const ValueKey('history-cpu'),
            trailing: RangePicker(value: _range, onChanged: _setRange),
            label: 'CPU',
            unit: MetricUnit.cores,
            lines: _cpu!,
            range: _range,
            requested: c.cpuRequests / 1000,
            allocatable: c.cpuAllocatable / 1000,
            amount: '${formatCores(c.cpuRequests)} / ${formatCores(c.cpuAllocatable)} cores',
            usedText: (v) => '${formatCores(v * 1000)} cores',
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
            usedText: formatBytes,
          )
        : null;
    // Every cell (chart, skeleton or empty) is the chart's height, so
    // nothing below moves as data arrives.
    Widget cell(Widget? chart) => SizedBox(height: historyMeterHeight, child: chart ?? (ready ? null : const _ChartSkeleton()));
    return LayoutBuilder(
      builder: (context, box) {
        final wide = box.maxWidth >= 620;
        final cells = [cell(cpu), cell(mem)];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            wide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: cells[0]),
                      const SizedBox(width: 28),
                      Expanded(child: cells[1]),
                    ],
                  )
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [cells[0], const SizedBox(height: 12), cells[1]]),
          ],
        );
      },
    );
  }
}

/// The height of one history meter (header, chart, key).
const double historyMeterHeight = 156;

/// Placeholders the size of the two history meters, for while the
/// capacity itself is still loading on a cluster with Prometheus.
class HistoryPlaceholder extends StatelessWidget {
  const HistoryPlaceholder({super.key});

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        const cell = SizedBox(height: historyMeterHeight, child: _ChartSkeleton());
        if (box.maxWidth >= 620) {
          return const Row(crossAxisAlignment: CrossAxisAlignment.start, children: [Expanded(child: cell), SizedBox(width: 28), Expanded(child: cell)]);
        }
        return const Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [cell, SizedBox(height: 12), cell]);
      });
}

class _ChartSkeleton extends StatelessWidget {
  const _ChartSkeleton();

  @override
  Widget build(BuildContext context) => const Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        SkeletonBar(width: 160, height: 12),
        SizedBox(height: 12),
        SkeletonBar(height: 92),
        SizedBox(height: 10),
        SkeletonBar(width: 120, height: 8),
      ]);
}

class _HistoryMeter extends StatelessWidget {
  final String label;
  final MetricUnit unit;
  final _Lines lines;
  final Duration range;
  final double requested;
  final double allocatable;
  final String amount;
  final String Function(double) usedText;

  /// Sits beside the title (the range picker).
  final Widget? trailing;
  const _HistoryMeter({
    super.key,
    this.trailing,
    required this.label,
    required this.unit,
    required this.lines,
    required this.range,
    required this.requested,
    required this.allocatable,
    required this.amount,
    required this.usedText,
  });

  List<(DateTime, double)> _flat(double v) => [(lines.usage.first.$1, v), (lines.usage.last.$1, v)];

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontFeatures: const [FontFeature.tabularFigures()]);
    final req = allocatable > 0 ? requested / allocatable : null;
    final now = lines.usage.last.$2;
    final use = allocatable > 0 ? now / allocatable : null;
    // Prometheus history when kube-state-metrics has it, else flat at the current value.
    final reqPoints = lines.requests ?? _flat(requested);
    final allocPoints = lines.allocatable ?? _flat(allocatable);
    double peak(List<(DateTime, double)> p) => p.fold<double>(0, (a, b) => math.max(a, b.$2));
    // The scale fits usage and requests; allocatable only shows when it is within reach.
    final yMax = math.max(peak(lines.usage), peak(reqPoints)) * 1.25;
    final showAlloc = allocPoints.isNotEmpty && peak(allocPoints) <= yMax;
    final guides = [
      ChartGuide(lines.requests == null ? 'requested (now)' : 'requested', reqPoints, dashed: true),
      if (showAlloc) ChartGuide(lines.allocatable == null ? 'allocatable (now)' : 'allocatable', allocPoints, faint: true),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(label, style: theme.textTheme.titleSmall),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            const SizedBox(width: 10),
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: amount,
                        style: TextStyle(color: theme.colorScheme.onSurface),
                      ),
                      const TextSpan(text: ' requested'),
                      if (req != null) ...[
                        const TextSpan(text: ' · '),
                        TextSpan(
                          text: formatPercent(req),
                          style: TextStyle(color: percentColor(context, req) ?? theme.colorScheme.onSurface, fontWeight: FontWeight.w600),
                        ),
                      ],
                      TextSpan(text: '   ${usedText(now)} in use${use == null ? '' : ' · ${formatPercent(use)}'}'),
                    ],
                  ),
                  textAlign: TextAlign.right,
                  style: hint,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        AreaChart(series: [MetricSeries(const {}, lines.usage)], guides: guides, unit: unit, range: range, height: 92, seriesName: 'in use', yMax: yMax),
        const SizedBox(height: 4),
        Row(
          children: [
            _Key(color: seriesColors(context)[0], text: 'in use'),
            const SizedBox(width: 12),
            _Key(color: theme.hintColor, text: guides[0].name, dashed: true),
            const SizedBox(width: 12),
            if (guides.length > 1) _Key(color: theme.hintColor.withValues(alpha: 0.5), text: guides[1].name),
          ],
        ),
      ],
    );
  }
}

class _Key extends StatelessWidget {
  final Color color;
  final String text;
  final bool dashed;
  const _Key({required this.color, required this.text, this.dashed = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        dashed
            ? Row(
                children: [
                  Container(width: 3, height: 2, color: color),
                  const SizedBox(width: 2),
                  Container(width: 3, height: 2, color: color),
                ],
              )
            : Container(width: 8, height: 2, color: color),
        const SizedBox(width: 4),
        Text(text, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontSize: 10)),
      ],
    );
  }
}
