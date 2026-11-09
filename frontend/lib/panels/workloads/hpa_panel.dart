import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../metrics/hpa_live.dart';
import '../../metrics/metrics_api.dart' show HpaLiveMetric;
import '../../ui/inspector/inspector.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'widgets/sections.dart';
import 'widgets/status_header.dart';
import 'widgets/util.dart';
import '../../metrics/quantity.dart';

/// One HPA metric: what it measures, its target and current value.
class HpaMetric {
  final String type;
  final String label;
  final String? subject;

  /// Utilization | AverageValue | Value
  final String targetType;
  final dynamic target;
  final dynamic current;
  const HpaMetric({required this.type, required this.label, this.subject, required this.targetType, this.target, this.current});

  bool get isPercent => targetType == 'Utilization';
  String _fmt(dynamic v) => v == null ? '—' : (isPercent ? '$v%' : '$v');
  String get targetText => '${targetType == 'AverageValue' ? 'avg ' : ''}${_fmt(target)}';
  String get currentText => current == null ? 'unknown' : '${targetType == 'AverageValue' ? 'avg ' : ''}${_fmt(current)}';

  /// current / target, or null if either is missing.
  double? get ratio {
    final t = parseQuantity(target), c = parseQuantity(current);
    if (t == null || c == null || t == 0) return null;
    return c / t;
  }
}

/// Pairs spec.metrics with status.currentMetrics. Handles Resource,
/// ContainerResource, Pods, Object, External and the autoscaling/v1 shape.
List<HpaMetric> hpaMetrics(Json hpa) {
  final spec = asMap(hpa['spec']);
  final status = asMap(hpa['status']);
  final current = asMapList(status['currentMetrics']);

  if (spec['targetCPUUtilizationPercentage'] != null && spec['metrics'] == null) {
    return [
      HpaMetric(
        type: 'Resource',
        label: 'cpu',
        targetType: 'Utilization',
        target: spec['targetCPUUtilizationPercentage'],
        current: status['currentCPUUtilizationPercentage'],
      ),
    ];
  }

  String key(Json m) {
    final type = '${m['type']}';
    final body = asMap(m[_field(type)]);
    return [
      type,
      body['name'] ?? dig(body, ['metric', 'name']),
      body['container'],
      dig(body, ['describedObject', 'kind']),
      dig(body, ['describedObject', 'name']),
    ].join('/');
  }

  final out = <HpaMetric>[];
  for (final m in asMapList(spec['metrics'])) {
    final type = '${m['type']}';
    final body = asMap(m[_field(type)]);
    final target = asMap(body['target']);
    final targetType = (target['type'] as String?) ?? 'Value';
    final cur = current.where((c) => key(c) == key(m)).firstOrNull;
    final curBody = asMap(asMap(cur?[_field(type)])['current']);
    dynamic pick(Json t) => switch (targetType) {
      'Utilization' => t['averageUtilization'],
      'AverageValue' => t['averageValue'],
      _ => t['value'],
    };
    final metricName = (body['name'] ?? dig(body, ['metric', 'name']) ?? '?').toString();
    final sel = selectorToString(dig(body, ['metric', 'selector']));
    final (label, subject) = switch (type) {
      'Resource' => (metricName, null),
      'ContainerResource' => (metricName, 'container ${body['container']}'),
      'Pods' => (metricName, 'per pod${sel.isNotEmpty ? ' {$sel}' : ''}'),
      'Object' => (metricName, '${dig(body, ['describedObject', 'kind'])}/${dig(body, ['describedObject', 'name'])}'),
      'External' => (metricName, sel.isNotEmpty ? '{$sel}' : null),
      _ => (type, null),
    };
    out.add(
      HpaMetric(
        type: type,
        label: label,
        subject: subject,
        targetType: targetType,
        target: pick(target),
        current: cur == null ? null : pick(curBody),
      ),
    );
  }
  return out;
}

String _field(String type) => switch (type) {
  'Resource' => 'resource',
  'ContainerResource' => 'containerResource',
  'Pods' => 'pods',
  'Object' => 'object',
  'External' => 'external',
  _ => type.toLowerCase(),
};

/// Headline from the HPA's conditions and replica counts.
(String, Severity, String?) hpaStatus(Json hpa) {
  final conds = asMapList(dig(hpa, ['status', 'conditions']));
  Json? cond(String t) => conds.where((c) => c['type'] == t).firstOrNull;
  final able = cond('AbleToScale');
  final active = cond('ScalingActive');
  final limited = cond('ScalingLimited');
  final cur = asIntOrNull(dig(hpa, ['status', 'currentReplicas'])) ?? 0;
  final max = asIntOrNull(dig(hpa, ['spec', 'maxReplicas'])) ?? 0;
  if (able?['status'] == 'False') return ('Unable to scale', Severity.error, able?['reason'] as String?);
  if (active?['status'] == 'False') {
    final reason = active?['reason'] as String?;
    if (reason == 'ScalingDisabled') return ('Scaling disabled', Severity.neutral, reason);
    return ('Scaling inactive', Severity.error, reason);
  }
  if (limited?['status'] == 'True') return ('Scaling limited', Severity.warn, limited?['reason'] as String?);
  if (max > 0 && cur >= max) return ('At max replicas', Severity.warn, null);
  if (conds.isEmpty) return ('No status yet', Severity.neutral, null);
  return ('Scaling active', Severity.ok, null);
}

class HpaPanel extends ResourcePanel {
  const HpaPanel();

  @override
  bool get ownerInHeader => true;

  @override
  Set<String> get kinds => const {'autoscaling/HorizontalPodAutoscaler'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final st = ctx.status;
    final target = asMap(spec['scaleTargetRef']);
    final targetRef = ObjectRef.fromOwnerRef(target, namespace: ctx.namespace);
    final (headline, sev, reason) = hpaStatus(ctx.object);
    final metrics = hpaMetrics(ctx.object);
    final scalingActive = asMapList(st['conditions']).where((c) => c['type'] == 'ScalingActive').firstOrNull;
    final lastScale = st['lastScaleTime'];
    final theme = Theme.of(context);
    final min = asIntOrNull(spec['minReplicas']) ?? 1;
    final max = asIntOrNull(spec['maxReplicas']) ?? 1;
    final current = asIntOrNull(st['currentReplicas']) ?? 0;
    final desired = asIntOrNull(st['desiredReplicas']);
    final desiredComputed = desired != null && scalingActive?['status'] != 'False';
    final behavior = asMap(spec['behavior']);
    final insights = conditionInsights(asMapList(st['conditions']), errors: sev == Severity.error ? const {'AbleToScale', 'ScalingActive'} : const {});
    return [
      InspectorHeader(
        headline: headline,
        mark: sev,
        // The reason is the insight's title when a condition explains it.
        detail: insights.isEmpty ? reason : null,
        figures: [
          InspectorFigure('$current', 'current', severity: max > 0 && current >= max ? Severity.warn : Severity.neutral, tooltip: 'replicas now'),
          InspectorFigure(
            desiredComputed ? '$desired' : '—',
            'desired',
            severity: desiredComputed && desired != current ? Severity.warn : Severity.neutral,
            tooltip: desiredComputed ? 'replicas the HPA wants' : 'Not computed: ScalingActive is False',
          ),
          InspectorFigure('$min', 'min'),
          InspectorFigure('$max', 'max'),
        ],
        insights: insights,
        facts: [
          ?ownerFact(ctx.object),
          (
            'Target',
            Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
              ResourceLink(targetRef, label: '${targetRef.kind}/${targetRef.name}'),
              if (targetRef.group.isNotEmpty) HintText(target['apiVersion'] as String? ?? ''),
            ]),
          ),
          if (lastScale != null) ('Last scaled', AgeText(lastScale, suffix: ' ago', style: theme.textTheme.bodySmall)),
        ],
      ),
      metrics.isEmpty
          ? const DetailSection(
              title: 'Metrics',
              icon: Icons.speed,
              child: InlineMessage('No metrics: defaults to 80% average CPU utilization'),
            )
          : hpaMetricsSection(ctx),
      workloadSection(
        'behavior',
        'Behavior',
        behavior.isEmpty
            ? 'defaults'
            : [if (behavior['scaleUp'] != null) 'custom scale up', if (behavior['scaleDown'] != null) 'custom scale down'].join(' · '),
        _Behavior(behavior),
      ),
      conditionsSection(context, st),
    ];
  }
}

/// One row of the Metrics section: the metric, its current value next to
/// its target, and a bar of current against target (the tick). [live], when
/// the metrics APIs answered, supplies the current value (read now from the
/// resource, custom or external metrics API, as the controller would) and
/// the replicas it proposes; otherwise the HPA's own status is shown.
class HpaMetricRow extends StatelessWidget {
  final HpaMetric m;
  final HpaLiveMetric? live;

  /// This metric sets the replica count (several can tie).
  final bool drives;
  const HpaMetricRow(this.m, {super.key, this.live, this.drives = false});

  String _fmt(String? v) => v == null || v.isEmpty ? '—' : (m.isPercent ? '$v%' : v);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    final warn = severityColor(context, Severity.warn);
    final l = live;
    final liveValue = l != null && l.error == null && l.current != null && l.current!.isNotEmpty;
    final ratio = liveValue ? l.ratio : m.ratio;
    final over = ratio != null && ratio > 1;
    final avg = m.targetType == 'AverageValue' ? 'avg ' : '';
    final currentText = liveValue ? '$avg${_fmt(l.current)}' : m.currentText;
    final missing = !liveValue && m.current == null;
    final notes = [
      if (liveValue && m.current != null) 'HPA status ${m.currentText}',
      if (l != null && l.pods > 0) 'over ${l.pods} pod${l.pods == 1 ? '' : 's'}',
      if (l?.proposed != null) '→ ${l!.proposed} replica${l.proposed == 1 ? '' : 's'}',
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Chipish(text: m.type),
              const SizedBox(width: 6),
              Expanded(
                child: Row(children: [
                  Flexible(
                    child: Text(
                      m.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (drives) ...[
                    const SizedBox(width: 6),
                    Tooltip(
                      message: 'This metric sets the replica count',
                      child: Text('driving', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
                    ),
                  ],
                  if (m.subject != null) ...[
                    const SizedBox(width: 6),
                    Flexible(child: Text(m.subject!, maxLines: 1, style: hint, overflow: TextOverflow.ellipsis)),
                  ],
                ]),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: liveValue ? 'Live, from the metrics API' : 'From the HPA status',
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: currentText,
                        style: TextStyle(fontWeight: FontWeight.w700, color: missing || over ? warn : null),
                      ),
                      TextSpan(text: '  /  target ', style: TextStyle(color: theme.hintColor)),
                      TextSpan(text: m.targetText, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                  style: small?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _TargetBar(ratio: ratio, color: over ? warn : theme.colorScheme.onSurface.withValues(alpha: 0.42)),
          if (missing)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('no current value reported (metrics unavailable?)', style: hint?.copyWith(fontSize: 11)),
            )
          else if (notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(notes.join('  ·  '), maxLines: 1, overflow: TextOverflow.ellipsis, style: hint?.copyWith(fontSize: 11)),
            ),
          if (l?.error != null)
            Text(l!.error!, maxLines: 2, overflow: TextOverflow.ellipsis, style: hint?.copyWith(fontSize: 11, color: warn)),
        ],
      ),
    );
  }
}

/// Current against target: the fill is the ratio, the tick (at 2/3 of the
/// width) the target, so going over shows past it.
class _TargetBar extends StatelessWidget {
  final double? ratio;
  final Color color;
  const _TargetBar({required this.ratio, required this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      height: 6,
      child: LayoutBuilder(
        builder: (context, c) {
          final w = c.maxWidth;
          final targetX = w * 2 / 3;
          final fill = ratio == null ? 0.0 : (ratio! * targetX).clamp(0.0, w);
          return Stack(
            children: [
              Positioned(
                left: 0,
                right: 0,
                top: 1.5,
                height: 3,
                child: DecoratedBox(
                  decoration: BoxDecoration(color: theme.colorScheme.onSurface.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(3)),
                ),
              ),
              Positioned(
                left: 0,
                width: fill,
                top: 1.5,
                height: 3,
                child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
              ),
              Positioned(
                left: targetX - 1,
                top: 0,
                bottom: 0,
                child: Container(width: 2, color: theme.colorScheme.onSurface.withValues(alpha: 0.55)),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Behavior extends StatelessWidget {
  final Json behavior;
  const _Behavior(this.behavior);

  @override
  Widget build(BuildContext context) {
    final up = behavior['scaleUp'];
    final down = behavior['scaleDown'];
    return KeyValueTable([
      ('Scale up', describeScalingRules(up is Map ? asMap(up) : null, up: true)),
      ('Scale down', describeScalingRules(down is Map ? asMap(down) : null, up: false)),
    ], keyWidth: 90);
  }
}

/// Readable form of an HPAScalingRules; null rules = Kubernetes defaults.
String describeScalingRules(Json? rules, {required bool up}) {
  final isDefault = rules == null;
  final r =
      rules ??
      (up
          ? {
              'stabilizationWindowSeconds': 0,
              'selectPolicy': 'Max',
              'policies': [
                {'type': 'Pods', 'value': 4, 'periodSeconds': 15},
                {'type': 'Percent', 'value': 100, 'periodSeconds': 15},
              ],
            }
          : {
              'stabilizationWindowSeconds': 300,
              'selectPolicy': 'Max',
              'policies': [
                {'type': 'Percent', 'value': 100, 'periodSeconds': 15},
              ],
            });
  final select = (r['selectPolicy'] as String?) ?? 'Max';
  if (select == 'Disabled') return 'disabled';
  final sign = up ? '+' : '−';
  final policies = [
    for (final p in asMapList(r['policies']))
      '$sign${p['value']}${p['type'] == 'Percent' ? '%' : ' pod${p['value'] == 1 ? '' : 's'}'} per ${p['periodSeconds']}s',
  ];
  final stab = r['stabilizationWindowSeconds'] ?? (up ? 0 : 300);
  final pol = policies.isEmpty
      ? 'no policies'
      : policies.length == 1
      ? policies.first
      : '${select == 'Min' ? 'least' : 'most'} of ${policies.join(', ')}';
  return '$pol · stabilization ${stab}s${isDefault ? ' (default)' : ''}';
}
