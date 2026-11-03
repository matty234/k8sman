/// Pod status helpers shared by the pod, workload, namespace and network
/// panels. No Flutter imports.
library;

import '../api/models.dart';
import 'k8s.dart';

/// The pod table's Status column (backend jq in
/// `backend/internal/columns/builtin.go`, and `overview.PodStatus`):
/// Terminating, then the first failing init container (`Init:<reason>`),
/// then the first container waiting/terminated reason, then the phase.
String podStatus(Json pod) {
  if (dig(pod, ['metadata', 'deletionTimestamp']) != null) return 'Terminating';
  final status = asMap(pod['status']);
  for (final s in asMapList(status['initContainerStatuses'])) {
    final st = asMap(s['state']);
    final waiting = st['waiting'];
    final term = asMap(st['terminated']);
    final code = (term['exitCode'] as num?) ?? 0;
    if (code != 0 || waiting != null) {
      return 'Init:${dig<String>(st, ['waiting', 'reason']) ?? term['reason'] ?? 'Error'}';
    }
  }
  for (final s in asMapList(status['containerStatuses'])) {
    final st = asMap(s['state']);
    final r = dig<String>(st, ['waiting', 'reason']) ?? dig<String>(st, ['terminated', 'reason']);
    if (r != null && r.isNotEmpty) return r;
  }
  return '${status['phase'] ?? 'Unknown'}';
}

/// Total restarts across the pod's (non-init) containers.
int podRestarts(Json pod) => asMapList(dig(pod, ['status', 'containerStatuses'])).fold(0, (a, s) => a + ((s['restartCount'] as num?)?.toInt() ?? 0));

/// Ready containers out of the pod's spec containers.
({int ready, int total}) podReadyCount(Json pod) {
  final total = asMapList(dig(pod, ['spec', 'containers'])).length;
  final ready = asMapList(dig(pod, ['status', 'containerStatuses'])).where((s) => s['ready'] == true).length;
  return (ready: ready, total: total);
}

/// True when a pod's Ready condition is True.
bool podReady(Json pod) => asMapList(dig(pod, ['status', 'conditions'])).any((c) => c['type'] == 'Ready' && c['status'] == 'True');
