/// Kubelet Summary API data (`GET /api/metrics/summary`): PVC usage for
/// mounted claims and live network rates per pod and node. The fallback
/// when the cluster has no Prometheus; it never throws for an unusable
/// source, it reports [KubeletSummary.available] = false instead.
library;

import '../api/client.dart';
import '../api/models.dart';
import '../util/k8s.dart';

double? _num(dynamic v) => (v as num?)?.toDouble();

/// One mounted PVC's filesystem usage.
class KubeletVolume {
  final String namespace;
  final String claim;
  final String pod;
  final String node;
  final double? used;
  final double? capacity;
  final double? available;
  final double? inodes;
  final double? inodesUsed;
  const KubeletVolume({
    required this.namespace,
    required this.claim,
    this.pod = '',
    this.node = '',
    this.used,
    this.capacity,
    this.available,
    this.inodes,
    this.inodesUsed,
  });

  factory KubeletVolume.fromJson(Json j) => KubeletVolume(
    namespace: '${j['namespace'] ?? ''}',
    claim: '${j['claim'] ?? ''}',
    pod: '${j['pod'] ?? ''}',
    node: '${j['node'] ?? ''}',
    used: _num(j['usedBytes']),
    capacity: _num(j['capacityBytes']),
    available: _num(j['availableBytes']),
    inodes: _num(j['inodes']),
    inodesUsed: _num(j['inodesUsed']),
  );

  String get key => '$namespace/$claim';
}

/// Network throughput of a pod or node (bytes/s). Rates are null until the
/// backend has two samples (~12s after the first request).
class NetThroughput {
  final String? namespace;
  final String name;
  final double? rx;
  final double? tx;
  const NetThroughput({this.namespace, required this.name, this.rx, this.tx});

  factory NetThroughput.fromJson(Json j) {
    final ns = j['namespace'] as String?;
    return NetThroughput(
      namespace: ns == null || ns.isEmpty ? null : ns,
      name: '${j['name'] ?? ''}',
      rx: _num(j['rxBytesPerSec']),
      tx: _num(j['txBytesPerSec']),
    );
  }

  bool get measured => rx != null && tx != null;
  double get total => (rx ?? 0) + (tx ?? 0);
  String get key => namespace == null ? name : '$namespace/$name';
}

class KubeletSummary {
  final bool available;
  final String? message;
  final int nodes;
  final int reporting;
  final List<KubeletVolume> volumes;
  final List<NetThroughput> pods;
  final List<NetThroughput> nodeNetwork;
  const KubeletSummary({
    required this.available,
    this.message,
    this.nodes = 0,
    this.reporting = 0,
    this.volumes = const [],
    this.pods = const [],
    this.nodeNetwork = const [],
  });

  static const unavailable = KubeletSummary(available: false, message: 'kubelet stats unavailable');

  factory KubeletSummary.fromJson(Json j) => KubeletSummary(
    available: j['state'] == 'available',
    message: j['message'] as String?,
    nodes: (j['nodes'] as num?)?.toInt() ?? 0,
    reporting: (j['reporting'] as num?)?.toInt() ?? 0,
    volumes: [for (final v in asMapList(j['volumes'])) KubeletVolume.fromJson(v)],
    pods: [for (final p in asMapList(j['pods'])) NetThroughput.fromJson(p)],
    nodeNetwork: [for (final n in asMapList(j['nodeNetwork'])) NetThroughput.fromJson(n)],
  );

  /// The largest report of each claim (an RWX claim mounted on several
  /// nodes is reported once per pod).
  Map<String, KubeletVolume> get volumesByClaim {
    final out = <String, KubeletVolume>{};
    for (final v in volumes) {
      final prev = out[v.key];
      if (prev == null || (v.used ?? -1) > (prev.used ?? -1)) out[v.key] = v;
    }
    return out;
  }
}

extension KubeletSummaryApi on ApiClient {
  /// Summary for [nodes] (all Ready nodes when empty), filtered to
  /// [namespace]. Any failure becomes an unavailable summary.
  Future<KubeletSummary> kubeletSummary({String? namespace, Iterable<String> nodes = const []}) async {
    try {
      return KubeletSummary.fromJson(await metrics('summary', {'namespace': namespace, 'node': nodes.isEmpty ? null : nodes.join(',')}));
    } catch (e) {
      return KubeletSummary(available: false, message: '$e');
    }
  }
}
