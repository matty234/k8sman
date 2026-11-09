/// Typed access to the backend's `/api/gpu` NVIDIA GPU inventory (see API.md
/// "NVIDIA GPUs"): GPU nodes, allocations, and live DCGM stats when the
/// cluster's Prometheus has them.
library;

import '../api/backend_http.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../util/k8s.dart';

double? _num(dynamic v) => v is num ? v.toDouble() : null;
int _int(dynamic v) => v is num ? v.toInt() : 0;
String? _str(dynamic v) => v is String && v.isNotEmpty ? v : null;
List<String> _strs(dynamic v) => v is List ? [for (final e in v) '$e'] : const [];

class GpuPodRef {
  final String namespace;
  final String name;
  final int gpus;
  const GpuPodRef({required this.namespace, required this.name, this.gpus = 0});
  factory GpuPodRef.fromJson(Json j) => GpuPodRef(namespace: '${j['namespace'] ?? ''}', name: '${j['name'] ?? ''}', gpus: _int(j['gpus']));
}

class GpuResource {
  final String name;
  final int capacity, allocatable, allocated;
  const GpuResource({required this.name, this.capacity = 0, this.allocatable = 0, this.allocated = 0});
  factory GpuResource.fromJson(Json j) =>
      GpuResource(name: '${j['name']}', capacity: _int(j['capacity']), allocatable: _int(j['allocatable']), allocated: _int(j['allocated']));
}

/// One GPU (or MIG instance) reporting DCGM metrics. Fractions are 0..1,
/// memory in bytes.
class GpuDevice {
  final String node;
  final String gpu;
  final String? uuid, model, pciBusId, migProfile;
  final double? util, avgUtil, memCopyUtil, tensorActive, grActive, dramActive, encUtil, decUtil;
  final double? memUsed, memTotal, tempC, memTempC, powerW, smClockMHz;
  final double? xid, uncorrectableRemappedRows, rowRemapFailure;
  final List<GpuPodRef> pods;
  final List<String> health;
  final bool idle;
  final String selector;

  const GpuDevice({
    required this.node,
    required this.gpu,
    this.uuid,
    this.model,
    this.pciBusId,
    this.migProfile,
    this.util,
    this.avgUtil,
    this.memCopyUtil,
    this.tensorActive,
    this.grActive,
    this.dramActive,
    this.encUtil,
    this.decUtil,
    this.memUsed,
    this.memTotal,
    this.tempC,
    this.memTempC,
    this.powerW,
    this.smClockMHz,
    this.xid,
    this.uncorrectableRemappedRows,
    this.rowRemapFailure,
    this.pods = const [],
    this.health = const [],
    this.idle = false,
    this.selector = '',
  });

  factory GpuDevice.fromJson(Json j) => GpuDevice(
        node: '${j['node'] ?? ''}',
        gpu: '${j['gpu'] ?? ''}',
        uuid: _str(j['uuid']),
        model: _str(j['model']),
        pciBusId: _str(j['pciBusId']),
        migProfile: _str(j['migProfile']),
        util: _num(j['util']),
        avgUtil: _num(j['avgUtil']),
        memCopyUtil: _num(j['memCopyUtil']),
        tensorActive: _num(j['tensorActive']),
        grActive: _num(j['grActive']),
        dramActive: _num(j['dramActive']),
        encUtil: _num(j['encUtil']),
        decUtil: _num(j['decUtil']),
        memUsed: _num(j['memUsed']),
        memTotal: _num(j['memTotal']),
        tempC: _num(j['tempC']),
        memTempC: _num(j['memTempC']),
        powerW: _num(j['powerW']),
        smClockMHz: _num(j['smClockMHz']),
        xid: _num(j['xid']),
        uncorrectableRemappedRows: _num(j['uncorrectableRemappedRows']),
        rowRemapFailure: _num(j['rowRemapFailure']),
        pods: [for (final p in asMapList(j['pods'])) GpuPodRef.fromJson(p)],
        health: _strs(j['health']),
        idle: j['idle'] == true,
        selector: '${j['selector'] ?? ''}',
      );

  String get label => migProfile == null ? 'GPU $gpu' : 'GPU $gpu · $migProfile';
}

class GpuNode {
  final String name;
  final bool ready, unschedulable, monitored;
  final String? product, family, driverVersion, cudaVersion, migStrategy, sharingStrategy;
  final int memoryMiB, count, replicas;
  final int capacity, allocatable, allocated, idleAllocated;
  final List<GpuResource> resources;
  final List<GpuDevice> devices;
  final List<GpuPodRef> pods;
  final String? selector;

  const GpuNode({
    required this.name,
    this.ready = true,
    this.unschedulable = false,
    this.monitored = false,
    this.product,
    this.family,
    this.driverVersion,
    this.cudaVersion,
    this.migStrategy,
    this.sharingStrategy,
    this.memoryMiB = 0,
    this.count = 0,
    this.replicas = 0,
    this.capacity = 0,
    this.allocatable = 0,
    this.allocated = 0,
    this.idleAllocated = 0,
    this.resources = const [],
    this.devices = const [],
    this.pods = const [],
    this.selector,
  });

  factory GpuNode.fromJson(Json j) => GpuNode(
        name: '${j['name']}',
        ready: j['ready'] == true,
        unschedulable: j['unschedulable'] == true,
        monitored: j['monitored'] == true,
        product: _str(j['product']),
        family: _str(j['family']),
        driverVersion: _str(j['driverVersion']),
        cudaVersion: _str(j['cudaVersion']),
        migStrategy: _str(j['migStrategy']),
        sharingStrategy: _str(j['sharingStrategy']),
        memoryMiB: _int(j['memoryMiB']),
        count: _int(j['count']),
        replicas: _int(j['replicas']),
        capacity: _int(j['capacity']),
        allocatable: _int(j['allocatable']),
        allocated: _int(j['allocated']),
        idleAllocated: _int(j['idleAllocated']),
        resources: [for (final r in asMapList(j['resources'])) GpuResource.fromJson(r)],
        devices: [for (final d in asMapList(j['devices'])) GpuDevice.fromJson(d)],
        pods: [for (final p in asMapList(j['pods'])) GpuPodRef.fromJson(p)],
        selector: _str(j['selector']),
      );

  /// The product label made readable ("Tesla-V100-SXM2-32GB" → "Tesla V100 SXM2 32GB").
  String get productName => (product ?? devices.map((d) => d.model).whereType<String>().firstOrNull ?? 'NVIDIA GPU').replaceAll('-', ' ');
}

class GpuPod {
  final String namespace, name, phase;
  final String? node, startedAt, selector, unschedulable;
  final int gpus;
  final Map<String, int> resources;
  final List<String> devices;
  final double? util, avgUtil;
  final bool idle;

  const GpuPod({
    required this.namespace,
    required this.name,
    required this.phase,
    this.node,
    this.startedAt,
    this.selector,
    this.unschedulable,
    this.gpus = 0,
    this.resources = const {},
    this.devices = const [],
    this.util,
    this.avgUtil,
    this.idle = false,
  });

  factory GpuPod.fromJson(Json j) => GpuPod(
        namespace: '${j['namespace']}',
        name: '${j['name']}',
        phase: '${j['phase'] ?? ''}',
        node: _str(j['node']),
        startedAt: _str(j['startedAt']),
        selector: _str(j['selector']),
        unschedulable: _str(j['unschedulable']),
        gpus: _int(j['gpus']),
        resources: {for (final e in asMap(j['resources']).entries) e.key: _int(e.value)},
        devices: _strs(j['devices']),
        util: _num(j['util']),
        avgUtil: _num(j['avgUtil']),
        idle: j['idle'] == true,
      );

  /// "2 GPUs", or the MIG/shared resources when no whole GPUs.
  String get request {
    if (gpus > 0) return gpus == 1 ? '1 GPU' : '$gpus GPUs';
    return resources.entries.map((e) => '${e.value}× ${e.key.replaceFirst('nvidia.com/', '')}').join(', ');
  }
}

class GpuIssue {
  final String severity, reason, message;
  final String? node, namespace, pod, gpu;
  const GpuIssue({required this.severity, required this.reason, required this.message, this.node, this.namespace, this.pod, this.gpu});
  factory GpuIssue.fromJson(Json j) => GpuIssue(
        severity: '${j['severity'] ?? 'info'}',
        reason: '${j['reason'] ?? ''}',
        message: '${j['message'] ?? ''}',
        node: _str(j['node']),
        namespace: _str(j['namespace']),
        pod: _str(j['pod']),
        gpu: _str(j['gpu']),
      );

  Severity get level => switch (severity) {
        'critical' => Severity.error,
        'warning' => Severity.warn,
        _ => Severity.info,
      };
}

class GpuSummary {
  final int nodes, capacity, allocatable, allocated, devices, idle, unhealthy, unmonitored, pendingPods;
  final double? avgUtil;
  const GpuSummary({
    this.nodes = 0,
    this.capacity = 0,
    this.allocatable = 0,
    this.allocated = 0,
    this.devices = 0,
    this.idle = 0,
    this.unhealthy = 0,
    this.unmonitored = 0,
    this.pendingPods = 0,
    this.avgUtil,
  });
  factory GpuSummary.fromJson(Json j) => GpuSummary(
        nodes: _int(j['nodes']),
        capacity: _int(j['capacity']),
        allocatable: _int(j['allocatable']),
        allocated: _int(j['allocated']),
        devices: _int(j['devices']),
        idle: _int(j['idle']),
        unhealthy: _int(j['unhealthy']),
        unmonitored: _int(j['unmonitored']),
        pendingPods: _int(j['pendingPods']),
        avgUtil: _num(j['avgUtil']),
      );
}

/// Monitoring source of the live stats.
enum GpuMonitoring { dcgm, noExporter, noPrometheus, error, skipped }

class GpuInventory {
  final GpuMonitoring monitoring;
  final String? prometheus;
  final bool attribution;
  final GpuSummary summary;
  final List<GpuNode> nodes;
  final List<GpuPod> pods;
  final List<GpuIssue> issues;
  final Map<String, String> errors;
  final DateTime? generatedAt;

  const GpuInventory({
    this.monitoring = GpuMonitoring.skipped,
    this.prometheus,
    this.attribution = false,
    this.summary = const GpuSummary(),
    this.nodes = const [],
    this.pods = const [],
    this.issues = const [],
    this.errors = const {},
    this.generatedAt,
  });

  factory GpuInventory.fromJson(Json j) => GpuInventory(
        monitoring: GpuMonitoring.values.where((m) => m.name == j['monitoring']).firstOrNull ?? GpuMonitoring.skipped,
        prometheus: _str(j['prometheus']),
        attribution: j['attribution'] == true,
        summary: GpuSummary.fromJson(asMap(j['summary'])),
        nodes: [for (final n in asMapList(j['nodes'])) GpuNode.fromJson(n)],
        pods: [for (final p in asMapList(j['pods'])) GpuPod.fromJson(p)],
        issues: [for (final i in asMapList(j['issues'])) GpuIssue.fromJson(i)],
        errors: {for (final e in asMap(j['errors']).entries) e.key: '${e.value}'},
        generatedAt: DateTime.tryParse('${j['generatedAt']}'),
      );

  bool get hasGpus => nodes.isNotEmpty;
  bool get live => monitoring == GpuMonitoring.dcgm;
  GpuNode? node(String name) => nodes.where((n) => n.name == name).firstOrNull;
  GpuPod? pod(String namespace, String name) => pods.where((p) => p.namespace == namespace && p.name == name).firstOrNull;
}

/// The GPU endpoint, cached per [ApiClient]. Tests set [debugOverride].
class GpuApi {
  final BackendHttp _http;
  GpuApi(ApiClient api) : _http = BackendHttp(api, '/api/');

  static final _of = PerApi(GpuApi.new);
  static set debugOverride(GpuApi Function(ApiClient api)? f) => _of.debugOverride = f;
  static GpuApi of(ApiClient api) => _of(api);

  /// The inventory; [live] false skips Prometheus (allocation only).
  Future<GpuInventory> inventory({bool live = true, bool refresh = false}) async =>
      GpuInventory.fromJson(jsonObjectBody(await _http.get('gpu', {'live': live ? null : 'false', 'refresh': refresh ? 'true' : null})));

  final Map<String, (DateTime, Future<GpuInventory>)> _recent = {};

  /// [inventory] shared by panels opened in quick succession (5s).
  Future<GpuInventory> cached(String contextName) {
    final hit = _recent[contextName];
    if (hit != null && DateTime.now().difference(hit.$1) < const Duration(seconds: 5)) return hit.$2;
    final f = inventory();
    _recent[contextName] = (DateTime.now(), f);
    f.catchError((_) {
      _recent.remove(contextName);
      return const GpuInventory();
    });
    return f;
  }
}
