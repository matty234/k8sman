/// Pure (widget-free) pod helpers: effective status, "why not ready"
/// insights, container pairing, probe sentences and shell quoting.
library;

import '../../api/models.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../../ui/inspector/insight.dart';

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
      if (!ready) return Severity.warn;
      // Running and ready, but restarting: the restart pattern's colour
      // (the same rule as the pod's header).
      return restartKind(this)?.severity ?? Severity.ok;
    }
    return Severity.neutral;
  }

  /// Problem containers start open with their actions showing. Clean-exit
  /// restarts (info) aren't a problem.
  bool get hasProblem => severity == Severity.error || severity == Severity.warn;
}

/// How a container keeps restarting, from its last termination.
enum RestartKind {
  /// Exit code 0 (Completed): the process finishes and is started again.
  cleanExit,
  oomKilled,

  /// A non-zero exit code.
  error,

  /// Waiting in CrashLoopBackOff.
  crashLoop,
}

extension RestartKindInfo on RestartKind {
  Severity get severity => switch (this) {
        RestartKind.cleanExit => Severity.info,
        RestartKind.error => Severity.warn,
        RestartKind.oomKilled || RestartKind.crashLoop => Severity.error,
      };

  /// For the header's detail line: "Ready, but restarting: clean exits".
  String get short => switch (this) {
        RestartKind.cleanExit => 'clean exits',
        RestartKind.error => 'exits with errors',
        RestartKind.oomKilled => 'OOMKilled',
        RestartKind.crashLoop => 'CrashLoopBackOff',
      };
}

/// The container's restart pattern, or null when it hasn't restarted.
RestartKind? restartKind(PodContainer c) {
  if (c.isWaiting && c.waiting['reason'] == 'CrashLoopBackOff') return RestartKind.crashLoop;
  if (c.restarts == 0) return null;
  final lt = c.lastTerminated;
  if (lt['reason'] == 'OOMKilled') return RestartKind.oomKilled;
  if (lt.isEmpty) return RestartKind.error;
  final code = (lt['exitCode'] as num?)?.toInt();
  return code == 0 || lt['reason'] == 'Completed' ? RestartKind.cleanExit : RestartKind.error;
}

/// Kinds whose pods are meant to run until replaced (a ReplicaSet stands
/// for its Deployment): a clean exit there is suspicious.
const _longRunningOwners = {'ReplicaSet', 'Deployment', 'StatefulSet', 'DaemonSet'};

/// Explains a container's restarts: what its exits look like and how often
/// ("Exits cleanly (code 0) about every 44m · 130× in 4d"), coloured by
/// [restartKind]. The rate is the restart count over the pod's age (since
/// [podStart]). [ownerKind] (the pod's controller) adds a hint for clean
/// exits; [named] puts the container's name first (pods with several).
/// Null when the container hasn't restarted.
Insight? restartInsight(PodContainer c, {DateTime? podStart, String? ownerKind, bool named = false, DateTime? now}) {
  final kind = restartKind(c);
  if (kind == null) return null;
  final at = now ?? DateTime.now();
  final lt = c.lastTerminated;
  final code = (lt['exitCode'] as num?)?.toInt();
  final reason = lt['reason'] as String?;
  final oom = reason == 'OOMKilled';
  final n = c.restarts;
  String span(Duration d) => formatAge(at.subtract(d), now: at);

  // How often: "about every 44m · 130× in 4d", or "once, 2h ago".
  final age = podStart == null ? null : at.toUtc().difference(podStart.toUtc());
  final finished = parseTime(lt['finishedAt']);
  final String rate;
  if (n >= 2 && age != null && age > Duration.zero) {
    rate = 'about every ${span(age ~/ n)} · $n× in ${span(age)}';
  } else if (n == 1) {
    rate = finished == null ? 'once' : 'once, ${formatAgo(finished, now: at)}';
  } else {
    rate = n == 0 ? '' : '$n×';
  }

  final String what;
  if (lt.isEmpty) {
    what = 'restarts';
  } else if (oom) {
    what = 'OOMKilled';
  } else if (code == 0 || reason == 'Completed') {
    what = 'exits cleanly (code 0)';
  } else {
    what = 'exits with code ${code ?? '?'} (${reason ?? 'Error'})';
  }
  final phrase = [what, if (rate.isNotEmpty) rate].join(' ');
  final body = kind == RestartKind.crashLoop ? 'CrashLoopBackOff: $phrase' : phrase;
  final text = named ? '${c.name}: $body' : '${body[0].toUpperCase()}${body.substring(1)}';

  final started = parseTime(lt['startedAt']);
  final ran = started != null && finished != null ? 'last ran ${formatAge(at.subtract(finished.difference(started)), now: at)}' : null;
  final hint = code == null || oom ? null : exitCodeHint(code);
  final detail = <String>[
    if (oom) dig(c.spec, ['resources', 'limits', 'memory']) == null ? 'no memory limit: the node ran short of memory' : 'exceeds its memory limit${_memLimit(c)}',
    if (kind == RestartKind.error || kind == RestartKind.crashLoop) ?hint,
    ?ran,
    if (kind == RestartKind.cleanExit && _longRunningOwners.contains(ownerKind))
      'a process that finishes normally may belong in a Job or CronJob, or its main loop is exiting',
    if (lt['message'] != null) 'termination message: ${'${lt['message']}'.trim()}',
    if (kind != RestartKind.cleanExit) 'see the previous instance\'s logs',
  ];
  return Insight(kind.severity, text, detail.isEmpty ? null : detail.join(' · '));
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


/// The pod's only long-running container (one regular container and no
/// sidecars), or null when it has several (or none). Such a pod's
/// inspector shows the container inline rather than as a list.
PodContainer? singleMainContainer(List<PodContainer> cs) {
  final main = [for (final c in cs) if (c.kind == ContainerKind.regular || c.kind == ContainerKind.sidecar) c];
  return main.length == 1 && main.single.kind == ContainerKind.regular ? main.single : null;
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

/// Short description of a terminated state: "Error · exit 3 · 2m ago".
String describeTerminated(Json t, {bool withAge = true}) {
  final code = (t['exitCode'] as num?)?.toInt();
  final parts = <String>[
    if (t['reason'] != null) '${t['reason']}',
    if (code != null) 'exit $code',
    if (t['signal'] != null) 'signal ${t['signal']}',
    if (withAge && formatAgo(parseTime(t['finishedAt'])).isNotEmpty) formatAgo(parseTime(t['finishedAt'])),
  ];
  return parts.join(' · ');
}

/// Each restarting container's [restartInsight], in container order.
List<(PodContainer, Insight)> podRestartInsights(Json pod, {DateTime? now}) {
  final podStart = parseTime(dig(pod, ['status', 'startTime'])) ?? parseTime(dig(pod, ['metadata', 'creationTimestamp']));
  final ownerKind = podControllerKind(pod);
  final all = podContainers(pod);
  // Names only when there are several containers to tell apart (not for
  // the one a single-container pod shows inline).
  final single = singleMainContainer(all)?.name;
  return [
    for (final c in all)
      if (restartInsight(c, podStart: podStart, ownerKind: ownerKind, named: all.length > 1 && c.name != single, now: now) case final i?) (c, i),
  ];
}

/// Builds the "why isn't this ready?" explanation from conditions and
/// container states. Empty list = nothing noteworthy. Without [restarts]
/// the restart insights (see [restartInsight]) are left out.
List<Insight> podInsights(Json pod, {bool restarts = true, DateTime? now}) {
  final out = <Insight>[];
  final all = podContainers(pod);
  final restartsOf = {for (final (c, i) in podRestartInsights(pod, now: now)) c.name: i};
  var explained = false; // by a restart insight, shown or not
  final spec = asMap(pod['spec']);
  final status = asMap(pod['status']);
  final phase = '${status['phase'] ?? ''}';
  final conds = {for (final c in asMapList(status['conditions'])) '${c['type']}': c};

  final del = dig(pod, ['metadata', 'deletionTimestamp']);
  if (del != null) {
    final grace = dig<num>(pod, ['metadata', 'deletionGracePeriodSeconds']);
    final finalizers = dig<List>(pod, ['metadata', 'finalizers']) ?? const [];
    out.add(Insight(Severity.warn, 'Pod is terminating', [
      'deletion requested ${formatAgo(parseTime(del))}',
      if (grace != null) 'grace period ${grace}s',
      if (finalizers.isNotEmpty) 'finalizers: ${finalizers.join(', ')}',
    ].join(' · ')));
  }

  if (phase == 'Failed' || status['reason'] != null) {
    final reason = status['reason'] ?? 'Failed';
    out.add(Insight(Severity.error, 'Pod $reason', status['message'] as String?));
  }

  final sched = conds['PodScheduled'];
  if (sched != null && sched['status'] == 'False') {
    out.add(Insight(Severity.error, 'Not scheduled: ${sched['reason'] ?? 'Unschedulable'}', sched['message'] as String?));
  } else if (spec['nodeName'] == null && phase == 'Pending') {
    out.add(const Insight(Severity.warn, 'Waiting to be scheduled onto a node'));
  }

  for (final c in all) {
    if (!c.hasStatus) continue;
    final who = '${c.kind == ContainerKind.regular ? 'Container' : '${c.kind.label} container'} ${c.name}';
    if (c.isWaiting) {
      final reason = '${c.waiting['reason'] ?? 'Waiting'}';
      final msg = c.waiting['message'] as String?;
      switch (reason) {
        case 'CrashLoopBackOff':
          break; // the restart insight below explains it
        case 'ImagePullBackOff' || 'ErrImagePull' || 'InvalidImageName' || 'ErrImageNeverPull':
          out.add(Insight(Severity.error, '$who can\'t pull image ${c.spec['image'] ?? ''} ($reason)',
              [?msg, 'check the image name/tag, registry reachability and imagePullSecrets'].join(' · ')));
        case 'CreateContainerConfigError':
          out.add(Insight(Severity.error, '$who has a config error', [?msg, 'a referenced ConfigMap/Secret or key is likely missing'].join(' · ')));
        case 'ContainerCreating' || 'PodInitializing':
          out.add(Insight(Severity.warn, '$who is $reason', msg));
        default:
          out.add(Insight(Severity.error, '$who is waiting: $reason', msg));
      }
    } else if (c.isTerminated) {
      final code = (c.terminated['exitCode'] as num?)?.toInt() ?? 0;
      if (code != 0) {
        final hint = exitCodeHint(code);
        out.add(Insight(Severity.error, '$who terminated: ${describeTerminated(c.terminated)}',
            [?hint, if (c.terminated['message'] != null) '${c.terminated['message']}'.trim()].join(' · ').ifEmpty()));
      } else if (c.kind == ContainerKind.sidecar || (c.kind == ContainerKind.regular && phase == 'Running')) {
        out.add(Insight(Severity.warn, '$who exited (${describeTerminated(c.terminated)})'));
      }
    } else if (c.isRunning) {
      if (c.kind == ContainerKind.init) {
        out.add(Insight(Severity.warn, '$who is still running', 'started ${formatAgo(parseTime(c.running['startedAt']))}; regular containers start after it completes'));
      } else if (c.kind != ContainerKind.ephemeral && !c.ready) {
        final started = c.status['started'];
        final startup = asMap(c.spec['startupProbe']);
        final readiness = asMap(c.spec['readinessProbe']);
        if (started == false && startup.isNotEmpty) {
          out.add(Insight(Severity.warn, '$who hasn\'t passed its startup probe yet', probeSentence(startup)));
        } else if (readiness.isNotEmpty) {
          out.add(Insight(Severity.warn, '$who is running but its readiness probe is failing', probeSentence(readiness)));
        } else {
          out.add(Insight(Severity.warn, '$who is running but not ready'));
        }
      }
    }
    // How it restarts (or crash-loops), even when otherwise healthy.
    final r = restartsOf[c.name];
    if (r != null) {
      explained = true;
      if (restarts) out.add(r);
    }
  }

  // Fall back to the Ready condition when containers didn't explain it.
  final ready = conds['Ready'];
  if (out.isEmpty && !explained && ready != null && ready['status'] != 'True' && phase != 'Succeeded') {
    out.add(Insight(Severity.warn, 'Not ready: ${ready['reason'] ?? 'unknown reason'}', ready['message'] as String?));
  }
  final gates = asMapList(spec['readinessGates']);
  for (final g in gates) {
    final t = '${g['conditionType']}';
    if (conds[t]?['status'] != 'True') out.add(Insight(Severity.warn, 'Readiness gate $t is not True', conds[t]?['message'] as String?));
  }
  return out;
}

/// The kind of the pod's controller (else its first owner), e.g. `ReplicaSet`.
String? podControllerKind(Json pod) {
  final owners = asMapList(dig(pod, ['metadata', 'ownerReferences']));
  if (owners.isEmpty) return null;
  return '${owners.firstWhere((o) => o['controller'] == true, orElse: () => owners.first)['kind']}';
}

/// The value an env var's `fieldRef` or `resourceFieldRef` ([valueFrom])
/// resolves to in [pod], for [container] (its spec), or null when it can't
/// be told from the objects (an unset limit defaults to the node's
/// allocatable, for one).
String? resolveEnvSource(Json pod, Json container, Json valueFrom) {
  final field = dig<String>(valueFrom, ['fieldRef', 'fieldPath']);
  if (field != null) {
    final m = RegExp(r'''^metadata\.(labels|annotations)\['(.*)'\]$''').firstMatch(field);
    if (m != null) return dig<Object>(pod, ['metadata', m[1]!, m[2]!])?.toString();
    List<String> ips(String key) => [for (final i in asMapList(dig(pod, ['status', key]))) if (i['ip'] != null) '${i['ip']}'];
    final v = switch (field) {
      'metadata.name' || 'metadata.namespace' || 'metadata.uid' => dig<Object>(pod, field.split('.')),
      'spec.nodeName' || 'status.podIP' || 'status.hostIP' => dig<Object>(pod, field.split('.')),
      'spec.serviceAccountName' => dig<Object>(pod, ['spec', 'serviceAccountName']) ?? dig<Object>(pod, ['spec', 'serviceAccount']),
      'status.podIPs' => ips('podIPs').join(',').ifEmpty(),
      'status.hostIPs' => ips('hostIPs').join(',').ifEmpty(),
      _ => null,
    };
    return v?.toString();
  }
  final r = asMap(valueFrom['resourceFieldRef']);
  final resource = r['resource'] as String?;
  if (resource == null) return null;
  final name = r['containerName'] as String?;
  final spec = name == null || name.isEmpty || name == container['name']
      ? container
      : [for (final k in const ['containers', 'initContainers']) ...asMapList(dig(pod, ['spec', k]))].where((c) => c['name'] == name).firstOrNull;
  if (spec == null) return null;
  final parts = resource.split('.'); // limits.cpu, requests.memory
  if (parts.length != 2) return null;
  final q = dig<Object>(spec, ['resources', parts[0], parts[1]]);
  if (q == null) return null;
  final cpu = parts[1] == 'cpu';
  double? base(Object? x) => cpu ? (parseCpuMillis(x) == null ? null : parseCpuMillis(x)! / 1000) : parseBytes(x);
  final value = base(q);
  final divisor = r['divisor'] == null ? 1.0 : base(r['divisor']);
  if (value == null || divisor == null || divisor <= 0) return null;
  // The kubelet rounds up to a whole number of divisors.
  return '${(value / divisor - 1e-9).ceil()}';
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
