/// GPU sections for the node and pod panels, added with one line each:
/// `gpuNodeSection(ctx)` / `gpuPodSection(ctx)`. Both render nothing for
/// objects without NVIDIA GPU resources.
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../modules/gpus_module.dart';
import '../modules/modules.dart' show moduleEnabled;
import '../panels/cluster/widgets.dart';
import '../panels/panel.dart';
import '../prometheus/metric_history_chart.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'gpu_api.dart';
import 'gpu_widgets.dart';

/// Whether a resource name is an NVIDIA GPU resource (whole GPUs, MIG
/// profiles or shared replicas).
bool isGpuResource(String name) => name == 'nvidia.com/gpu' || name == 'nvidia.com/gpu.shared' || name.startsWith('nvidia.com/mig-');

bool _hasGpuCapacity(Json status) =>
    asMap(status['capacity']).entries.any((e) => isGpuResource(e.key) && '${e.value}' != '0');

/// GPU resources a pod spec asks for (limits, else requests), summed over
/// containers.
Map<String, int> podGpuRequests(Json spec) {
  final out = <String, int>{};
  for (final c in asMapList(spec['containers'])) {
    final res = asMap(c['resources']);
    final l = asMap(res['limits']), r = asMap(res['requests']);
    for (final k in {...l.keys, ...r.keys}) {
      if (!isGpuResource(k)) continue;
      final v = int.tryParse('${l[k] ?? r[k]}') ?? 0;
      if (v > 0) out[k] = (out[k] ?? 0) + v;
    }
  }
  return out;
}


/// History charts for DCGM series matching [selector] (a PromQL label
/// matcher list, e.g. `UUID=~"GPU-a|GPU-b"`).
List<MetricChartSpec> gpuChartSpecs(String selector) {
  String agg(String fn, String by, String expr) => by.isEmpty ? '$fn($expr)' : 'max by ($by) ($expr)';
  return [
    MetricChartSpec(title: 'GPU utilisation', unit: MetricUnit.percent, query: (_, by) => '${agg('avg', by ?? '', 'DCGM_FI_DEV_GPU_UTIL{$selector}')} / 100'),
    MetricChartSpec(title: 'GPU memory used', unit: MetricUnit.bytes, query: (_, by) => '${agg('sum', by ?? '', 'DCGM_FI_DEV_FB_USED{$selector}')} * 1048576'),
    MetricChartSpec(title: 'Temperature (°C)', unit: MetricUnit.plain, query: (_, by) => agg('max', by ?? '', 'DCGM_FI_DEV_GPU_TEMP{$selector}')),
    MetricChartSpec(title: 'Power (W)', unit: MetricUnit.plain, query: (_, by) => agg('sum', by ?? '', 'DCGM_FI_DEV_POWER_USAGE{$selector}')),
  ];
}

Widget gpuHistory(ApiClient api, String key, String selector) => MetricHistorySection(
      key: ValueKey('gpu-history-$key'),
      api: api,
      title: 'GPU history',
      breakdownLabel: 'gpu',
      charts: gpuChartSpecs(selector),
    );

/// The GPUs integration is on (these sections read its /api/gpu).
bool _gpusOn(PanelContext ctx) => moduleEnabled(const GpusModule().id, ctx.app.disabledModules);

/// Node panel: GPU inventory, devices and history.
Widget gpuNodeSection(PanelContext ctx) {
  if (!_hasGpuCapacity(ctx.status) || !_gpusOn(ctx)) return const SizedBox.shrink();
  return _GpuNodeSection(key: ValueKey('gpu-node-${ctx.uid}'), ctx: ctx);
}

/// Pod panel: GPUs held, and per-device stats when DCGM attributes them.
Widget gpuPodSection(PanelContext ctx) {
  final req = podGpuRequests(ctx.spec);
  if (req.isEmpty || !_gpusOn(ctx)) return const SizedBox.shrink();
  return _GpuPodSection(key: ValueKey('gpu-pod-${ctx.uid}'), ctx: ctx, requests: req);
}

class _GpuNodeSection extends StatefulWidget {
  final PanelContext ctx;
  const _GpuNodeSection({super.key, required this.ctx});

  @override
  State<_GpuNodeSection> createState() => _GpuNodeSectionState();
}

class _GpuNodeSectionState extends State<_GpuNodeSection> {
  late final Future<GpuInventory> _inv = GpuApi.of(widget.ctx.api).cached(widget.ctx.app.currentContext);

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<GpuInventory>(
      future: _inv,
      builder: (context, snap) {
        final n = snap.data?.node(widget.ctx.name);
        final theme = Theme.of(context);
        final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
        Widget body;
        if (snap.hasError) {
          body = InlineMessage('GPU inventory unavailable: ${snap.error is ApiException ? (snap.error as ApiException).message : snap.error}', isError: true);
        } else if (snap.data == null) {
          body = const Padding(padding: EdgeInsets.all(8), child: Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))));
        } else if (n == null) {
          body = const InlineMessage('No GPU inventory for this node');
        } else {
          final inv = snap.data!;
          body = Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(gpuNodeLine(n), style: hint),
            const SizedBox(height: 4),
            UsageBar(label: 'Allocated', labelWidth: 84, used: n.allocated.toDouble(), total: n.allocatable.toDouble(), usedText: '${n.allocated}', totalText: '${n.allocatable}'),
            for (final r in n.resources.where((r) => r.name != 'nvidia.com/gpu' && r.capacity > 0))
              UsageBar(
                label: r.name.replaceFirst('nvidia.com/', ''),
                labelWidth: 84,
                used: r.allocated.toDouble(),
                total: r.allocatable.toDouble(),
                usedText: '${r.allocated}',
                totalText: '${r.allocatable}',
              ),
            if (n.capacity > n.allocatable)
              Callout(
                severity: Severity.warn,
                icon: Icons.warning_amber,
                title: '${n.capacity - n.allocatable} of ${n.capacity} GPUs not allocatable',
                child: Text('The NVIDIA device plugin marked them unhealthy.', style: theme.textTheme.bodySmall),
              ),
            if (n.idleAllocated > 0)
              Callout(
                severity: Severity.warn,
                icon: Icons.hourglass_empty,
                title: '${n.idleAllocated} allocated GPU${n.idleAllocated == 1 ? '' : 's'} idle for the last hour',
              ),
            if (!n.monitored && inv.monitoring != GpuMonitoring.skipped)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: InlineMessage(_noStatsReason(inv)),
              ),
            if (n.pods.isNotEmpty) ...[
              const SizedBox(height: 4),
              Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('Held by', style: hint),
                for (final p in n.pods) GpuPodLink(namespace: p.namespace, name: p.name, suffix: '(${p.gpus})'),
              ]),
            ],
            for (final d in n.devices) GpuDeviceTile(d),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DetailSection(
            title: 'GPUs',
            icon: Icons.memory,
            trailing: n == null ? null : _Hint('${n.allocated}/${n.allocatable} allocated'),
            child: body,
          ),
          if (n?.selector != null) gpuHistory(widget.ctx.api, 'node-${widget.ctx.uid}', n!.selector!),
        ]);
      },
    );
  }
}

String _noStatsReason(GpuInventory inv) => switch (inv.monitoring) {
      GpuMonitoring.dcgm => 'No DCGM exporter metrics from this node: live GPU stats unavailable. Is the dcgm-exporter DaemonSet scheduled here?',
      GpuMonitoring.noExporter => 'Prometheus has no DCGM exporter metrics: install NVIDIA dcgm-exporter for live GPU stats.',
      GpuMonitoring.noPrometheus => 'No Prometheus found: live GPU stats need Prometheus and NVIDIA dcgm-exporter.',
      GpuMonitoring.error => 'GPU metrics query failed: ${inv.errors['prometheus'] ?? ''}',
      GpuMonitoring.skipped => '',
    };

class _GpuPodSection extends StatefulWidget {
  final PanelContext ctx;
  final Map<String, int> requests;
  const _GpuPodSection({super.key, required this.ctx, required this.requests});

  @override
  State<_GpuPodSection> createState() => _GpuPodSectionState();
}

class _GpuPodSectionState extends State<_GpuPodSection> {
  late final Future<GpuInventory> _inv = GpuApi.of(widget.ctx.api).cached(widget.ctx.app.currentContext);

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final req = widget.requests;
    final count = req.entries.map((e) => e.key == 'nvidia.com/gpu' ? (e.value == 1 ? '1 GPU' : '${e.value} GPUs') : '${e.value}× ${e.key.replaceFirst('nvidia.com/', '')}').join(', ');
    return FutureBuilder<GpuInventory>(
      future: _inv,
      builder: (context, snap) {
        final inv = snap.data;
        final pod = inv?.pod(ctx.namespace ?? '', ctx.name);
        final node = pod?.node == null ? null : inv?.node(pod!.node!);
        final devices = [
          for (final d in node?.devices ?? const <GpuDevice>[])
            if (d.pods.any((p) => p.namespace == pod!.namespace && p.name == pod.name)) d,
        ];
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DetailSection(
            title: 'GPUs',
            icon: Icons.memory,
            trailing: _Hint(count),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(
                [
                  'Requests $count',
                  if (node != null) 'on ${node.productName}',
                  if (pod?.util != null) 'now ${(pod!.util! * 100).round()}% busy',
                ].join(' · '),
                style: hint,
              ),
              if (pod?.idle == true)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Callout(severity: Severity.warn, icon: Icons.hourglass_empty, title: 'Idle: its GPUs averaged under 1% utilisation over the last hour'),
                ),
              if (pod?.unschedulable != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Callout(severity: Severity.warn, icon: Icons.schedule, title: 'Waiting for GPUs', child: Text(pod!.unschedulable!, style: theme.textTheme.bodySmall)),
                ),
              for (final d in devices) GpuDeviceTile(d, showPods: false),
              if (inv != null && devices.isEmpty && node != null && node.monitored && !inv.attribution)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text('Per-pod GPU stats need dcgm-exporter\'s Kubernetes pod mapping; see the node for device stats.', style: hint),
                ),
            ]),
          ),
          if (pod?.selector != null) gpuHistory(ctx.api, 'pod-${ctx.uid}', pod!.selector!),
        ]);
      },
    );
  }
}

/// Muted text in a section header.
class _Hint extends StatelessWidget {
  final String text;
  const _Hint(this.text);
  @override
  Widget build(BuildContext context) => Text(text, style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).hintColor));
}
