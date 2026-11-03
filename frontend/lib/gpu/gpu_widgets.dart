/// Building blocks shared by the GPUs page and the node/pod panels.
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../metrics/quantity.dart';
import '../metrics/widgets.dart';
import '../prometheus/metric_history_chart.dart' show seriesColors;
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'gpu_api.dart';

/// Temperature (°C) from which a device reads as warm / hot.
const gpuWarmC = 80.0;
const gpuHotC = 85.0;

String formatTemp(double? c) => c == null ? '—' : '${c.round()} °C';
String formatWatts(double? w) => w == null ? '—' : (w < 10 ? '${w.toStringAsFixed(1)} W' : '${w.round()} W');

Severity tempSeverity(double? c) => c == null ? Severity.neutral : (c >= gpuHotC ? Severity.error : (c >= gpuWarmC ? Severity.warn : Severity.neutral));

/// One device: utilisation, memory and tensor meters with temperature,
/// power and the pods using it. [history] (0..1 utilisation points) draws a
/// sparkline beside the title when given.
class GpuDeviceTile extends StatelessWidget {
  final GpuDevice device;
  final List<double>? history;

  /// Show the pods attributed to the device.
  final bool showPods;
  const GpuDeviceTile(this.device, {super.key, this.history, this.showPods = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = device;
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final tempSev = tempSeverity(d.tempC);
    String pct(double? v) => formatPercent(v);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text(d.label, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
          if (d.idle) ...[
            const SizedBox(width: 6),
            const Tooltip(message: 'Allocated, but averaged under 1% utilisation over the last hour', child: StatusBadge('Idle', severity: Severity.warn, dense: true)),
          ],
          for (final h in d.health) ...[
            const SizedBox(width: 6),
            Tooltip(message: h, child: StatusBadge(_shortHealth(h), severity: Severity.error, dense: true)),
          ],
          const SizedBox(width: 8),
          Expanded(
            child: history != null && history!.length > 1
                ? Tooltip(
                    message: 'Utilisation, last hour',
                    child: SizedBox(height: 16, child: Sparkline(history!, color: seriesColors(context).first)),
                  )
                : const SizedBox.shrink(),
          ),
          const SizedBox(width: 8),
          Text(formatTemp(d.tempC), style: theme.textTheme.bodySmall?.copyWith(color: tempSev == Severity.neutral ? null : severityColor(context, tempSev))),
          Text(' · ${formatWatts(d.powerW)}', style: hint),
        ]),
        const SizedBox(height: 2),
        ResourceMeter(
          label: 'Utilisation',
          used: d.util,
          scale: 1,
          percentBase: 1,
          percentOf: 'the GPU',
          valueText: d.avgUtil == null ? '' : '1h avg ${pct(d.avgUtil)}',
          format: pct,
          labelWidth: 84,
          valueWidth: 124,
          compact: true,
        ),
        ResourceMeter(
          label: 'Memory',
          used: d.memUsed,
          scale: d.memTotal,
          percentBase: d.memTotal,
          percentOf: 'framebuffer',
          valueText: d.memUsed == null ? '—' : '${formatBytes(d.memUsed)} / ${formatBytes(d.memTotal)}',
          format: (v) => formatBytes(v),
          labelWidth: 84,
          valueWidth: 124,
          compact: true,
        ),
        if (d.tensorActive != null)
          ResourceMeter(
            label: 'Tensor',
            used: d.tensorActive,
            scale: 1,
            percentBase: null,
            percentOf: 'cycles',
            valueText: pct(d.tensorActive),
            format: pct,
            labelWidth: 84,
            valueWidth: 124,
            compact: true,
          ),
        if (showPods && d.pods.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text('Used by', style: hint),
              for (final p in d.pods) GpuPodLink(namespace: p.namespace, name: p.name),
            ]),
          ),
      ]),
    );
  }

  static String _shortHealth(String h) {
    final l = h.toLowerCase();
    if (l.startsWith('xid')) return h.split(' ').take(2).join(' ');
    if (l.contains('remapping failed')) return 'Remap failed';
    if (l.contains('remapped')) return 'Remapped rows';
    if (l.contains('ecc')) return 'ECC errors';
    if (l.contains('hot')) return 'Hot';
    return 'Unhealthy';
  }
}

/// A link to a pod (opens its detail).
class GpuPodLink extends StatelessWidget {
  final String namespace;
  final String name;
  final String? suffix;
  const GpuPodLink({super.key, required this.namespace, required this.name, this.suffix});

  @override
  Widget build(BuildContext context) => ResourceLink(
        ObjectRef(kind: 'Pod', name: name, namespace: namespace),
        label: '$namespace/$name${suffix == null ? '' : ' $suffix'}',
      );
}

/// A minimal line of 0..1 values (no axes).
class Sparkline extends StatelessWidget {
  final List<double> values;
  final Color color;
  const Sparkline(this.values, {super.key, required this.color});

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.infinite,
        painter: _SparkPainter(values, color, AppColors.of(context).separator),
      );
}

class _SparkPainter extends CustomPainter {
  final List<double> values;
  final Color color;
  final Color baseline;
  _SparkPainter(this.values, this.color, this.baseline);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawLine(Offset(0, size.height - 0.5), Offset(size.width, size.height - 0.5), Paint()..color = baseline);
    if (values.length < 2) return;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = i / (values.length - 1) * size.width;
      final y = size.height - 1 - values[i].clamp(0.0, 1.0) * (size.height - 2);
      i == 0 ? path.moveTo(x, y) : path.lineTo(x, y);
    }
    final area = Path.from(path)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(area, Paint()..color = color.withValues(alpha: 0.15));
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.values != values || old.color != color;
}

/// "Tesla V100 SXM2 32GB · 32 GiB · driver 570.211.01 · CUDA 12.8".
String gpuNodeLine(GpuNode n) => [
      n.productName,
      if (n.memoryMiB > 0) formatBytes(n.memoryMiB * 1024 * 1024),
      if (n.driverVersion != null) 'driver ${n.driverVersion}',
      if (n.cudaVersion != null) 'CUDA ${n.cudaVersion}',
      if (n.migStrategy != null && n.migStrategy != 'none') 'MIG ${n.migStrategy}',
      if (n.sharingStrategy != null && n.sharingStrategy != 'none') '${n.sharingStrategy} ×${math.max(n.replicas, 1)}',
    ].join(' · ');
