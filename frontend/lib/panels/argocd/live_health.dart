/// Health of live objects, following Argo CD's built-in health checks
/// (gitops-engine `pkg/health`). Argo CD 3 keeps per-resource health in its
/// resource tree rather than in `status.resources`, so the Application panel
/// derives it from the live objects when it isn't persisted.
library;

import '../../api/models.dart';
import '../../util/k8s.dart';
import '../../util/json.dart';

class LiveHealth {
  final String status; // Healthy | Progressing | Degraded | Suspended | Missing | Unknown
  final String? message;
  const LiveHealth(this.status, [this.message]);

  @override
  String toString() => message == null ? status : '$status: $message';
}


Json? _cond(Json obj, String type) {
  for (final c in asMapList(dig(obj, ['status', 'conditions']))) {
    if (c['type'] == type) return c;
  }
  return null;
}

/// Health for [obj] of [group]/[kind], or null when Argo has no health check
/// for the kind (ConfigMaps, RBAC, ...).
LiveHealth? liveHealth(String group, String kind, Json obj) {
  final spec = asMap(obj['spec']);
  final st = asMap(obj['status']);
  final gen = asInt(dig(obj, ['metadata', 'generation']));
  final observed = asInt(st['observedGeneration']);
  switch ('$group/$kind') {
    case 'apps/Deployment':
      if (spec['paused'] == true) return const LiveHealth('Suspended', 'Deployment is paused');
      final progressing = _cond(obj, 'Progressing');
      if (progressing?['reason'] == 'ProgressDeadlineExceeded') {
        return LiveHealth('Degraded', '${progressing?['message'] ?? 'Deployment exceeded its progress deadline'}');
      }
      if (gen > observed) return const LiveHealth('Progressing', 'Waiting for rollout to finish: observed generation is behind');
      final want = spec['replicas'] == null ? 1 : asInt(spec['replicas']);
      final updated = asInt(st['updatedReplicas']);
      final replicas = asInt(st['replicas']);
      final available = asInt(st['availableReplicas']);
      if (updated < want) return LiveHealth('Progressing', 'Waiting for rollout to finish: $updated of $want new replicas updated');
      if (replicas > updated) return LiveHealth('Progressing', 'Waiting for rollout to finish: ${replicas - updated} old replicas pending termination');
      if (available < updated) return LiveHealth('Progressing', 'Waiting for rollout to finish: $available of $updated updated replicas available');
      return const LiveHealth('Healthy');
    case 'apps/StatefulSet':
      if (gen > observed) return const LiveHealth('Progressing', 'Waiting for statefulset spec update to be observed');
      final want = spec['replicas'] == null ? 1 : asInt(spec['replicas']);
      final ready = asInt(st['readyReplicas']);
      if (ready < want) return LiveHealth('Progressing', 'Waiting for $want pods to be ready ($ready ready)');
      final strategy = dig<String>(spec, ['updateStrategy', 'type']) ?? 'RollingUpdate';
      if (strategy == 'RollingUpdate' && st['updateRevision'] != null && st['updateRevision'] != st['currentRevision']) {
        return const LiveHealth('Progressing', 'Waiting for rolling update to complete');
      }
      return const LiveHealth('Healthy');
    case 'apps/DaemonSet':
      if (gen > observed) return const LiveHealth('Progressing', 'Waiting for daemon set spec update to be observed');
      final desired = asInt(st['desiredNumberScheduled']);
      if (asInt(st['updatedNumberScheduled']) < desired) return const LiveHealth('Progressing', 'Waiting for daemon set rollout to finish');
      if (asInt(st['numberAvailable']) < desired) return const LiveHealth('Progressing', 'Waiting for daemon set pods to be available');
      return const LiveHealth('Healthy');
    case 'apps/ReplicaSet':
      final failure = _cond(obj, 'ReplicaFailure');
      if (failure?['status'] == 'True') return LiveHealth('Degraded', '${failure?['message'] ?? 'ReplicaFailure'}');
      final want = spec['replicas'] == null ? 1 : asInt(spec['replicas']);
      final available = asInt(st['availableReplicas']);
      if (available < want) return LiveHealth('Progressing', 'Waiting for rollout to finish: $available of $want replicas available');
      return const LiveHealth('Healthy');
    case '/Pod':
      return _podHealth(obj);
    case '/PersistentVolumeClaim':
      switch (st['phase']) {
        case 'Bound':
          return const LiveHealth('Healthy');
        case 'Lost':
          return const LiveHealth('Degraded', 'Volume is lost');
        default:
          return const LiveHealth('Progressing', 'Waiting for the claim to be bound');
      }
    case '/Service':
      if (spec['type'] == 'LoadBalancer' && asMapList(dig(st, ['loadBalancer', 'ingress'])).isEmpty) {
        return const LiveHealth('Progressing', 'Waiting for a load balancer address');
      }
      return const LiveHealth('Healthy');
    case 'networking.k8s.io/Ingress':
      if (asMapList(dig(st, ['loadBalancer', 'ingress'])).isEmpty) return const LiveHealth('Progressing', 'Waiting for an ingress address');
      return const LiveHealth('Healthy');
    case 'batch/Job':
      if (_cond(obj, 'Failed')?['status'] == 'True') return LiveHealth('Degraded', '${_cond(obj, 'Failed')?['message'] ?? 'Job failed'}');
      if (_cond(obj, 'Complete')?['status'] == 'True') return const LiveHealth('Healthy');
      if (spec['suspend'] == true) return const LiveHealth('Suspended', 'Job is suspended');
      return const LiveHealth('Progressing', 'Job is running');
    case 'batch/CronJob':
      if (spec['suspend'] == true) return const LiveHealth('Suspended', 'CronJob is suspended');
      return const LiveHealth('Healthy');
    case 'autoscaling/HorizontalPodAutoscaler':
      final able = _cond(obj, 'AbleToScale');
      if (able?['status'] == 'False') return LiveHealth('Degraded', '${able?['message'] ?? ''}');
      return const LiveHealth('Healthy');
    case 'argoproj.io/Application':
      final h = dig<String>(st, ['health', 'status']);
      return h == null ? null : LiveHealth(h, dig<String>(st, ['health', 'message']));
    case 'apiextensions.k8s.io/CustomResourceDefinition':
      if (_cond(obj, 'Established')?['status'] == 'True') return const LiveHealth('Healthy');
      return const LiveHealth('Progressing', 'CRD is not established yet');
  }
  return null;
}

LiveHealth _podHealth(Json pod) {
  final st = asMap(pod['status']);
  final statuses = [...asMapList(st['initContainerStatuses']), ...asMapList(st['containerStatuses'])];
  for (final cs in statuses) {
    final waiting = asMap(dig(cs, ['state', 'waiting']));
    final reason = waiting['reason'] as String?;
    if (reason != null && (reason.contains('BackOff') || reason.startsWith('Err') || reason == 'InvalidImageName' || reason == 'CreateContainerConfigError')) {
      return LiveHealth('Degraded', '${waiting['message'] ?? reason}');
    }
  }
  switch (st['phase']) {
    case 'Succeeded':
      return const LiveHealth('Healthy', 'Pod completed');
    case 'Failed':
      return LiveHealth('Degraded', '${st['message'] ?? st['reason'] ?? 'Pod failed'}');
    case 'Running':
      final ready = asMapList(st['conditions']).any((c) => c['type'] == 'Ready' && c['status'] == 'True');
      return ready ? const LiveHealth('Healthy') : const LiveHealth('Progressing', 'Waiting for containers to be ready');
    default:
      return LiveHealth('Progressing', '${st['reason'] ?? 'Pod is ${st['phase'] ?? 'pending'}'}');
  }
}
