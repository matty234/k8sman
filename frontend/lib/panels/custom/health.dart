import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../ui/inspector/inspector.dart' show Callout;

/// Condition types that are bad when True.
bool isNegativeCondition(String type) =>
    const {'MemoryPressure', 'DiskPressure', 'PIDPressure', 'NetworkUnavailable', 'Failed', 'ReplicaFailure', 'Stalled', 'Degraded', 'NonStructuralSchema', 'Terminating'}
        .contains(type) ||
    type.endsWith('Failed') ||
    type.endsWith('Error') ||
    type.endsWith('Failure');

Severity conditionSeverity(Json c) {
  final status = '${c['status']}';
  if (status == 'Unknown') return Severity.warn;
  final bad = isNegativeCondition('${c['type']}');
  final good = (status == 'True') != bad;
  return good ? Severity.ok : (bad ? Severity.error : Severity.warn);
}

/// Headline condition types, in display order.
const _keyConditions = ['Ready', 'Available', 'Synced', 'Healthy', 'Established', 'Succeeded', 'Complete', 'Reconciled', 'Progressing'];

class _Summary {
  final List<Widget> badges = [];
  final List<Widget> lines = [];
}

/// "At a glance" health for any object: phase/state/ready/health, key
/// conditions, generation drift, deletion/finalizers and the most relevant
/// message. Renders nothing when there's nothing to say ([hasContent]).
class HealthSummary extends StatelessWidget {
  final Json object;
  const HealthSummary(this.object, {super.key});

  static bool hasContent(Json object) {
    final status = asMap(object['status']);
    return status.keys.any((k) => const {'phase', 'state', 'health', 'ready', 'message', 'reason', 'observedGeneration', 'conditions', 'status'}.contains(k)) ||
        dig(object, ['metadata', 'deletionTimestamp']) != null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = _Summary();
    final status = asMap(object['status']);
    final conds = asMapList(status['conditions']);
    final generation = dig<num>(object, ['metadata', 'generation'])?.toInt();

    // Deletion in progress.
    final deleting = dig(object, ['metadata', 'deletionTimestamp']);
    if (deleting != null) {
      s.badges.add(const StatusBadge('Terminating', severity: Severity.warn));
      final fins = (dig<List>(object, ['metadata', 'finalizers']) ?? const []).map((e) => '$e').toList();
      s.lines.add(_line(
        context,
        Icons.hourglass_bottom,
        Severity.warn,
        fins.isEmpty ? 'Deletion requested' : 'Deletion blocked by finalizers: ${fins.join(', ')}',
        trailing: AgeText(deleting, suffix: ' ago'),
      ));
    }

    // Phase-like scalars.
    for (final k in const ['phase', 'state', 'status']) {
      final v = status[k];
      if (v is String && v.isNotEmpty) s.badges.add(_labeled(context, humanizeKey(k), v));
    }
    final health = status['health'];
    if (health is String && health.isNotEmpty) s.badges.add(_labeled(context, 'Health', health));
    if (health is Map && health['status'] is String) s.badges.add(_labeled(context, 'Health', '${health['status']}'));
    final ready = status['ready'];
    if (ready is bool) s.badges.add(StatusBadge(ready ? 'Ready' : 'Not ready', severity: ready ? Severity.ok : Severity.error));
    if (ready is String || ready is num) s.badges.add(_labeled(context, 'Ready', '$ready', severity: _fractionSeverity('$ready')));

    // Headline conditions.
    for (final type in _keyConditions) {
      final c = conds.where((c) => c['type'] == type).firstOrNull;
      if (c == null) continue;
      final st = '${c['status']}';
      s.badges.add(StatusBadge(st == 'True' ? type : '$type: $st', severity: conditionSeverity(c)));
    }
    final negatives = conds.where((c) => isNegativeCondition('${c['type']}') && c['status'] == 'True');
    for (final c in negatives) {
      s.badges.add(StatusBadge('${c['type']}', severity: Severity.error));
    }
    if (conds.length > 1) {
      final ok = conds.where((c) => conditionSeverity(c) == Severity.ok).length;
      s.badges.add(Text('$ok/${conds.length} conditions healthy',
          style: theme.textTheme.bodySmall?.copyWith(color: ok == conds.length ? theme.hintColor : severityColor(context, Severity.warn))));
    }

    // Generation drift.
    final observed = (status['observedGeneration'] as num?)?.toInt();
    if (generation != null && observed != null) {
      if (observed < generation) {
        s.lines.add(_line(context, Icons.sync, Severity.warn,
            "Reconciling: controller hasn't observed generation $generation yet (last observed $observed)"));
      } else {
        s.lines.add(_line(context, Icons.check_circle_outline, Severity.neutral, 'Observed generation $observed (up to date)'));
      }
    }
    if (generation != null) {
      final stale = conds.where((c) => c['observedGeneration'] is num && (c['observedGeneration'] as num) < generation).map((c) => '${c['type']}').toList();
      if (stale.isNotEmpty) {
        s.lines.add(_line(context, Icons.history, Severity.warn, 'Stale conditions (older generation): ${stale.join(', ')}'));
      }
    }

    // Most relevant message: an unhealthy condition's, else status.message.
    final bad = conds.where((c) => conditionSeverity(c) != Severity.ok && '${c['message'] ?? ''}'.isNotEmpty).toList()
      ..sort((a, b) => (conditionSeverity(a) == Severity.error ? 0 : 1).compareTo(conditionSeverity(b) == Severity.error ? 0 : 1));
    for (final c in bad.take(2)) {
      final reason = c['reason'] != null ? ' (${c['reason']})' : '';
      s.lines.add(_line(context, Icons.error_outline, conditionSeverity(c), '${c['type']}=${c['status']}$reason: ${c['message']}'));
    }
    final msg = [status['reason'], status['message']].whereType<String>().where((e) => e.isNotEmpty).join(': ');
    if (msg.isNotEmpty) {
      final sev = _worst([for (final k in const ['phase', 'state', 'status']) if (status[k] is String) severityOf(status[k])]);
      s.lines.add(_line(context, Icons.message_outlined, sev == Severity.ok ? Severity.neutral : sev, msg));
    }
    for (final k in const ['error', 'lastError', 'failureMessage', 'errorMessage']) {
      final v = status[k];
      if (v is String && v.isNotEmpty) s.lines.add(_line(context, Icons.error_outline, Severity.error, v));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (s.badges.isNotEmpty) Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: s.badges),
      if (s.badges.isNotEmpty && s.lines.isNotEmpty) const SizedBox(height: 8),
      ...s.lines,
      if (s.badges.isEmpty && s.lines.isEmpty) InlineMessage('No status reported'),
    ]);
  }

  static String humanizeKey(String k) => '${k[0].toUpperCase()}${k.substring(1)}';

  static Severity _worst(List<Severity> s) {
    if (s.contains(Severity.error)) return Severity.error;
    if (s.contains(Severity.warn)) return Severity.warn;
    return s.isEmpty ? Severity.neutral : s.first;
  }

  static Severity? _fractionSeverity(String v) {
    final m = RegExp(r'^(\d+)/(\d+)$').firstMatch(v);
    if (m == null) return null;
    return m.group(1) == m.group(2) ? Severity.ok : Severity.warn;
  }

  static Widget _labeled(BuildContext context, String label, String value, {Severity? severity}) {
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Text('$label ', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
      StatusBadge(value, severity: severity),
    ]);
  }

  static Widget _line(BuildContext context, IconData icon, Severity sev, String text, {Widget? trailing}) {
    final theme = Theme.of(context);
    if (sev == Severity.error || sev == Severity.warn) {
      return Padding(padding: const EdgeInsets.only(top: 4), child: Callout(severity: sev, icon: icon, title: text, action: trailing));
    }
    final c = sev == Severity.neutral ? theme.hintColor : severityColor(context, sev);
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(icon, size: 14, color: c)),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
        if (trailing != null) ...[const SizedBox(width: 6), trailing],
      ]),
    );
  }
}

/// Monospace-ish helper kept here so panel files stay small.
TextStyle hintMono(BuildContext context, {double size = 11}) => monoStyle(context, size: size, color: Theme.of(context).hintColor);
