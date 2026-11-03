/// Pure helpers for the cluster panels (node allocation sums, RBAC risk
/// classification, quota quantity parsing). No Flutter imports, so they are
/// unit-testable on their own.
library;

import 'dart:math' as math;

import '../../api/models.dart';
import '../../util/k8s.dart';

// ---------------------------------------------------------------------------
// Node allocation
// ---------------------------------------------------------------------------

/// Effective CPU (millicores) / memory (bytes) requests and limits of a pod.
class PodResources {
  final double cpuRequest;
  final double cpuLimit;
  final double memRequest;
  final double memLimit;
  const PodResources({this.cpuRequest = 0, this.cpuLimit = 0, this.memRequest = 0, this.memLimit = 0});

  PodResources operator +(PodResources o) => PodResources(
        cpuRequest: cpuRequest + o.cpuRequest,
        cpuLimit: cpuLimit + o.cpuLimit,
        memRequest: memRequest + o.memRequest,
        memLimit: memLimit + o.memLimit,
      );

  @override
  String toString() => 'PodResources(cpu ${cpuRequest}m/${cpuLimit}m, mem $memRequest/$memLimit)';
}

double _qty(Json container, String kind, String resource) {
  final v = dig<dynamic>(container, ['resources', kind, resource]);
  if (v == null) return 0;
  return (resource == 'cpu' ? parseCpuMillis(v) : parseBytes(v)) ?? 0;
}

/// Effective value of one resource for a pod, following the scheduler's rule:
/// `max(max over init containers, sum over app containers) + overhead`.
/// Restartable init containers (sidecars, `restartPolicy: Always`) keep
/// running, so they add to the app-container sum and to every later init
/// container's peak.
double effectivePodQuantity(Json pod, String kind, String resource) {
  final spec = asMap(pod['spec']);
  var sidecars = 0.0;
  var initPeak = 0.0;
  for (final ic in asMapList(spec['initContainers'])) {
    final v = _qty(ic, kind, resource);
    if (ic['restartPolicy'] == 'Always') {
      sidecars += v;
      initPeak = math.max(initPeak, sidecars);
    } else {
      initPeak = math.max(initPeak, sidecars + v);
    }
  }
  var app = 0.0;
  for (final c in asMapList(spec['containers'])) {
    app += _qty(c, kind, resource);
  }
  final overheadRaw = dig<dynamic>(spec, ['overhead', resource]);
  final overhead = overheadRaw == null ? 0.0 : ((resource == 'cpu' ? parseCpuMillis(overheadRaw) : parseBytes(overheadRaw)) ?? 0.0);
  return math.max(initPeak, app + sidecars) + overhead;
}

PodResources podResources(Json pod) => PodResources(
      cpuRequest: effectivePodQuantity(pod, 'requests', 'cpu'),
      cpuLimit: effectivePodQuantity(pod, 'limits', 'cpu'),
      memRequest: effectivePodQuantity(pod, 'requests', 'memory'),
      memLimit: effectivePodQuantity(pod, 'limits', 'memory'),
    );

/// Pods in a terminal phase no longer hold node resources.
bool isTerminalPod(Json pod) {
  final phase = dig<String>(pod, ['status', 'phase']);
  return phase == 'Succeeded' || phase == 'Failed';
}

class NodeAllocation {
  final PodResources total;
  final int activePods;
  final int terminatedPods;
  const NodeAllocation({required this.total, required this.activePods, required this.terminatedPods});
}

/// Sums the effective requests/limits of the non-terminal [pods] on a node
/// (what `kubectl describe node` calls "Allocated resources").
NodeAllocation nodeAllocation(List<Json> pods) {
  var total = const PodResources();
  var active = 0, terminated = 0;
  for (final p in pods) {
    if (isTerminalPod(p)) {
      terminated++;
      continue;
    }
    active++;
    total = total + podResources(p);
  }
  return NodeAllocation(total: total, activePods: active, terminatedPods: terminated);
}

/// A kubectl-ish one-word status for a pod (Terminating, the pod's reason,
/// the first container waiting/terminated reason, NotReady, else the phase).
/// Unlike the table's `podStatus` (util/pod.dart) it surfaces Evicted and
/// NotReady, which the node and namespace panels want.
String podKubectlStatus(Json pod) {
  if (dig(pod, ['metadata', 'deletionTimestamp']) != null) return 'Terminating';
  final st = asMap(pod['status']);
  if (st['reason'] is String && (st['reason'] as String).isNotEmpty) return st['reason'];
  for (final key in ['initContainerStatuses', 'containerStatuses']) {
    for (final cs in asMapList(st[key])) {
      final waiting = dig<String>(cs, ['state', 'waiting', 'reason']);
      if (waiting != null && waiting.isNotEmpty) return key == 'initContainerStatuses' ? 'Init:$waiting' : waiting;
      final term = dig<String>(cs, ['state', 'terminated', 'reason']);
      if (term != null && term.isNotEmpty && term != 'Completed' && key == 'containerStatuses') return term;
    }
  }
  final phase = st['phase'] as String? ?? 'Unknown';
  if (phase == 'Running') {
    final css = asMapList(st['containerStatuses']);
    if (css.isNotEmpty && css.any((c) => c['ready'] != true)) return 'NotReady';
  }
  return phase;
}

// ---------------------------------------------------------------------------
// RBAC
// ---------------------------------------------------------------------------

enum VerbRisk { read, write, escalate, other }

const readVerbs = {'get', 'list', 'watch'};
const writeVerbs = {'create', 'update', 'patch', 'delete', 'deletecollection'};
const escalationVerbs = {'*', 'escalate', 'bind', 'impersonate'};

bool _readsSecrets(List<String> resources) => resources.contains('secrets') || resources.contains('*');

/// Risk of granting [verb] on [resources]. Reading secrets (directly or via
/// a `*` resource) counts as escalation, since secrets hold SA tokens.
VerbRisk verbRisk(String verb, {List<String> resources = const []}) {
  if (escalationVerbs.contains(verb)) return VerbRisk.escalate;
  if (readVerbs.contains(verb)) return _readsSecrets(resources) ? VerbRisk.escalate : VerbRisk.read;
  if (writeVerbs.contains(verb)) return VerbRisk.write;
  return VerbRisk.other;
}

List<String> strList(dynamic v) => v is List ? [for (final e in v) '$e'] : const [];

/// Human-readable reasons a single rule is dangerous (empty if benign).
List<String> ruleDangers(Json rule) {
  final verbs = strList(rule['verbs']);
  final resources = strList(rule['resources']);
  final groups = strList(rule['apiGroups']);
  if (resources.isEmpty) return const []; // nonResourceURLs-only rule
  final out = <String>[];
  final allVerbs = verbs.contains('*');
  final allResources = resources.contains('*');
  final coreGroup = groups.contains('') || groups.contains('*');
  if (allVerbs && allResources) {
    out.add(groups.contains('*') ? 'Full wildcard: * on * in all API groups' : 'Wildcard: * on * in ${groups.map(apiGroupLabel).join(', ')}');
  } else if (allVerbs) {
    out.add('All verbs (*) on ${resources.join(', ')}');
  }
  if (coreGroup && _readsSecrets(resources) && (allVerbs || verbs.any(readVerbs.contains))) {
    out.add('Can read Secrets');
  }
  if (coreGroup && (allResources || resources.any((r) => r == 'pods/exec' || r == 'pods/attach' || r == 'pods/*'))) {
    if (allVerbs || verbs.contains('create') || verbs.contains('get')) out.add('Can exec/attach into pods');
  }
  for (final v in ['escalate', 'bind', 'impersonate']) {
    if (verbs.contains(v)) out.add('Grants "$v"');
  }
  return out;
}

/// Distinct dangers across [rules], in first-seen order.
List<String> rulesDangers(List<Json> rules) {
  final seen = <String>{};
  for (final r in rules) {
    seen.addAll(ruleDangers(r));
  }
  return seen.toList();
}

String apiGroupLabel(String g) => g.isEmpty ? 'core' : g;

/// Bindings (RoleBinding or ClusterRoleBinding JSON) whose roleRef points at
/// the role [kind]/[name]. For a Role, only RoleBindings in [namespace] count.
List<Json> bindingsFor(List<Json> bindings, {required String kind, required String name, String? namespace}) => [
      for (final b in bindings)
        if (dig(b, ['roleRef', 'kind']) == kind &&
            dig(b, ['roleRef', 'name']) == name &&
            (kind != 'Role' || dig(b, ['metadata', 'namespace']) == namespace))
          b,
    ];

/// ClusterRoles this one aggregates into, from `rbac.authorization.k8s.io/aggregate-to-<x>: "true"` labels.
List<String> aggregatesInto(Json labels) => [
      for (final e in labels.entries)
        if (e.key.startsWith('rbac.authorization.k8s.io/aggregate-to-') && '${e.value}' == 'true')
          e.key.substring('rbac.authorization.k8s.io/aggregate-to-'.length),
    ];

// ---------------------------------------------------------------------------
// Quantities (quotas / limit ranges)
// ---------------------------------------------------------------------------

enum QtyKind { cpu, bytes, count }

QtyKind qtyKindFor(String resource) {
  final r = resource.toLowerCase();
  if (r == 'cpu' || r.endsWith('.cpu')) return QtyKind.cpu;
  if (r.contains('memory') || r.contains('storage') || r.startsWith('hugepages')) return QtyKind.bytes;
  return QtyKind.count;
}

double? parseQty(String resource, dynamic v) => switch (qtyKindFor(resource)) {
      QtyKind.cpu => parseCpuMillis(v),
      QtyKind.bytes => parseBytes(v),
      QtyKind.count => parseBytes(v), // plain numbers, plus k/M suffixes
    };

String formatQty(String resource, double? v) {
  if (v == null) return '—';
  return switch (qtyKindFor(resource)) {
    QtyKind.cpu => formatCpu(v),
    QtyKind.bytes => formatBytes(v),
    QtyKind.count => v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2),
  };
}
