/// Pure (widget-free) pod helpers: effective status, "why not ready"
/// insights, container pairing, probe sentences and shell quoting.
library;

import '../../api/models.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';

enum ContainerKind { init, sidecar, regular, ephemeral }

extension ContainerKindLabel on ContainerKind {
  String get label => switch (this) {
        ContainerKind.init => 'Init',
        ContainerKind.sidecar => 'Sidecar',
        ContainerKind.regular => 'Container',
        ContainerKind.ephemeral => 'Ephemeral',
      };
}

/// A container spec paired with its status (matched by name).
class PodContainer {
  final ContainerKind kind;
  final Json spec;
  final Json status;
  const PodContainer(this.kind, this.spec, this.status);

  String get name => '${spec['name'] ?? status['name'] ?? ''}';
  bool get hasStatus => status.isNotEmpty;
  int get restarts => (status['restartCount'] as num?)?.toInt() ?? 0;
  bool get ready => status['ready'] == true;
  Json get state => asMap(status['state']);
  Json get lastState => asMap(status['lastState']);
  Json get waiting => asMap(state['waiting']);
  Json get running => asMap(state['running']);
  Json get terminated => asMap(state['terminated']);
  bool get isWaiting => state.containsKey('waiting');
  bool get isRunning => state.containsKey('running');
  bool get isTerminated => state.containsKey('terminated');
  Json get lastTerminated => asMap(lastState['terminated']);

  /// True once the container has produced (or produced before) a process
  /// whose logs can be read.
  bool get everStarted => isRunning || isTerminated || lastTerminated.isNotEmpty;

  /// One-word state for badges: Running / CrashLoopBackOff / Completed / ...
  String get stateLabel {
    if (!hasStatus) return 'No status';
    if (isWaiting) return '${waiting['reason'] ?? 'Waiting'}';
    if (isTerminated) return '${terminated['reason'] ?? (terminated['exitCode'] == 0 ? 'Completed' : 'Error')}';
    if (isRunning) return 'Running';
    return 'Unknown';
  }

  Severity get severity {
    if (!hasStatus) return Severity.neutral;
    if (isWaiting) {
      final r = '${waiting['reason'] ?? ''}';
      return r == 'ContainerCreating' || r == 'PodInitializing' || r.isEmpty ? Severity.warn : Severity.error;
    }
    if (isTerminated) {
      final code = (terminated['exitCode'] as num?)?.toInt() ?? 0;
      if (code != 0) return Severity.error;
      // A regular container or sidecar that exited is not serving.
      return kind == ContainerKind.init ? Severity.ok : Severity.neutral;
    }
    if (isRunning) {
      if (kind == ContainerKind.init) return Severity.warn; // still initialising
      if (kind == ContainerKind.ephemeral) return Severity.ok;
      return ready ? Severity.ok : Severity.warn;
    }
    return Severity.neutral;
  }

  /// Problem containers get a coloured card border.
  bool get hasProblem => severity == Severity.error || severity == Severity.warn || restarts > 0;
}

List<PodContainer> podContainers(Json pod) {
  final spec = asMap(pod['spec']);
  final status = asMap(pod['status']);
  Map<String, Json> byName(dynamic l) => {for (final s in asMapList(l)) '${s['name']}': s};
  final initSt = byName(status['initContainerStatuses']);
  final st = byName(status['containerStatuses']);
  final ephSt = byName(status['ephemeralContainerStatuses']);
  return [
    for (final c in asMapList(spec['initContainers']))
      PodContainer(c['restartPolicy'] == 'Always' ? ContainerKind.sidecar : ContainerKind.init, c, initSt['${c['name']}'] ?? const {}),
    for (final c in asMapList(spec['containers'])) PodContainer(ContainerKind.regular, c, st['${c['name']}'] ?? const {}),
    for (final c in asMapList(spec['ephemeralContainers'])) PodContainer(ContainerKind.ephemeral, c, ephSt['${c['name']}'] ?? const {}),
  ];
}

/// A derived, human explanation line for the status summary.
class PodInsight {
  final Severity severity;
  final String text;
  final String? detail;
  const PodInsight(this.severity, this.text, [this.detail]);
  @override
  String toString() => detail == null ? text : '$text — $detail';
}

String? exitCodeHint(int code) => switch (code) {
      0 => null,
      1 => 'general application error',
      2 => 'misuse of shell builtin / bad arguments',
      126 => 'command found but not executable',
      127 => 'command not found',
      128 => 'invalid exit argument',
      130 => 'SIGINT',
      134 => 'SIGABRT (abort)',
      137 => 'SIGKILL: OOM-killed or killed after failing liveness / grace period',
      139 => 'SIGSEGV (segfault)',
      143 => 'SIGTERM (graceful stop requested)',
      _ => code > 128 && code < 160 ? 'killed by signal ${code - 128}' : null,
    };

String _ago(dynamic ts) {
  final t = parseTime(ts);
  return t == null ? '' : '${formatAge(t)} ago';
}

/// Short description of a terminated state: "Error · exit 3 · 2m ago".
String describeTerminated(Json t, {bool withAge = true}) {
  final code = (t['exitCode'] as num?)?.toInt();
  final parts = <String>[
    if (t['reason'] != null) '${t['reason']}',
    if (code != null) 'exit $code',
    if (t['signal'] != null) 'signal ${t['signal']}',
    if (withAge && _ago(t['finishedAt']).isNotEmpty) _ago(t['finishedAt']),
  ];
  return parts.join(' · ');
}

/// Builds the "why isn't this ready?" explanation from conditions and
/// container states. Empty list = nothing noteworthy.
List<PodInsight> podInsights(Json pod) {
  final out = <PodInsight>[];
  final spec = asMap(pod['spec']);
  final status = asMap(pod['status']);
  final phase = '${status['phase'] ?? ''}';
  final conds = {for (final c in asMapList(status['conditions'])) '${c['type']}': c};

  final del = dig(pod, ['metadata', 'deletionTimestamp']);
  if (del != null) {
    final grace = dig<num>(pod, ['metadata', 'deletionGracePeriodSeconds']);
    final finalizers = dig<List>(pod, ['metadata', 'finalizers']) ?? const [];
    out.add(PodInsight(Severity.warn, 'Pod is terminating', [
      'deletion requested ${_ago(del)}',
      if (grace != null) 'grace period ${grace}s',
      if (finalizers.isNotEmpty) 'finalizers: ${finalizers.join(', ')}',
    ].join(' · ')));
  }

  if (phase == 'Failed' || status['reason'] != null) {
    final reason = status['reason'] ?? 'Failed';
    out.add(PodInsight(Severity.error, 'Pod $reason', status['message'] as String?));
  }

  final sched = conds['PodScheduled'];
  if (sched != null && sched['status'] == 'False') {
    out.add(PodInsight(Severity.error, 'Not scheduled: ${sched['reason'] ?? 'Unschedulable'}', sched['message'] as String?));
  } else if (spec['nodeName'] == null && phase == 'Pending') {
    out.add(const PodInsight(Severity.warn, 'Waiting to be scheduled onto a node'));
  }

  for (final c in podContainers(pod)) {
    if (!c.hasStatus) continue;
    final who = '${c.kind == ContainerKind.regular ? 'Container' : '${c.kind.label} container'} ${c.name}';
    if (c.isWaiting) {
      final reason = '${c.waiting['reason'] ?? 'Waiting'}';
      final msg = c.waiting['message'] as String?;
      switch (reason) {
        case 'CrashLoopBackOff':
          final lt = c.lastTerminated;
          final code = (lt['exitCode'] as num?)?.toInt();
          final hint = code == null ? null : exitCodeHint(code);
          final oom = lt['reason'] == 'OOMKilled';
          out.add(PodInsight(
            Severity.error,
            '$who is in CrashLoopBackOff: restarted ${c.restarts} time${c.restarts == 1 ? '' : 's'}'
            '${lt.isEmpty ? '' : ', last exit code ${code ?? '?'} (${lt['reason'] ?? 'Error'}) ${_ago(lt['finishedAt'])}'}',
            [
              if (oom) 'killed for exceeding its memory limit${_memLimit(c)}',
              if (!oom && hint != null) 'exit $code: $hint',
              if (lt['message'] != null) 'termination message: ${'${lt['message']}'.trim()}',
              'see the previous instance\'s logs',
            ].join(' · '),
          ));
        case 'ImagePullBackOff' || 'ErrImagePull' || 'InvalidImageName' || 'ErrImageNeverPull':
          out.add(PodInsight(Severity.error, '$who can\'t pull image ${c.spec['image'] ?? ''} ($reason)',
              [?msg, 'check the image name/tag, registry reachability and imagePullSecrets'].join(' · ')));
        case 'CreateContainerConfigError':
          out.add(PodInsight(Severity.error, '$who has a config error', [?msg, 'a referenced ConfigMap/Secret or key is likely missing'].join(' · ')));
        case 'ContainerCreating' || 'PodInitializing':
          out.add(PodInsight(Severity.warn, '$who is $reason', msg));
        default:
          out.add(PodInsight(Severity.error, '$who is waiting: $reason', msg));
      }
    } else if (c.isTerminated) {
      final code = (c.terminated['exitCode'] as num?)?.toInt() ?? 0;
      if (code != 0) {
        final hint = exitCodeHint(code);
        out.add(PodInsight(Severity.error, '$who terminated: ${describeTerminated(c.terminated)}',
            [?hint, if (c.terminated['message'] != null) '${c.terminated['message']}'.trim()].join(' · ').ifEmpty()));
      } else if (c.kind == ContainerKind.sidecar || (c.kind == ContainerKind.regular && phase == 'Running')) {
        out.add(PodInsight(Severity.warn, '$who exited (${describeTerminated(c.terminated)})'));
      }
    } else if (c.isRunning) {
      if (c.kind == ContainerKind.init) {
        out.add(PodInsight(Severity.warn, '$who is still running', 'started ${_ago(c.running['startedAt'])}; regular containers start after it completes'));
      } else if (c.kind != ContainerKind.ephemeral && !c.ready) {
        final started = c.status['started'];
        final startup = asMap(c.spec['startupProbe']);
        final readiness = asMap(c.spec['readinessProbe']);
        if (started == false && startup.isNotEmpty) {
          out.add(PodInsight(Severity.warn, '$who hasn\'t passed its startup probe yet', probeSentence(startup)));
        } else if (readiness.isNotEmpty) {
          out.add(PodInsight(Severity.warn, '$who is running but its readiness probe is failing', probeSentence(readiness)));
        } else {
          out.add(PodInsight(Severity.warn, '$who is running but not ready'));
        }
      }
    }
    // Restarts on an otherwise-healthy container are still worth flagging.
    if (c.restarts > 0 && !(c.isWaiting && c.waiting['reason'] == 'CrashLoopBackOff')) {
      final lt = c.lastTerminated;
      out.add(PodInsight(
        lt['reason'] == 'OOMKilled' ? Severity.error : Severity.warn,
        '$who has restarted ${c.restarts} time${c.restarts == 1 ? '' : 's'}',
        lt.isEmpty ? null : 'last termination: ${describeTerminated(lt)}${lt['reason'] == 'OOMKilled' ? ' — memory limit${_memLimit(c)}' : ''}',
      ));
    }
  }

  // Fall back to the Ready condition when containers didn't explain it.
  final ready = conds['Ready'];
  if (out.isEmpty && ready != null && ready['status'] != 'True' && phase != 'Succeeded') {
    out.add(PodInsight(Severity.warn, 'Not ready: ${ready['reason'] ?? 'unknown reason'}', ready['message'] as String?));
  }
  final gates = asMapList(spec['readinessGates']);
  for (final g in gates) {
    final t = '${g['conditionType']}';
    if (conds[t]?['status'] != 'True') out.add(PodInsight(Severity.warn, 'Readiness gate $t is not True', conds[t]?['message'] as String?));
  }
  return out;
}

String _memLimit(PodContainer c) {
  final l = dig(c.spec, ['resources', 'limits', 'memory']);
  return l == null ? '' : ' ($l)';
}

extension on String {
  String? ifEmpty() => isEmpty ? null : this;
}

/// "HTTP GET :http/ every 5s · timeout 1s · fail after 3"
String probeSentence(Json p) {
  final String action;
  if (p['httpGet'] is Map) {
    final h = asMap(p['httpGet']);
    final scheme = '${h['scheme'] ?? 'HTTP'}';
    action = '${scheme == 'HTTPS' ? 'HTTPS' : 'HTTP'} GET ${h['host'] ?? ''}:${h['port'] ?? ''}${h['path'] ?? '/'}';
  } else if (p['tcpSocket'] is Map) {
    final t = asMap(p['tcpSocket']);
    action = 'TCP ${t['host'] ?? ''}:${t['port'] ?? ''}';
  } else if (p['grpc'] is Map) {
    final g = asMap(p['grpc']);
    action = 'gRPC :${g['port'] ?? ''}${g['service'] != null ? ' (${g['service']})' : ''}';
  } else if (p['exec'] is Map) {
    action = 'exec ${shellJoin([for (final c in (dig<List>(p, ['exec', 'command']) ?? const [])) '$c'])}';
  } else {
    action = 'unknown probe';
  }
  final delay = (p['initialDelaySeconds'] as num?) ?? 0;
  final succ = (p['successThreshold'] as num?) ?? 1;
  return [
    '$action every ${p['periodSeconds'] ?? 10}s',
    if (delay > 0) 'delay ${delay}s',
    'timeout ${p['timeoutSeconds'] ?? 1}s',
    'fail after ${p['failureThreshold'] ?? 3}',
    if (succ > 1) 'succeed after $succ',
  ].join(' · ');
}

/// "key=value:NoSchedule op for 300s"
String tolerationText(Json t) {
  final key = t['key'];
  final op = '${t['operator'] ?? 'Equal'}';
  final buf = StringBuffer();
  if (key == null && op == 'Exists') {
    buf.write('* (tolerates everything)');
  } else {
    buf.write(key ?? '*');
    if (op == 'Equal') buf.write('=${t['value'] ?? ''}');
    if (op == 'Exists') buf.write(' exists');
  }
  if (t['effect'] != null) buf.write(' :${t['effect']}');
  if (t['tolerationSeconds'] != null) buf.write(' for ${t['tolerationSeconds']}s');
  return buf.toString();
}

/// Default tolerations the admission controller injects into every pod.
bool isDefaultToleration(Json t) =>
    (t['key'] == 'node.kubernetes.io/not-ready' || t['key'] == 'node.kubernetes.io/unreachable') &&
    t['operator'] == 'Exists' &&
    t['effect'] == 'NoExecute';

/// Node selector term ({matchExpressions, matchFields}) as text.
String nodeSelectorTermText(Json term) {
  String expr(Json e) {
    final vals = (e['values'] as List?)?.join(',') ?? '';
    return switch ('${e['operator']}') {
      'In' => '${e['key']} in ($vals)',
      'NotIn' => '${e['key']} notin ($vals)',
      'Exists' => '${e['key']}',
      'DoesNotExist' => '!${e['key']}',
      'Gt' => '${e['key']} > $vals',
      'Lt' => '${e['key']} < $vals',
      final op => '${e['key']} $op $vals',
    };
  }

  return [
    for (final e in asMapList(term['matchExpressions'])) expr(e),
    for (final e in asMapList(term['matchFields'])) 'field:${expr(e)}',
  ].join(', ');
}
