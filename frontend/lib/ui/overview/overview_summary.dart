/// Problem counts per kind for the sidebar, from `GET /api/overview` over
/// all namespaces.
library;

import 'package:flutter/foundation.dart';

import '../../api/backend_http.dart';
import '../../api/client.dart';
import 'overview_api.dart';

/// Objects of one kind with problems: how many and the worst severity
/// (critical or warning; info-only issues don't count).
@immutable
class KindProblems {
  final int count;
  final IssueSeverity severity;

  /// Category labels, in the overview's order.
  final List<String> labels;
  const KindProblems({required this.count, required this.severity, this.labels = const []});
}

/// The latest all-namespaces overview of the current context, reduced to
/// [KindProblems] per kind (`group/Kind`).
///
/// One per [ApiClient]. The Overview page feeds it whenever it fetches for
/// all namespaces; the sidebar polls [refreshIfStale] every [interval], which
/// only fetches when nothing fed it in the last [freshFor]. So the sidebar
/// costs at most one request per [interval], and none while the Overview
/// page is polling.
class OverviewSummary extends ChangeNotifier {
  static const interval = Duration(seconds: 30);
  static const freshFor = Duration(seconds: 25);

  static final _of = PerApi((ApiClient api) => OverviewSummary(OverviewApi(api)));
  static OverviewSummary of(ApiClient api) => _of(api);

  final OverviewApi source;
  OverviewSummary(this.source);

  /// Overview categories → the kind whose objects they are about, and the
  /// backend source (`pending`) that feeds that kind.
  static const _kindOf = {
    'crashLoop': '/Pod',
    'imagePull': '/Pod',
    'createContainerConfigError': '/Pod',
    'initBlocked': '/Pod',
    'oomKilled': '/Pod',
    'podFailed': '/Pod',
    'stuckPending': '/Pod',
    'stuckTerminating': '/Pod',
    'notReady': '/Pod',
    'highRestarts': '/Pod',
    'progressDeadlineExceeded': 'apps/Deployment',
    'deploymentUnavailable': 'apps/Deployment',
    'statefulSetNotReady': 'apps/StatefulSet',
    'daemonSetNotReady': 'apps/DaemonSet',
    'jobFailed': 'batch/Job',
    'jobLongRunning': 'batch/Job',
    'cronJobFailing': 'batch/CronJob',
    'cronJobOverdue': 'batch/CronJob',
    'nodeNotReady': '/Node',
    'nodePressure': '/Node',
    'pvcLost': '/PersistentVolumeClaim',
    'pvcPending': '/PersistentVolumeClaim',
    'argoSyncFailed': 'argoproj.io/Application',
    'argoDegraded': 'argoproj.io/Application',
    'argoMissing': 'argoproj.io/Application',
    'argoOutOfSync': 'argoproj.io/Application',
    'gatewayNotReady': 'gateway.networking.k8s.io/Gateway',
    'gatewayListener': 'gateway.networking.k8s.io/Gateway',
    // Routes: the issue's own kind (HTTPRoute, GRPCRoute, …), see summarise.
    'routeNotAccepted': '',
    'routeUnresolvedRefs': '',
  };
  static const _sourceOf = {
    '/Pod': 'pods',
    'apps/Deployment': 'deployments',
    'apps/StatefulSet': 'statefulsets',
    'apps/DaemonSet': 'daemonsets',
    'batch/Job': 'jobs',
    'batch/CronJob': 'cronjobs',
    '/Node': 'nodes',
    '/PersistentVolumeClaim': 'pvcs',
    'argoproj.io/Application': 'argocd',
    'gateway.networking.k8s.io/Gateway': 'gateway',
  };

  String? _context;
  DateTime? _at;
  bool _busy = false;

  /// The context whose first answer had sources still loading and got one
  /// quick re-check (so badges don't wait a whole [interval] on connect).
  String? _rechecked;
  static const recheckAfter = Duration(seconds: 2);
  Map<String, KindProblems> _byKind = const {};

  /// Problems per kind for [context] (empty for another context or before
  /// the first fetch).
  Map<String, KindProblems> forContext(String? context) => context == _context ? _byKind : const {};

  /// Takes an all-namespaces overview of [context] (fetched by anyone).
  void feed(OverviewData data, String? context) {
    _at = DateTime.now();
    final changedContext = context != _context;
    _context = context;
    final next = summarise(data);
    if (changedContext || !_sameAs(next)) {
      _byKind = next;
      notifyListeners();
    }
  }

  bool _sameAs(Map<String, KindProblems> next) =>
      next.length == _byKind.length &&
      next.entries.every((e) {
        final o = _byKind[e.key];
        return o != null && o.count == e.value.count && o.severity == e.value.severity && listEquals(o.labels, e.value.labels);
      });

  /// Fetches unless something fed this context in the last [freshFor] (or a
  /// fetch is running). False when the fetch failed.
  Future<bool> refreshIfStale() async {
    final ctx = source.api.context;
    final at = _at;
    if (_busy || (ctx == _context && at != null && DateTime.now().difference(at) < freshFor)) return true;
    _busy = true;
    try {
      final data = await source.fetch();
      // The context switched while fetching: drop it.
      if (source.api.context == ctx) {
        feed(data, ctx);
        if (data.pending.isNotEmpty && _rechecked != ctx) {
          _rechecked = ctx;
          Future.delayed(recheckAfter, () {
            if (source.api.context != ctx) return;
            _at = null;
            refreshIfStale();
          });
        }
      }
      return true;
    } catch (_) {
      // Remember the attempt, so a failing backend isn't asked again
      // before the next interval.
      if (ctx != _context) {
        _context = ctx;
        _byKind = const {};
        notifyListeners();
      }
      _at = DateTime.now();
      return false;
    } finally {
      _busy = false;
    }
  }

  /// Distinct objects per kind with critical or warning issues. Kinds whose
  /// source is still pending are left out (unknown, not zero).
  static Map<String, KindProblems> summarise(OverviewData data) {
    final objects = <String, Set<String>>{};
    final worst = <String, IssueSeverity>{};
    final cats = <String, Set<String>>{};
    for (final i in data.issues) {
      var gk = _kindOf[i.category];
      if (gk == '') gk = '${i.group}/${i.kind}'; // a route of any kind
      if (gk == null || i.severity == IssueSeverity.info || data.isPending(_sourceOf[gk] ?? 'gateway')) continue;
      objects.putIfAbsent(gk, () => {}).add('${i.namespace}/${i.name}');
      cats.putIfAbsent(gk, () => {}).add(i.category);
      if (worst[gk] == null || i.severity.index < worst[gk]!.index) worst[gk] = i.severity;
    }
    return {
      for (final e in objects.entries)
        e.key: KindProblems(
          count: e.value.length,
          severity: worst[e.key]!,
          labels: [for (final c in data.categories) if (cats[e.key]!.contains(c.id)) c.label],
        ),
    };
  }
}
