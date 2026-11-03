/// Pure rollout logic for Deployments (unit-tested).
library;

import '../../api/models.dart';
import '../../util/k8s.dart';
import 'widgets/util.dart';

const revisionAnnotation = 'deployment.kubernetes.io/revision';

class RolloutStatus {
  final String text;
  final Severity severity;
  final String? detail;
  const RolloutStatus(this.text, this.severity, [this.detail]);
  @override
  String toString() => text;
}

/// Mirrors `kubectl rollout status`: paused, controller lag, deadline
/// exceeded, replica failure, then updated/old/available counts.
RolloutStatus deriveRolloutStatus(Json d) {
  final spec = asMap(d['spec']);
  final status = asMap(d['status']);
  final conds = asMapList(status['conditions']);
  Json? cond(String type) => conds.where((c) => c['type'] == type).firstOrNull;

  final generation = asInt(dig(d, ['metadata', 'generation'])) ?? 0;
  final observed = asInt(status['observedGeneration']) ?? 0;
  final desired = asInt(spec['replicas']) ?? 1;
  final updated = asInt(status['updatedReplicas']) ?? 0;
  final replicas = asInt(status['replicas']) ?? 0;
  final available = asInt(status['availableReplicas']) ?? 0;

  if (spec['paused'] == true) {
    return RolloutStatus('Paused', Severity.warn, 'Rollout is paused; template changes will not roll out. $updated of $desired updated.');
  }
  if (generation > observed) {
    return RolloutStatus('Progressing: waiting for controller', Severity.warn, 'Generation $generation not yet observed (observed $observed).');
  }
  final progressing = cond('Progressing');
  if (progressing?['reason'] == 'ProgressDeadlineExceeded') {
    return RolloutStatus('ProgressDeadlineExceeded', Severity.error, progressing?['message'] as String?);
  }
  final failure = cond('ReplicaFailure');
  if (failure?['status'] == 'True') {
    return RolloutStatus('ReplicaFailure: ${failure?['reason'] ?? ''}', Severity.error, failure?['message'] as String?);
  }
  if (updated < desired) {
    return RolloutStatus('Progressing: $updated of $desired updated', Severity.warn);
  }
  if (replicas > updated) {
    final old = replicas - updated;
    return RolloutStatus('Progressing: $old old replica${old == 1 ? '' : 's'} pending termination', Severity.warn);
  }
  if (available < updated) {
    return RolloutStatus('Progressing: $available of $updated updated available', Severity.warn);
  }
  if (desired == 0) return const RolloutStatus('Rollout complete', Severity.ok, 'Scaled to 0 replicas.');
  return const RolloutStatus('Rollout complete', Severity.ok);
}

int revisionOf(Json rs) => int.tryParse('${dig(rs, ['metadata', 'annotations', revisionAnnotation]) ?? ''}') ?? 0;

/// ReplicaSets owned by [deploymentUid], newest revision first.
List<Json> rolloutHistory(List<Json> replicaSets, String deploymentUid) {
  final owned = [
    for (final rs in replicaSets)
      if (isOwnedByAny(rs, {deploymentUid})) rs,
  ];
  owned.sort((a, b) {
    final c = revisionOf(b).compareTo(revisionOf(a));
    if (c != 0) return c;
    return '${dig(b, ['metadata', 'creationTimestamp'])}'.compareTo('${dig(a, ['metadata', 'creationTimestamp'])}');
  });
  return owned;
}

/// container name → image for a pod template holder (RS / Deployment).
Map<String, String> templateImages(Json obj) => {
  for (final c in [
    ...asMapList(dig(obj, ['spec', 'template', 'spec', 'initContainers'])),
    ...asMapList(dig(obj, ['spec', 'template', 'spec', 'containers'])),
  ])
    '${c['name']}': '${c['image']}',
};

/// Human summary of what rolling back from [current] to [target] changes.
String rollbackSummary(Json? current, Json target) {
  final from = current == null ? const <String, String>{} : templateImages(current);
  final to = templateImages(target);
  final lines = <String>[
    for (final e in to.entries)
      if (from[e.key] != e.value) '${e.key}: ${from[e.key] ?? '(absent)'} → ${e.value}',
    for (final k in from.keys)
      if (!to.containsKey(k)) '$k: removed (${from[k]})',
  ];
  final rev = revisionOf(target);
  if (lines.isEmpty) {
    return 'Restores the pod template of revision $rev. Images are unchanged; other template fields (env, resources, …) may differ.';
  }
  return 'Restores the pod template of revision $rev. Image changes:\n${lines.map((l) => '  • $l').join('\n')}';
}

Set<String> initContainerNames(Json obj) => {
  for (final c in asMapList(dig(obj, ['spec', 'template', 'spec', 'initContainers']))) '${c['name']}',
};
