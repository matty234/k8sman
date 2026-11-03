import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../panels/cluster/logic.dart' show PodResources;
import '../util/k8s.dart';
import 'cache.dart';
import 'metrics_api.dart';
import 'quantity.dart';
import 'widgets.dart';

/// CPU and memory meters for a node: actual usage filled, requests outlined
/// (and limits as ticks when [limits] is set), scaled to allocatable. Without
/// [usage] it falls back to request-only bars, as before metrics existed.
class NodeResourceMeters extends StatelessWidget {
  final Usage? usage;
  final PodResources requests;
  final double cpuAllocatable;
  final double memAllocatable;
  final bool limits;
  final double labelWidth;
  const NodeResourceMeters({
    super.key,
    required this.usage,
    required this.requests,
    required this.cpuAllocatable,
    required this.memAllocatable,
    this.limits = false,
    this.labelWidth = 100,
  });

  @override
  Widget build(BuildContext context) {
    final u = usage;
    final cpuAlloc = cpuAllocatable > 0 ? cpuAllocatable : null;
    final memAlloc = memAllocatable > 0 ? memAllocatable : null;
    if (u == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ResourceMeter(
            label: 'CPU requests',
            used: requests.cpuRequest,
            scale: cpuAlloc,
            percentBase: cpuAlloc,
            percentOf: 'allocatable',
            labelWidth: labelWidth,
            valueText: '${formatCpu(requests.cpuRequest)} / ${formatCpu(cpuAlloc)}',
            format: (v) => formatCpu(v),
          ),
          ResourceMeter(
            label: 'Mem requests',
            used: requests.memRequest,
            scale: memAlloc,
            percentBase: memAlloc,
            percentOf: 'allocatable',
            labelWidth: labelWidth,
            valueText: '${formatBytes(requests.memRequest)} / ${formatBytes(memAlloc)}',
            format: formatBytes,
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ResourceMeter(
          label: 'CPU',
          used: u.cpuMillis,
          requested: requests.cpuRequest,
          limit: limits ? requests.cpuLimit : null,
          scale: cpuAlloc,
          percentBase: cpuAlloc,
          percentOf: 'allocatable',
          labelWidth: labelWidth,
          valueText: '${formatCpuUsage(u.cpuMillis)} / ${formatCpu(cpuAlloc)}',
          format: (v) => formatCpuUsage(v),
        ),
        ResourceMeter(
          label: 'Memory',
          used: u.memoryBytes,
          requested: requests.memRequest,
          limit: limits ? requests.memLimit : null,
          scale: memAlloc,
          percentBase: memAlloc,
          percentOf: 'allocatable',
          labelWidth: labelWidth,
          valueText: '${formatBytes(u.memoryBytes)} / ${formatBytes(memAlloc)}',
          format: formatBytes,
        ),
      ],
    );
  }
}

/// Polls node usage every 15s (shared cache) and hands it to [builder].
class NodeUsagePoller extends StatefulWidget {
  final ApiClient api;
  final Widget Function(BuildContext context, Map<String, NodeUsage>? usage, Object? error) builder;
  const NodeUsagePoller({super.key, required this.api, required this.builder});

  @override
  State<NodeUsagePoller> createState() => _NodeUsagePollerState();
}

class _NodeUsagePollerState extends State<NodeUsagePoller> {
  Map<String, NodeUsage>? _usage;
  Object? _error;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(seconds: 15), (_) => _load());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final items = await MetricsCache.of(widget.api).nodes();
      if (mounted) {
        setState(() {
          _usage = {for (final n in items) n.name: n};
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _usage = null;
          _error = e;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _usage, _error);
}

/// The Node panel's "Usage" section body: live meters vs requests/limits.
class NodeLiveUsage extends StatelessWidget {
  final ApiClient api;
  final String nodeName;
  final Json allocatable;

  /// Effective requests/limits of the node's pods; null while loading.
  final PodResources? requests;
  const NodeLiveUsage({super.key, required this.api, required this.nodeName, required this.allocatable, this.requests});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return NodeUsagePoller(
      api: api,
      builder: (context, usage, error) {
        final u = usage?[nodeName];
        if (u == null) {
          return error != null
              ? MetricsUnavailableNote(error)
              : usage == null
              ? const SizedBox(
                  height: 20,
                  child: Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))),
                )
              : MetricsUnavailableNote(const MetricsUnavailable(MetricsState.notReady, 'no sample for this node yet'));
        }
        final cpu = parseCpuMillis(allocatable['cpu']) ?? 0;
        final mem = parseBytes(allocatable['memory']) ?? 0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NodeResourceMeters(
              usage: u.usage,
              requests: requests ?? const PodResources(),
              cpuAllocatable: cpu,
              memAllocatable: mem,
              limits: true,
              labelWidth: 110,
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                const Expanded(child: MeterLegend(showLimit: true)),
                if (u.timestamp != null)
                  Text('sampled ${formatAge(parseTime(u.timestamp))} ago', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
              ],
            ),
          ],
        );
      },
    );
  }
}
