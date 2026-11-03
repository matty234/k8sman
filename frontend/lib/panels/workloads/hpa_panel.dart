import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../metrics/hpa_live.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
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
  final cur = asInt(dig(hpa, ['status', 'currentReplicas'])) ?? 0;
  final max = asInt(dig(hpa, ['spec', 'maxReplicas'])) ?? 0;
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
    return [
      DetailSection(
        title: 'Scaling',
        icon: Icons.unfold_more_double,
        trailing: StatusBadge(reason == null ? headline : '$headline: $reason', severity: sev, dense: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            KeyValueTable([
              (
                'Target',
                Row(
                  children: [
                    ResourceLink(targetRef, label: '${targetRef.kind}/${targetRef.name}'),
                    if (targetRef.group.isNotEmpty) ...[const SizedBox(width: 6), HintText(target['apiVersion'] as String? ?? '')],
                  ],
                ),
              ),
              if (lastScale != null) ('Last scaled', AgeText(lastScale, suffix: ' ago', style: theme.textTheme.bodySmall)),
            ], keyWidth: 90),
            const SizedBox(height: 8),
            ReplicaRange(
              min: asInt(spec['minReplicas']) ?? 1,
              max: asInt(spec['maxReplicas']) ?? 1,
              current: asInt(st['currentReplicas']) ?? 0,
              desired: asInt(st['desiredReplicas']),
              desiredComputed: scalingActive?['status'] != 'False',
            ),
          ],
        ),
      ),
      DetailSection(
        title: 'Metrics',
        icon: Icons.speed,
        child: metrics.isEmpty
            ? const InlineMessage('No metrics: defaults to 80% average CPU utilization')
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final m in metrics) _MetricRow(m)]),
      ),
      hpaLiveSection(ctx),
      DetailSection(title: 'Conditions', icon: Icons.checklist, child: ConditionsTable(st['conditions'] as List?)),
      DetailSection(title: 'Behavior', icon: Icons.tune, child: _Behavior(asMap(spec['behavior']))),
    ];
  }
}

/// min ── current ── desired ── max on a 0..max track.
class ReplicaRange extends StatelessWidget {
  final int min;
  final int max;
  final int current;
  final int? desired;
  final bool desiredComputed;
  const ReplicaRange({super.key, required this.min, required this.max, required this.current, this.desired, this.desiredComputed = true});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scaleMax = math.max(math.max(max, current), (desired ?? 0)).toDouble() + 1;
    final primary = theme.colorScheme.primary;
    final warn = severityColor(context, Severity.warn);
    final showDesired = desired != null && desiredComputed;
    final atLimit = current >= max || current <= min;
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            _Stat('min', '$min', hint),
            _Stat('current', '$current', small?.copyWith(fontWeight: FontWeight.w700, color: primary)),
            _Stat(
              'desired',
              showDesired ? '$desired' : '—',
              small?.copyWith(fontWeight: FontWeight.w700, color: showDesired ? warn : theme.hintColor),
              tooltip: showDesired ? null : 'Not computed: ScalingActive is False',
            ),
            _Stat('max', '$max', hint),
          ],
        ),
        const SizedBox(height: 6),
        SizedBox(
          height: 30,
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth - 12;
              double x(num v) => 6 + w * (v / scaleMax);
              return Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned(
                    left: 6,
                    right: 6,
                    top: 9,
                    height: 6,
                    child: Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                  ),
                  Positioned(
                    left: x(min),
                    width: math.max(2, x(max) - x(min)),
                    top: 9,
                    height: 6,
                    child: Container(
                      decoration: BoxDecoration(color: primary.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(3)),
                    ),
                  ),
                  for (final (v, l) in [(min, '$min'), (max, '$max')])
                    Positioned(
                      left: x(v) - 10,
                      width: 20,
                      top: 17,
                      child: Text(l, textAlign: TextAlign.center, style: hint?.copyWith(fontSize: 10)),
                    ),
                  if (showDesired && desired != current)
                    Positioned(
                      left: x(desired!) - 6,
                      top: 6,
                      child: Tooltip(
                        message: 'desired $desired',
                        child: Icon(Icons.arrow_drop_down_circle_outlined, size: 12, color: warn),
                      ),
                    ),
                  Positioned(
                    left: x(current) - 6,
                    top: 6,
                    child: Tooltip(
                      message: 'current $current',
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: BoxDecoration(
                          color: atLimit ? warn : primary,
                          shape: BoxShape.circle,
                          border: Border.all(color: theme.colorScheme.surface, width: 2),
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ],
    );
  }
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final TextStyle? style;
  final String? tooltip;
  const _Stat(this.label, this.value, this.style, {this.tooltip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final w = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
        Text(value, style: style?.copyWith(fontSize: 16)),
      ],
    );
    return Expanded(
      child: tooltip == null ? w : Tooltip(message: tooltip!, child: w),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final HpaMetric m;
  const _MetricRow(this.m);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final ratio = m.ratio;
    final over = ratio != null && ratio > 1;
    final barColor = ratio == null ? theme.hintColor : severityColor(context, over ? Severity.warn : Severity.ok);
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
              Text(m.label, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
              if (m.subject != null) ...[
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    m.subject!,
                    style: small?.copyWith(color: theme.hintColor),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              const Spacer(),
              Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: m.currentText,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: m.current == null ? severityColor(context, Severity.warn) : (over ? severityColor(context, Severity.warn) : null),
                      ),
                    ),
                    TextSpan(
                      text: '  /  target ',
                      style: TextStyle(color: theme.hintColor),
                    ),
                    TextSpan(
                      text: m.targetText,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
                style: small,
              ),
            ],
          ),
          const SizedBox(height: 4),
          // Bar: current relative to target (target mark at 2/3 width).
          SizedBox(
            height: 6,
            child: LayoutBuilder(
              builder: (context, c) {
                final w = c.maxWidth;
                final targetX = w * 2 / 3;
                final fill = ratio == null ? 0.0 : (ratio * targetX).clamp(0.0, w);
                return Stack(
                  children: [
                    Container(
                      decoration: BoxDecoration(
                        color: theme.colorScheme.outlineVariant.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    Container(
                      width: fill,
                      decoration: BoxDecoration(color: barColor, borderRadius: BorderRadius.circular(3)),
                    ),
                    Positioned(
                      left: targetX - 1,
                      top: -2,
                      bottom: -2,
                      child: Container(width: 2, color: theme.colorScheme.onSurface.withValues(alpha: 0.7)),
                    ),
                  ],
                );
              },
            ),
          ),
          if (m.current == null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text('no current value reported (metrics unavailable?)', style: small?.copyWith(color: theme.hintColor, fontSize: 11)),
            ),
        ],
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
