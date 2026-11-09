/// Chart markers for a pod: its Kubernetes events, plus container lifecycle
/// points read from the pod status (which outlive the events, kept ~1h).
library;

import '../api/models.dart';
import '../util/k8s.dart';
import 'metric_history_chart.dart';

/// Reasons that mean something went wrong even on a Normal event.
const _errorReasons = {'OOMKilling', 'OOMKilled', 'BackOff', 'Unhealthy', 'Failed', 'FailedMount', 'Evicted', 'ErrImagePull', 'ImagePullBackOff', 'CrashLoopBackOff', 'Error'};

/// Events plus status points, one marker each. A status point is dropped
/// when an event already says the same thing for the same container within
/// [_dupWindow] (a `Started` event and `running.startedAt`, or an event with
/// the terminated reason); otherwise both show.
List<ChartMarker> podMarkers(Json pod, List<Json> events) {
  final out = <ChartMarker>[];
  final seen = <(String, String?, DateTime)>[]; // reason, container, time
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

  for (final cs in asMapList(dig(pod, ['status', 'containerStatuses']))) {
    final name = (cs['name'] as String?) ?? '';
    final started = parseTime(dig(cs, ['state', 'running', 'startedAt']));
    if (started != null && !duplicate('Started', name, started)) {
      out.add(ChartMarker(time: started, title: 'Started', details: ['container $name']));
    }
    final term = asMap(dig(cs, ['lastState', 'terminated']));
    final finished = parseTime(term['finishedAt']);
    if (finished != null) {
      final reason = (term['reason'] as String?) ?? 'Terminated';
      final code = term['exitCode'];
      if (!duplicate(reason, name, finished)) {
        out.add(ChartMarker(
          time: finished,
          title: reason,
          severity: reason == 'Completed' || code == 0 ? ChartSeverity.info : ChartSeverity.error,
          details: ['container $name', if (code != null) 'exit code $code'],
        ));
      }
    }
  }
  return out..sort((a, b) => a.time.compareTo(b.time));
}

const _dupWindow = Duration(seconds: 90);
