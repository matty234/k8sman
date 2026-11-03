/// Typed access to the backend's `/api/metrics/*` endpoints (see API.md and
/// docs/METRICS.md). Everything goes through [ApiClient.metrics], which test
/// fakes override.
library;

import '../api/client.dart';
import '../api/models.dart';
import '../util/k8s.dart';

/// Availability of one metrics API group.
enum MetricsState { available, notReady, notInstalled, unknown }

MetricsState _state(dynamic s) => switch (s) {
  'available' => MetricsState.available,
  'notReady' => MetricsState.notReady,
  'notInstalled' => MetricsState.notInstalled,
  _ => MetricsState.unknown,
};

class MetricsApiStatus {
  final String group;
  final String? version;
  final MetricsState state;
  final String? reason;
  final String? message;

  /// Backing service `namespace/name`.
  final String? service;
  const MetricsApiStatus({required this.group, this.version, required this.state, this.reason, this.message, this.service});

  factory MetricsApiStatus.fromJson(Json j) {
    final svc = asMap(j['service']);
    return MetricsApiStatus(
      group: '${j['group'] ?? ''}',
      version: j['version'] as String?,
      state: _state(j['state']),
      reason: j['reason'] as String?,
      message: j['message'] as String?,
      service: svc.isEmpty ? null : '${svc['namespace']}/${svc['name']}',
    );
  }

  bool get available => state == MetricsState.available;
}

class MetricsStatus {
  final MetricsApiStatus resource;
  final MetricsApiStatus custom;
  final MetricsApiStatus external;
  const MetricsStatus({required this.resource, required this.custom, required this.external});

  factory MetricsStatus.fromJson(Json j) => MetricsStatus(
    resource: MetricsApiStatus.fromJson(asMap(j['resource'])),
    custom: MetricsApiStatus.fromJson(asMap(j['custom'])),
    external: MetricsApiStatus.fromJson(asMap(j['external'])),
  );

  List<MetricsApiStatus> get all => [resource, custom, external];
}

/// CPU (millicores) and memory (bytes) usage.
class Usage {
  final double cpuMillis;
  final double memoryBytes;
  const Usage(this.cpuMillis, this.memoryBytes);
  static const zero = Usage(0, 0);

  factory Usage.fromJson(Json j) =>
      Usage((j['cpuMillis'] as num?)?.toDouble() ?? parseCpuMillis(j['cpu']) ?? 0, (j['memoryBytes'] as num?)?.toDouble() ?? parseBytes(j['memory']) ?? 0);

  Usage operator +(Usage o) => Usage(cpuMillis + o.cpuMillis, memoryBytes + o.memoryBytes);
}

class NodeUsage {
  final String name;
  final Usage usage;
  final String? timestamp;
  const NodeUsage(this.name, this.usage, {this.timestamp});
  factory NodeUsage.fromJson(Json j) => NodeUsage('${j['name']}', Usage.fromJson(j), timestamp: j['timestamp'] as String?);
}

class PodUsage {
  final String name;
  final String namespace;
  final Usage usage;
  final Map<String, Usage> containers;
  final String? timestamp;
  final String? window;
  const PodUsage({required this.name, required this.namespace, required this.usage, this.containers = const {}, this.timestamp, this.window});

  factory PodUsage.fromJson(Json j) => PodUsage(
    name: '${j['name']}',
    namespace: '${j['namespace']}',
    usage: Usage.fromJson(j),
    containers: {for (final c in asMapList(j['containers'])) '${c['name']}': Usage.fromJson(c)},
    timestamp: j['timestamp'] as String?,
    window: j['window'] as String?,
  );

  String get key => '$namespace/$name';
}

/// A resource type with custom metrics.
class CustomMetricResource {
  final String resource;
  final String group;
  final bool namespaced;
  final List<String> metrics;
  const CustomMetricResource({required this.resource, required this.group, required this.namespaced, required this.metrics});

  factory CustomMetricResource.fromJson(Json j) => CustomMetricResource(
    resource: '${j['resource']}',
    group: '${j['group'] ?? ''}',
    namespaced: j['namespaced'] == true,
    metrics: List<String>.from(j['metrics'] ?? const []),
  );

  String get key => group.isEmpty ? resource : '$resource.$group';
}

/// One custom or external metric sample.
class MetricSample {
  final String metric;
  final ObjectRef? object;
  final Map<String, String> labels;
  final String value;
  final double number;
  final String? timestamp;
  final int? windowSeconds;
  const MetricSample({
    required this.metric,
    this.object,
    this.labels = const {},
    required this.value,
    required this.number,
    this.timestamp,
    this.windowSeconds,
  });

  factory MetricSample.fromJson(Json j) {
    final o = asMap(j['object']);
    final av = '${o['apiVersion'] ?? ''}';
    return MetricSample(
      metric: '${j['metric'] ?? ''}',
      object: o.isEmpty
          ? null
          : ObjectRef(group: av.contains('/') ? av.split('/').first : '', kind: '${o['kind']}', name: '${o['name']}', namespace: o['namespace'] as String?),
      labels: {for (final e in asMap(j['labels']).entries) e.key: '${e.value}'},
      value: '${j['value'] ?? ''}',
      number: (j['number'] as num?)?.toDouble() ?? 0,
      timestamp: j['timestamp'] as String?,
      windowSeconds: (j['windowSeconds'] as num?)?.toInt(),
    );
  }
}

/// An external metric name, discovered or referenced by an HPA.
class ExternalMetricRef {
  final String name;
  final String? namespace;
  final String? selector;

  /// `discovery` or `hpa`.
  final String source;
  final String? hpa;
  const ExternalMetricRef({required this.name, this.namespace, this.selector, required this.source, this.hpa});

  factory ExternalMetricRef.fromJson(Json j) => ExternalMetricRef(
    name: '${j['name']}',
    namespace: j['namespace'] as String?,
    selector: j['selector'] as String?,
    source: '${j['source'] ?? 'discovery'}',
    hpa: j['hpa'] as String?,
  );
}

/// One HPA metric with its live value (see `GET /api/metrics/hpa`).
class HpaLiveMetric {
  final int index;
  final String type;
  final String name;
  final String? container;
  final String? selector;
  final ObjectRef? object;
  final String targetType;
  final String target;
  final String? current;
  final int? utilization;
  final String? averageValue;
  final int pods;
  final double? ratio;
  final int? proposed;
  final bool driving;
  final String? error;

  const HpaLiveMetric({
    required this.index,
    required this.type,
    required this.name,
    this.container,
    this.selector,
    this.object,
    required this.targetType,
    required this.target,
    this.current,
    this.utilization,
    this.averageValue,
    this.pods = 0,
    this.ratio,
    this.proposed,
    this.driving = false,
    this.error,
  });

  factory HpaLiveMetric.fromJson(Json j) {
    final o = asMap(j['object']);
    final av = '${o['apiVersion'] ?? ''}';
    return HpaLiveMetric(
      index: (j['index'] as num?)?.toInt() ?? 0,
      type: '${j['type'] ?? ''}',
      name: '${j['name'] ?? ''}',
      container: j['container'] as String?,
      selector: j['selector'] as String?,
      object: o.isEmpty
          ? null
          : ObjectRef(group: av.contains('/') ? av.split('/').first : '', kind: '${o['kind']}', name: '${o['name']}', namespace: o['namespace'] as String?),
      targetType: '${j['targetType'] ?? ''}',
      target: '${j['target'] ?? ''}',
      current: j['current'] as String?,
      utilization: (j['utilization'] as num?)?.toInt(),
      averageValue: j['averageValue'] as String?,
      pods: (j['pods'] as num?)?.toInt() ?? 0,
      ratio: (j['ratio'] as num?)?.toDouble(),
      proposed: (j['proposed'] as num?)?.toInt(),
      driving: j['driving'] == true,
      error: j['error'] as String?,
    );
  }
}

class HpaAnalysis {
  final int currentReplicas;
  final int? desiredReplicas;
  final int minReplicas;
  final int maxReplicas;
  final int? proposed;

  /// `min` / `max` when the bounds, not a metric, set [proposed].
  final String? limitedBy;
  final String? selector;
  final List<HpaLiveMetric> metrics;
  final List<String> errors;
  const HpaAnalysis({
    required this.currentReplicas,
    this.desiredReplicas,
    required this.minReplicas,
    required this.maxReplicas,
    this.proposed,
    this.limitedBy,
    this.selector,
    this.metrics = const [],
    this.errors = const [],
  });

  factory HpaAnalysis.fromJson(Json j) => HpaAnalysis(
    currentReplicas: (j['currentReplicas'] as num?)?.toInt() ?? 0,
    desiredReplicas: (j['desiredReplicas'] as num?)?.toInt(),
    minReplicas: (j['minReplicas'] as num?)?.toInt() ?? 1,
    maxReplicas: (j['maxReplicas'] as num?)?.toInt() ?? 1,
    proposed: (j['proposed'] as num?)?.toInt(),
    limitedBy: j['limitedBy'] as String?,
    selector: j['selector'] as String?,
    metrics: [for (final m in asMapList(j['metrics'])) HpaLiveMetric.fromJson(m)],
    errors: List<String>.from(j['errors'] ?? const []),
  );
}

/// Why a metrics call failed, in UI terms.
class MetricsUnavailable implements Exception {
  final MetricsState state;
  final String message;
  const MetricsUnavailable(this.state, this.message);

  /// Maps backend errors: 404 = not installed, 503 = installed but not ready.
  static Object wrap(Object e) {
    if (e is ApiException) {
      if (e.status == 404 && e.message.contains('not installed')) return MetricsUnavailable(MetricsState.notInstalled, e.message);
      if (e.status == 503) return MetricsUnavailable(MetricsState.notReady, e.message);
    }
    return e;
  }

  @override
  String toString() => message;
}

extension MetricsApi on ApiClient {
  Future<T> _call<T>(Future<T> Function() f) async {
    try {
      return await f();
    } catch (e) {
      throw MetricsUnavailable.wrap(e);
    }
  }

  Future<MetricsStatus> metricsStatus({bool refresh = false}) =>
      _call(() async => MetricsStatus.fromJson(await metrics('status', {'refresh': refresh ? 'true' : null})));

  Future<List<NodeUsage>> nodeMetrics() => _call(() async => [for (final i in asMapList((await metrics('nodes'))['items'])) NodeUsage.fromJson(i)]);

  Future<List<PodUsage>> podMetrics({String? namespace, String? labelSelector}) => _call(
    () async => [
      for (final i in asMapList((await metrics('pods', {'namespace': namespace, 'labelSelector': labelSelector}))['items'])) PodUsage.fromJson(i),
    ],
  );

  Future<List<CustomMetricResource>> customMetricResources() =>
      _call(() async => [for (final r in asMapList((await metrics('custom/discover'))['resources'])) CustomMetricResource.fromJson(r)]);

  Future<List<MetricSample>> customMetric({
    String group = '',
    required String resource,
    String? namespace,
    String? name,
    String? selector,
    required String metric,
  }) => _call(
    () async => [
      for (final i in asMapList(
        (await metrics('custom', {
          'group': group,
          'resource': resource,
          'namespace': namespace,
          'name': name,
          'selector': selector,
          'metric': metric,
        }))['items'],
      ))
        MetricSample.fromJson(i),
    ],
  );

  Future<List<ExternalMetricRef>> externalMetricNames({String? namespace}) => _call(
    () async => [
      for (final m in asMapList((await metrics('external/discover', {'namespace': namespace}))['metrics'])) ExternalMetricRef.fromJson(m),
    ],
  );

  Future<List<MetricSample>> externalMetric({required String namespace, required String metric, String? labelSelector}) => _call(
    () async => [
      for (final i in asMapList((await metrics('external', {'namespace': namespace, 'metric': metric, 'labelSelector': labelSelector}))['items']))
        MetricSample.fromJson(i),
    ],
  );

  Future<HpaAnalysis> hpaAnalysis({required String namespace, required String name}) =>
      _call(() async => HpaAnalysis.fromJson(await metrics('hpa', {'namespace': namespace, 'name': name})));
}
