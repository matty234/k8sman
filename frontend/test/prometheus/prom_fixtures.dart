import 'dart:convert';
import 'dart:io';

import 'package:k8sman/api/client.dart';
import 'package:k8sman/prometheus/prom_api.dart';

/// JSON captured from a real backend against kube-prometheus-stack on the
/// dev cluster (see "Fixtures" in docs/PROMETHEUS.md).
dynamic promFixture(String name) => jsonDecode(File('test/prometheus/fixtures/$name.json').readAsStringSync());

/// Serves /api/prom/* from fixtures and records mutations.
class FixturePromApi extends PromApi {
  /// No Prometheus/Alertmanager at all.
  final bool missing;

  /// With [missing]: the search itself failed (the cluster API unreachable).
  final bool discoveryFailed;
  final List<(String method, String path, Object? body)> sent = [];

  /// PromQL passed to query / query_range.
  final List<String> queries = [];

  /// Number of `alerts` fetches.
  int alertFetches = 0;

  FixturePromApi({this.missing = false, this.discoveryFailed = false}) : super(ApiClient(base: Uri.parse('http://fake')));

  @override
  Future<dynamic> getJson(String path, [Map<String, String?> query = const {}]) async {
    if (missing) {
      if (path == 'status') return {'prometheus': [], 'alertmanager': [], 'operatorCRDs': false};
      if (path == 'alerts') {
        return {'groups': [], 'summary': {}, if (discoveryFailed) 'errors': {'discovery': 'services: connection refused'}};
      }
      throw ApiException(404, 'no prometheus found in the cluster', reason: 'NotFound');
    }
    switch (path) {
      case 'status':
        return promFixture('status');
      case 'alerts':
        alertFetches++;
        return promFixture('alerts');
      case 'silences':
        return promFixture('silences');
      case 'rules':
        return promFixture('rules-k8sman-demo');
      case 'targets':
        return promFixture(query['kind'] == 'PodMonitor' ? 'targets-podmonitor-grafana' : 'targets-servicemonitor-web');
      case 'query_range':
        final q = query['query'] ?? '';
        queries.add(q);
        final by = q.contains('by (container)');
        if (q.contains('kube_node_status_allocatable')) return promFixture(q.contains('resource="cpu"') ? 'query-cluster-cpu' : 'query-cluster-mem');
        if (q.contains('node_cpu_seconds_total')) return promFixture('query-node-cpu');
        if (q.contains('node_memory')) return promFixture('query-node-mem');
        if (q.contains('container_cpu_usage_seconds_total')) return promFixture(by ? 'query-pod-cpu-containers' : 'query-pod-cpu');
        return promFixture(by ? 'query-pod-mem-containers' : 'query-pod-mem');
    }
    throw ApiException(404, 'no fixture for $path');
  }

  @override
  Future<dynamic> send(String method, String path, {Map<String, String?> query = const {}, Object? body}) async {
    sent.add((method, path, body));
    if (method == 'POST' && path == 'silences') return {'silenceID': 'new-silence'};
    return {};
  }
}
