import '../api/client.dart';
import 'kubelet_summary.dart';
import 'metrics_api.dart';

/// Shares recent metrics fetches between widgets of one [ApiClient] (e.g.
/// every container card of a pod, or every panel open on one namespace), so
/// they cost one request per [ttl].
class MetricsCache {
  static final _byApi = Expando<MetricsCache>('metricsCache');
  static MetricsCache of(ApiClient api) => _byApi[api] ??= MetricsCache._(api);

  final ApiClient api;
  MetricsCache._(this.api);

  /// Slightly shorter than the 15s poll so each poll gets fresh data.
  Duration ttl = const Duration(seconds: 10);
  final Map<String, (DateTime, Future<Object?>)> _entries = {};

  Future<T> _get<T>(String key, Future<T> Function() fetch, {bool force = false}) {
    final now = DateTime.now();
    final e = _entries[key];
    if (!force && e != null && now.difference(e.$1) < ttl) return e.$2.then((v) => v as T);
    final f = fetch();
    _entries[key] = (now, f);
    // Don't cache failures: the next caller retries.
    f.then<void>(
      (_) {},
      onError: (Object _) {
        if (_entries[key]?.$2 == f) _entries.remove(key);
      },
    );
    return f;
  }

  Future<List<NodeUsage>> nodes({bool force = false}) => _get('nodes', api.nodeMetrics, force: force);

  /// Pod usage in [namespace] (null = all namespaces).
  Future<List<PodUsage>> pods(String? namespace, {bool force = false}) =>
      _get('pods/${namespace ?? ''}', () => api.podMetrics(namespace: namespace), force: force);

  /// One pod's usage, or null if metrics-server has no sample for it.
  Future<PodUsage?> pod(String namespace, String name) async {
    for (final p in await pods(namespace)) {
      if (p.name == name) return p;
    }
    return null;
  }

  /// Kubelet summary (PVC usage, network rates) for [namespace] (null =
  /// all) on [nodes] (empty = all Ready nodes). Never throws.
  Future<KubeletSummary> summary(String? namespace, {Iterable<String> nodes = const []}) {
    final n = nodes.toSet().toList()..sort();
    return _get('summary/${namespace ?? ''}/${n.join(',')}', () => api.kubeletSummary(namespace: namespace, nodes: n));
  }

  Future<MetricsStatus> status({bool force = false}) => _get('status', () => api.metricsStatus(refresh: force), force: force);

  void clear() => _entries.clear();
}
