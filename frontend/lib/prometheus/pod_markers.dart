/// Chart markers for a pod: its Kubernetes events, plus container lifecycle
/// points read from the pod status (which outlive the events, kept ~1h)
/// and restarts seen in Prometheus (each container instance's start time).
library;

import '../api/models.dart';
import '../panels/pod/pod_logic.dart';
import '../util/k8s.dart';
import 'metric_history_chart.dart';
import 'prom_api.dart';

/// Reasons that mean something went wrong even on a Normal event.
const _errorReasons = {'OOMKilling', 'OOMKilled', 'BackOff', 'Unhealthy', 'Failed', 'FailedMount', 'Evicted', 'ErrImagePull', 'ImagePullBackOff', 'CrashLoopBackOff', 'Error'};

/// Events plus status points, one marker each. A status point is dropped
/// when an event already says the same thing for the same container within
/// [_dupWindow] (a `Started` event and `running.startedAt`, or an event with
/// the terminated reason); otherwise both show.
///
/// [starts] (container → instance start times, from Prometheus) add a
/// restart marker for each start after the pod's own, unless the status
/// already marks that restart (its last termination just before).
List<ChartMarker> podMarkers(Json pod, List<Json> events, {Map<String, List<DateTime>> starts = const {}}) {
  final out = <ChartMarker>[];
  final seen = <(String, String?, DateTime)>[]; // reason, container, time
  final containers = podContainers(pod);
  final named = containers.length > 1;
  for (final e in events) {
    final t = parseTime(e['lastTimestamp']) ??
        parseTime(e['eventTime']) ??
        parseTime(dig(e, ['series', 'lastObservedTime'])) ??
        parseTime(e['firstTimestamp']) ??
        parseTime(dig(e, ['metadata', 'creationTimestamp']));
    if (t == null) continue;
    final reason = (e['reason'] as String?) ?? 'Event';
    final container = RegExp(r'\{(.+)\}').firstMatch(dig<String>(e, ['involvedObject', 'fieldPath']) ?? '')?.group(1);
    final message = (e['message'] as String?)?.trim() ?? '';
    final count = e['count'] is int ? e['count'] as int : 1;
    final warn = e['type'] == 'Warning';
    seen.add((reason, container, t));
    out.add(ChartMarker(
      time: t,
      title: reason,
      severity: _errorReasons.contains(reason) ? ChartSeverity.error : (warn ? ChartSeverity.warn : ChartSeverity.info),
      details: [if (message.isNotEmpty) message, if (container != null) 'container $container'],
      count: count,
    ));
  }

  bool duplicate(String reason, String container, DateTime t) => seen.any((s) => s.$1 == reason && (s.$2 == null || s.$2 == container) && s.$3.difference(t).abs() <= _dupWindow);
  final podStart = parseTime(dig(pod, ['status', 'startTime'])) ?? parseTime(dig(pod, ['metadata', 'creationTimestamp']));

  for (final c in containers) {
    if (c.kind == ContainerKind.ephemeral) continue;
    final name = c.name;
    final kind = restartKind(c);
    final sev = switch (kind?.severity) { Severity.error => ChartSeverity.error, Severity.warn => ChartSeverity.warn, _ => ChartSeverity.info };
    final started = parseTime(c.running['startedAt']);
    if (c.kind != ContainerKind.init && started != null && !duplicate('Started', name, started)) {
      out.add(ChartMarker(time: started, title: 'Started', details: ['container $name']));
    }
    final term = c.lastTerminated;
    final finished = parseTime(term['finishedAt']);
    if (finished != null) {
      final reason = (term['reason'] as String?) ?? 'Terminated';
      final code = term['exitCode'];
      if (!duplicate(reason, name, finished)) {
        out.add(ChartMarker(
          time: finished,
          title: code == null ? 'Restart' : 'Restart · exit $code',
          severity: reason == 'Completed' || code == 0 ? ChartSeverity.info : (reason == 'OOMKilled' ? ChartSeverity.error : sev),
          details: [if (reason != 'Completed' && reason != 'Error') reason, if (named) 'container $name'],
          restart: true,
        ));
      }
    }
    // Earlier restarts, from each instance's start time.
    for (final t in starts[name] ?? const <DateTime>[]) {
      if (podStart != null && t.difference(podStart) < const Duration(minutes: 1)) continue; // the first start
      if (finished != null && !t.isBefore(finished) && t.difference(finished) < const Duration(minutes: 10)) continue; // the status' restart
      if (started != null && t.difference(started).abs() <= _dupWindow) continue; // the current instance: marked above
      out.add(ChartMarker(time: t, title: 'Restart', severity: sev, details: [if (named) 'container $name'], restart: true));
    }
  }
  return out..sort((a, b) => a.time.compareTo(b.time));
}

/// Start times per container from a `max by (container)
/// (container_start_time_seconds)` range query: each distinct value is an
/// instance's start (seconds since the epoch). Starts outside the window
/// [start]–[end] are dropped.
Map<String, List<DateTime>> containerStarts(List<MetricSeries> series, DateTime start, DateTime end) {
  final out = <String, List<DateTime>>{};
  for (final s in series) {
    final name = s.metric['container'];
    if (name == null) continue;
    final seen = <int>{};
    for (final p in s.points) {
      final secs = p.$2.round();
      if (!seen.add(secs)) continue;
      final t = DateTime.fromMillisecondsSinceEpoch(secs * 1000, isUtc: true);
      if (t.isBefore(start) || t.isAfter(end)) continue;
      out.putIfAbsent(name, () => []).add(t);
    }
  }
  return out;
}

const _dupWindow = Duration(seconds: 90);
