import 'dart:async';

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../panels/panel.dart';
import '../panels/workloads/hpa_panel.dart' show hpaMetrics;
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'metrics_api.dart';
import 'widgets.dart';
import '../state/poller.dart';

/// "Live metrics" section for the HPA panel: each metric's current value read
/// from the metrics APIs (next to the HPA's own status.currentMetrics), the
/// replica count it proposes, and which one is driving the decision.
Widget hpaLiveSection(PanelContext ctx) => DetailSection(
  title: 'Live metrics',
  icon: Icons.query_stats,
  child: HpaLiveMetrics(key: ValueKey('hpa-live-${ctx.uid}'), api: ctx.api, namespace: ctx.namespace ?? '', name: ctx.name, hpa: ctx.object),
);

class HpaLiveMetrics extends StatefulWidget {
  final ApiClient api;
  final String namespace;
  final String name;

  /// The live HPA object, for status.currentMetrics.
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
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final a = _a;
    if (a == null) {
      if (_error != null) return InlineMessage('$_error', isError: true);
      return const SizedBox(
        height: 24,
        child: Center(child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5))),
      );
    }
    final status = hpaMetrics(widget.hpa);
    final best = a.metrics.where((m) => m.driving).toList();
    final String verdict;
    if (a.proposed == null) {
      verdict = 'No metric could be evaluated right now.';
    } else if (a.limitedBy == 'min') {
      verdict = 'Every metric asks for ${best.isEmpty ? 'fewer' : '≤ ${best.first.proposed}'} replicas: held at minReplicas ${a.minReplicas}.';
    } else if (a.limitedBy == 'max') {
      verdict = '${_names(best)} asks for ${best.first.proposed} replicas: capped at maxReplicas ${a.maxReplicas}.';
    } else {
      verdict = '${_names(best)} drives the decision: ${a.proposed} replica${a.proposed == 1 ? '' : 's'}.';
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final m in a.metrics)
          _LiveRow(m, statusText: m.index < status.length ? status[m.index].currentText : null, drives: m.driving && a.limitedBy == null),
        const SizedBox(height: 6),
        Text(verdict, style: theme.textTheme.bodySmall),
        Text(
          'Live values from the metrics APIs, computed like the HPA controller (10% tolerance). '
          'The HPA itself reports desired ${a.desiredReplicas ?? '?'} with ${a.currentReplicas} current.',
          style: hint?.copyWith(fontSize: 11),
        ),
        for (final e in a.errors) Padding(padding: const EdgeInsets.only(top: 4), child: InlineMessage(e, isError: true)),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 4), child: MetricsUnavailableNote(_error)),
      ],
    );
  }

  static String _names(List<HpaLiveMetric> ms) => ms.isEmpty ? 'A metric' : ms.map((m) => m.name).join(' and ');
}

class _LiveRow extends StatelessWidget {
  final HpaLiveMetric m;
  final String? statusText;
  final bool drives;
  const _LiveRow(this.m, {this.statusText, required this.drives});

  String _fmt(String? v) => v == null || v.isEmpty ? '—' : (m.targetType == 'Utilization' ? '$v%' : v);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    final subject = m.container != null
        ? 'container ${m.container}'
        : m.object != null
        ? '${m.object!.kind}/${m.object!.name}'
        : (m.selector?.isNotEmpty ?? false)
        ? '{${m.selector}}'
        : null;
    final over = (m.ratio ?? 0) > 1;
    final accent = theme.colorScheme.primary;
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: drives ? accent.withValues(alpha: 0.7) : theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Chipish(text: m.type),
              const SizedBox(width: 6),
              Expanded(
                child: Row(
                  children: [
                    Flexible(
                      child: Text(
                        m.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                      ),
                    ),
                    if (drives) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(color: accent.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(4)),
                        child: Text(
                          'driving',
                          style: theme.textTheme.labelSmall?.copyWith(color: accent, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: m.error != null ? 'unavailable' : _fmt(m.current),
                      style: TextStyle(fontWeight: FontWeight.w700, color: m.error != null || over ? severityColor(context, Severity.warn) : null),
                    ),
                    TextSpan(
                      text: ' / ${m.targetType == 'AverageValue' ? 'avg ' : ''}${_fmt(m.target)}',
                      style: TextStyle(color: theme.hintColor),
                    ),
                  ],
                ),
                style: monoStyle(context, size: 11.5),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            [
              ?subject,
              if (statusText != null) 'HPA status $statusText',
              if (m.pods > 0) 'over ${m.pods} pod${m.pods == 1 ? '' : 's'}',
              if (m.proposed != null) '→ ${m.proposed} replica${m.proposed == 1 ? '' : 's'}',
            ].join('  ·  '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: hint?.copyWith(fontSize: 11),
          ),
          if (m.error != null)
            Text(
              m.error!,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: hint?.copyWith(fontSize: 11, color: severityColor(context, Severity.warn)),
            ),
        ],
      ),
    );
  }
}
