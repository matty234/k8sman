/// Small helpers shared by the workloads panels.
library;

import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets/common.dart';
import '../../../util/k8s.dart';
import '../../panel.dart';
import '../../../ui/widgets/atoms.dart';
export '../../../util/json.dart' show asIntOrNull;

/// Natural compare so `web-2` sorts before `web-10`.
int naturalCompare(String a, String b) {
  final re = RegExp(r'(\d+)|(\D+)');
  final pa = re.allMatches(a).map((m) => m.group(0)!).toList();
  final pb = re.allMatches(b).map((m) => m.group(0)!).toList();
  for (var i = 0; i < pa.length && i < pb.length; i++) {
    final na = int.tryParse(pa[i]), nb = int.tryParse(pb[i]);
    final c = (na != null && nb != null) ? na.compareTo(nb) : pa[i].compareTo(pb[i]);
    if (c != 0) return c;
  }
  return pa.length.compareTo(pb.length);
}

/// Trailing ordinal of a StatefulSet pod name (`redis-3` → 3).
int? ordinalOf(String name) {
  final m = RegExp(r'-(\d+)$').firstMatch(name);
  return m == null ? null : int.parse(m.group(1)!);
}

/// True if any of [obj]'s ownerReferences has uid in [uids].
bool isOwnedByAny(Json obj, Set<String> uids) => asMapList(dig(obj, ['metadata', 'ownerReferences'])).any((o) => uids.contains(o['uid']));

/// A ResourceLink that ellipsizes instead of wrapping.
class OneLineLink extends StatelessWidget {
  final ObjectRef ref;
  final String? label;
  const OneLineLink(this.ref, {super.key, this.label});

  @override
  Widget build(BuildContext context) => DefaultTextStyle.merge(
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    softWrap: false,
    child: Tooltip(
      message: '${ref.kind}/${ref.name}',
      child: ResourceLink(ref, label: label ?? ref.name),
    ),
  );
}

/// Human readable toleration: `key=value:NoSchedule`, `Exists (all taints)`.
String formatToleration(Json t) {
  final key = t['key'] as String?;
  final op = (t['operator'] as String?) ?? 'Equal';
  final effect = t['effect'] as String?;
  final secs = t['tolerationSeconds'];
  String s;
  if (key == null || key.isEmpty) {
    s = op == 'Exists' ? 'all taints' : '(any key)';
  } else if (op == 'Exists') {
    s = '$key (exists)';
  } else {
    s = '$key=${t['value'] ?? ''}';
  }
  if (effect != null && effect.isNotEmpty) s += ':$effect';
  if (secs != null) s += ' for ${secs}s';
  return s;
}

/// Chips for a LabelSelector including matchExpressions.
class SelectorChips extends StatelessWidget {
  final dynamic selector;
  const SelectorChips(this.selector, {super.key});

  @override
  Widget build(BuildContext context) {
    final terms = selectorTerms(selector);
    if (terms.isEmpty) return const HintText('everything (empty selector)');
    return Wrap(spacing: 4, runSpacing: 4, children: [for (final t in terms) Chipish(text: t, copyValue: t.contains('=') ? t : null)]);
  }
}

/// Number with a severity colour (e.g. restarts > 0 in amber).
Widget coloredCount(BuildContext context, String text, Severity s, {bool bold = true}) => Text(
  text,
  style: Theme.of(context).textTheme.bodySmall
      ?.copyWith(color: severityColor(context, s), fontWeight: bold ? FontWeight.w600 : null, fontFeatures: const [FontFeature.tabularFigures()]),
);

/// Key that changes when replica state or generation moves, used to refetch
/// related objects without refetching on every watch tick.
String workloadRefreshKey(PanelContext ctx) {
  final s = ctx.status;
  return [
    s['observedGeneration'],
    s['replicas'],
    s['updatedReplicas'],
    s['readyReplicas'],
    s['availableReplicas'],
    s['currentReplicas'],
    s['currentRevision'],
    s['updateRevision'],
    s['desiredNumberScheduled'],
    s['currentNumberScheduled'],
    s['numberReady'],
    s['updatedNumberScheduled'],
    s['currentHealthy'],
    s['expectedPods'],
    ctx.spec['replicas'],
    dig(ctx.object, ['metadata', 'annotations', 'deployment.kubernetes.io/revision']),
  ].join('|');
}
