import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../panels/panel.dart';
import '../panels/workloads/hpa_panel.dart' show hpaMetrics, HpaMetricRow;
import '../ui/widgets/common.dart';
import 'metrics_api.dart';
import '../state/poller.dart';

/// The HPA panel's "Metrics" section: each metric with its current value
/// next to its target. Current values are read live from the metrics APIs
/// (resource, custom and external, as the controller does: one
/// `/api/metrics/hpa` call per 15s), falling back to the HPA's own
/// status.currentMetrics when those can't be read.
Widget hpaMetricsSection(PanelContext ctx) => DetailSection(
  title: 'Metrics',
  icon: Icons.speed,
  child: HpaLiveMetrics(key: ValueKey('hpa-live-${ctx.uid}'), api: ctx.api, namespace: ctx.namespace ?? '', name: ctx.name, hpa: ctx.object),
);

class HpaLiveMetrics extends StatefulWidget {
  final ApiClient api;
  final String namespace;
  final String name;

  /// The live HPA object (spec.metrics and status.currentMetrics).
  final Map<String, dynamic> hpa;
  const HpaLiveMetrics({super.key, required this.api, required this.namespace, required this.name, required this.hpa});

  @override
  State<HpaLiveMetrics> createState() => _HpaLiveMetricsState();
}

class _HpaLiveMetricsState extends State<HpaLiveMetrics> with PollingState {
  HpaAnalysis? _a;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
    poll(const Duration(seconds: 15), () async {
      await _load();
      return _error == null;
    });
  }

  Future<void> _load() async {
    try {
      final a = await widget.api.hpaAnalysis(namespace: widget.namespace, name: widget.name);
      if (mounted) {
        setState(() {
          _a = a;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontSize: 11);
    final a = _a;
    final status = hpaMetrics(widget.hpa);
    HpaLiveMetric? live(int i) => a?.metrics.where((m) => m.index == i).firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final (i, m) in status.indexed) HpaMetricRow(m, live: live(i), drives: (live(i)?.driving ?? false) && a?.limitedBy == null),
        if (a != null) ...[
          const SizedBox(height: 6),
          Text(_verdict(a), style: theme.textTheme.bodySmall),
          for (final e in a.errors) Padding(padding: const EdgeInsets.only(top: 4), child: InlineMessage(e, isError: true)),
        ] else if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Tooltip(message: '$_error', child: Text('Live values unavailable: showing the HPA status', style: hint)),
          ),
      ],
    );
  }

  static String _verdict(HpaAnalysis a) {
    final best = a.metrics.where((m) => m.driving).toList();
    final names = best.isEmpty ? 'A metric' : best.map((m) => m.name).join(' and ');
    if (a.proposed == null) return 'No metric could be evaluated right now.';
    if (a.limitedBy == 'min') {
      return 'Every metric asks for ${best.isEmpty ? 'fewer' : '≤ ${best.first.proposed}'} replicas: held at minReplicas ${a.minReplicas}.';
    }
    if (a.limitedBy == 'max') return '$names asks for ${best.first.proposed} replicas: capped at maxReplicas ${a.maxReplicas}.';
    return '$names drives the decision: ${a.proposed} replica${a.proposed == 1 ? '' : 's'}.';
  }
}
