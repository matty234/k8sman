import 'dart:convert';
import 'dart:io';

import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';

import '../support/harness.dart';

/// Captured `/api/metrics/*` responses (kind dev cluster with metrics-server
/// and KEDA; custom metrics are constructed).
dynamic metricsFixture(String name) => jsonDecode(File('test/metrics/fixtures/$name').readAsStringSync());

Json nodeFixture() => Map<String, dynamic>.from(jsonDecode(File('../dev/fixtures/node-k8sman-dev-control-plane.json').readAsStringSync()));
List<Json> demoPods() => [for (final p in metricsFixture('pods-demo-objects.json')) Map<String, dynamic>.from(p)];

bool _matches(Json item, String? labelSelector) {
  if (labelSelector == null || labelSelector.isEmpty) return true;
  final labels = Map<String, dynamic>.from(item['metadata']?['labels'] ?? const {});
  return labelSelector.split(',').every((kv) {
    final p = kv.split('=');
    return p.length == 2 && labels[p[0]] == p[1];
  });
}

/// FakeApiClient that also serves the metrics endpoints.
class MetricsFakeApi extends FakeApiClient {
  /// metrics-server installed (false → 404 "not installed").
  final bool resourceMetrics;

  /// A custom metrics adapter installed.
  final bool customMetrics;
  final List<String> calls = [];
  /// The `namespace` of each pod metrics request.
  final podNamespaces = <String?>[];

  MetricsFakeApi({this.resourceMetrics = true, this.customMetrics = true, Map<String, List<Json>>? items})
      : super(
          itemsByResource: items ?? {'nodes': [nodeFixture()], 'pods': demoPods()},
          itemsFilter: (r, item, labelSelector, fieldSelector) => _matches(item, labelSelector),
        );

  static ApiException notInstalled(String group) => ApiException(404, '$group is not installed (no APIService registered)');

  @override
  Future<Json> metrics(String path, [Map<String, String?> query = const {}]) async {
    calls.add(path);
    Json f(String name) => Map<String, dynamic>.from(metricsFixture(name));
    switch (path) {
      case 'status':
        final s = f('status.json');
        if (!resourceMetrics) s['resource'] = {'group': 'metrics.k8s.io', 'state': 'notInstalled', 'available': false};
        if (customMetrics) {
          s['custom'] = {
            'group': 'custom.metrics.k8s.io',
            'version': 'v1beta2',
            'state': 'available',
            'available': true,
            'service': {'namespace': 'monitoring', 'name': 'prometheus-adapter'},
          };
        }
        return s;
      case 'nodes':
        if (!resourceMetrics) throw notInstalled('metrics.k8s.io');
        return f('nodes.json');
      case 'pods':
        podNamespaces.add(query['namespace']);
        if (!resourceMetrics) throw notInstalled('metrics.k8s.io');
        return f(query['namespace'] == 'demo' ? 'pods-demo.json' : 'pods-all.json');
      case 'custom/discover':
        if (!customMetrics) throw notInstalled('custom.metrics.k8s.io');
        return f('custom-discover.json');
      case 'custom':
        return f('custom-values.json');
      case 'external/discover':
        return f('external-discover.json');
      case 'external':
        return f('external-values.json');
      case 'hpa':
        return f('hpa-web.json');
    }
    throw ApiException(404, 'no fixture for $path');
  }
}
