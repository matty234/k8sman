/// Typed access to the backend's `/api/hubble` (Cilium Hubble flows; see
/// API.md "Hubble").
library;

import '../api/backend_http.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../state/frame_stream.dart';
import '../util/k8s.dart';
import 'traffic_model.dart';

/// One side of a flow.
class FlowEndpoint {
  final String? namespace;
  final String? pod;
  final String? workloadKind;
  final String? workloadName;

  /// `namespace/name` of the Service the flow was addressed to.
  final String? service;
  final String? ip;
  final int? port;
  final int? identity;

  /// DNS names Hubble knows for the IP (world endpoints).
  final List<String> names;

  /// Cilium's reserved identity for non-pod endpoints: world, host, …
  final String? reserved;

  const FlowEndpoint({
    this.namespace,
    this.pod,
    this.workloadKind,
    this.workloadName,
    this.service,
    this.ip,
    this.port,
    this.identity,
    this.names = const [],
    this.reserved,
  });

  factory FlowEndpoint.fromJson(Json j) => FlowEndpoint(
        namespace: j['namespace'] as String?,
        pod: j['pod'] as String?,
        workloadKind: j['workloadKind'] as String?,
        workloadName: j['workloadName'] as String?,
        service: j['service'] as String?,
        ip: j['ip'] as String?,
        port: (j['port'] as num?)?.toInt(),
        identity: (j['identity'] as num?)?.toInt(),
        names: [for (final n in (j['names'] as List? ?? const [])) '$n'],
        reserved: j['reserved'] as String?,
      );

  /// A short name: namespace/pod, the service, a DNS name, the reserved
  /// identity or the IP.
  String get label {
    if (pod != null) return '$namespace/$pod';
    if (service != null) return service!;
    if (names.isNotEmpty) return names.first;
    if (reserved != null) return reserved!;
    return ip ?? 'identity $identity';
  }

  /// What a click opens: the pod, else the service.
  ObjectRef? get ref {
    if (pod != null && namespace != null) return ObjectRef(kind: 'Pod', name: pod!, namespace: namespace);
    final s = service;
    if (s != null && s.contains('/')) return ObjectRef(kind: 'Service', namespace: s.split('/').first, name: s.split('/').last);
    return null;
  }

  /// An endpoint spec for `from`/`to` (see API.md).
  String? get spec {
    if (pod != null) return '$namespace/$pod';
    if (service != null) return 'svc:$service';
    if (names.isNotEmpty) return 'fqdn:${names.first}';
    return ip;
  }
}

class FlowPolicy {
  final String? kind;
  final String? namespace;
  final String name;
  const FlowPolicy({this.kind, this.namespace, required this.name});
  factory FlowPolicy.fromJson(Json j) => FlowPolicy(kind: j['kind'] as String?, namespace: j['namespace'] as String?, name: '${j['name'] ?? ''}');

  @override
  String toString() => [if (kind != null && kind!.isNotEmpty) kind, if (namespace != null && namespace!.isNotEmpty) '$namespace/$name' else name].join(' ');
}

/// One flow (see hubble.Flow in the backend).
class HubbleFlow {
  final DateTime? time;
  final String verdict;
  final String? dropReason;
  final String? direction;
  final bool isReply;
  final FlowEndpoint source;
  final FlowEndpoint destination;
  final String? protocol;
  final List<String> tcpFlags;
  final String? l7Kind;
  final double? l7LatencyMs;
  final String? httpMethod;
  final String? httpUrl;
  final int? httpCode;
  final String? dnsQuery;
  final int? dnsRCode;
  final String? node;
  final String? event;
  final List<FlowPolicy> allowedBy;
  final List<FlowPolicy> deniedBy;

  const HubbleFlow({
    this.time,
    required this.verdict,
    this.dropReason,
    this.direction,
    this.isReply = false,
    required this.source,
    required this.destination,
    this.protocol,
    this.tcpFlags = const [],
    this.l7Kind,
    this.l7LatencyMs,
    this.httpMethod,
    this.httpUrl,
    this.httpCode,
    this.dnsQuery,
    this.dnsRCode,
    this.node,
    this.event,
    this.allowedBy = const [],
    this.deniedBy = const [],
  });

  factory HubbleFlow.fromJson(Json j) {
    final l4 = asMap(j['l4']);
    final l7 = asMap(j['l7']);
    final http = asMap(l7['http']);
    final dns = asMap(l7['dns']);
    final pol = asMap(j['policies']);
    return HubbleFlow(
      time: DateTime.tryParse('${j['time'] ?? ''}'),
      verdict: '${j['verdict'] ?? 'VERDICT_UNKNOWN'}',
      dropReason: j['dropReason'] as String?,
      direction: j['direction'] as String?,
      isReply: j['isReply'] == true,
      source: FlowEndpoint.fromJson(asMap(j['source'])),
      destination: FlowEndpoint.fromJson(asMap(j['destination'])),
      protocol: l4['protocol'] as String?,
      tcpFlags: [for (final f in (l4['flags'] as List? ?? const [])) '$f'],
      l7Kind: l7['kind'] as String?,
      l7LatencyMs: (l7['latencyMs'] as num?)?.toDouble(),
      httpMethod: http['method'] as String?,
      httpUrl: http['url'] as String?,
      httpCode: (http['code'] as num?)?.toInt(),
      dnsQuery: dns['query'] as String?,
      dnsRCode: (dns['rcode'] as num?)?.toInt(),
      node: j['node'] as String?,
      event: j['event'] as String?,
      allowedBy: [for (final p in asMapList(pol['allowedBy'])) FlowPolicy.fromJson(p)],
      deniedBy: [for (final p in asMapList(pol['deniedBy'])) FlowPolicy.fromJson(p)],
    );
  }

  bool get dropped => verdict == 'DROPPED';

  /// L7 detail in one line: "GET /api → 200", "DNS example.com", or null.
  String? get l7Summary {
    if (httpMethod != null || httpUrl != null || httpCode != null) {
      final req = [if (httpMethod != null && httpMethod!.isNotEmpty) httpMethod, if (httpUrl != null && httpUrl!.isNotEmpty) Uri.tryParse(httpUrl!)?.path ?? httpUrl].join(' ');
      return [if (req.isNotEmpty) req, if (httpCode != null && httpCode! > 0) '→ $httpCode'].join(' ');
    }
    if (dnsQuery != null) return 'DNS ${dnsQuery!}${dnsRCode != null && dnsRCode! > 0 ? ' (rcode $dnsRCode)' : ''}';
    return null;
  }
}

/// GET /api/hubble/status.
class HubbleStatus {
  /// notInstalled | noRelay | connected | unreachable.
  final String state;
  final String? message;
  final String? relayNamespace;
  final String? relayService;
  final bool tls;
  final String? version;
  final int? connectedNodes;
  final List<String> unavailableNodes;
  final double? flowsRate;
  final int? numFlows;
  final int? maxFlows;

  const HubbleStatus({
    required this.state,
    this.message,
    this.relayNamespace,
    this.relayService,
    this.tls = false,
    this.version,
    this.connectedNodes,
    this.unavailableNodes = const [],
    this.flowsRate,
    this.numFlows,
    this.maxFlows,
  });

  factory HubbleStatus.fromJson(Json j) {
    final r = asMap(j['relay']);
    final s = asMap(j['server']);
    return HubbleStatus(
      state: '${j['state'] ?? 'unreachable'}',
      message: j['message'] as String?,
      relayNamespace: r['namespace'] as String?,
      relayService: r['service'] as String?,
      tls: r['tls'] == true,
      version: s['version'] as String?,
      connectedNodes: (s['connectedNodes'] as num?)?.toInt(),
      unavailableNodes: [for (final n in (s['unavailableNodes'] as List? ?? const [])) '$n'],
      flowsRate: (s['flowsRate'] as num?)?.toDouble(),
      numFlows: (s['numFlows'] as num?)?.toInt(),
      maxFlows: (s['maxFlows'] as num?)?.toInt(),
    );
  }

  bool get connected => state == 'connected';

  /// "hubble-relay v1.18.7 · 13 nodes · 4.9k flows/s".
  String get summary => [
        if (version != null) version!.split('+').first,
        if (connectedNodes != null) '$connectedNodes node${connectedNodes == 1 ? '' : 's'}',
        if (unavailableNodes.isNotEmpty) '${unavailableNodes.length} unavailable',
        if (flowsRate != null) '${_compact(flowsRate!)} flows/s',
      ].join(' · ');
}

String _compact(double v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : v.toStringAsFixed(v < 10 ? 1 : 0);

/// One group of GET /api/hubble/drops, also built client-side from live
/// drops ([DropGroup.group]).
class DropGroup {
  final FlowEndpoint source;
  final FlowEndpoint destination;
  final String reason;
  final String? protocol;
  final int? port;
  int count;
  DateTime? first;
  DateTime? last;
  final List<FlowPolicy> deniedBy;

  DropGroup({
    required this.source,
    required this.destination,
    required this.reason,
    this.protocol,
    this.port,
    this.count = 0,
    this.first,
    this.last,
    this.deniedBy = const [],
  });

  factory DropGroup.fromJson(Json j) => DropGroup(
        source: FlowEndpoint.fromJson(asMap(j['source'])),
        destination: FlowEndpoint.fromJson(asMap(j['destination'])),
        reason: '${j['reason'] ?? ''}',
        protocol: j['protocol'] as String?,
        port: (j['port'] as num?)?.toInt(),
        count: (j['count'] as num?)?.toInt() ?? 0,
        first: DateTime.tryParse('${j['first'] ?? ''}'),
        last: DateTime.tryParse('${j['last'] ?? ''}'),
        deniedBy: [for (final p in asMapList(j['deniedBy'])) FlowPolicy.fromJson(p)],
      );

  /// Adds [flows]' drops into [groups] (keyed by source, destination,
  /// reason, protocol and port), the way the backend groups them.
  static void group(Map<String, DropGroup> groups, Iterable<HubbleFlow> flows) {
    for (final f in flows) {
      if (!f.dropped) continue;
      final reason = f.dropReason ?? '';
      final key = '${f.source.label}|${f.destination.label}|$reason|${f.protocol}|${f.destination.port}';
      final g = groups[key] ??= DropGroup(source: f.source, destination: f.destination, reason: reason, protocol: f.protocol, port: f.destination.port, deniedBy: f.deniedBy);
      g.count++;
      final t = f.time;
      if (t != null) {
        if (g.first == null || t.isBefore(g.first!)) g.first = t;
        if (g.last == null || t.isAfter(g.last!)) g.last = t;
      }
    }
  }
}

/// GET /api/hubble/connectivity.
class Connectivity {
  /// allowed | dropped | mixed | unknown.
  final String verdict;
  final Map<String, int> verdicts;
  final Map<String, int> reverse;
  final List<DropGroup> drops;
  final List<FlowPolicy> allowedBy;
  final List<HubbleFlow> recent;
  final DateTime? oldest;

  const Connectivity({
    required this.verdict,
    this.verdicts = const {},
    this.reverse = const {},
    this.drops = const [],
    this.allowedBy = const [],
    this.recent = const [],
    this.oldest,
  });

  factory Connectivity.fromJson(Json j) => Connectivity(
        verdict: '${j['verdict'] ?? 'unknown'}',
        verdicts: {for (final e in asMap(j['verdicts']).entries) e.key: (e.value as num).toInt()},
        reverse: {for (final e in asMap(j['reverse']).entries) e.key: (e.value as num).toInt()},
        drops: [for (final d in asMapList(j['drops'])) DropGroup.fromJson(d)],
        allowedBy: [for (final p in asMapList(j['allowedBy'])) FlowPolicy.fromJson(p)],
        recent: [for (final f in asMapList(j['recent'])) HubbleFlow.fromJson(f)],
        oldest: DateTime.tryParse('${j['oldest'] ?? ''}'),
      );
}

/// What to stream: the backend's query parameters (see API.md).
class FlowQuery {
  final List<String> namespaces;
  final String? pod;

  /// Match [pod] exactly rather than as a name prefix.
  final bool exact;
  final String? labels;
  final String? service;
  final String? from;
  final String? to;
  final Set<String> verdicts;
  final String? protocol;
  final String? port;
  final String? direction;

  const FlowQuery({
    this.namespaces = const [],
    this.pod,
    this.exact = false,
    this.labels,
    this.service,
    this.from,
    this.to,
    this.verdicts = const {},
    this.protocol,
    this.port,
    this.direction,
  });

  FlowQuery copyWith({Set<String>? verdicts, List<String>? namespaces, String? protocol, String? port, String? direction}) => FlowQuery(
        namespaces: namespaces ?? this.namespaces,
        pod: pod,
        exact: exact,
        labels: labels,
        service: service,
        from: from,
        to: to,
        verdicts: verdicts ?? this.verdicts,
        protocol: protocol ?? this.protocol,
        port: port ?? this.port,
        direction: direction ?? this.direction,
      );

  Map<String, String?> toParams() => {
        'namespace': namespaces.isEmpty ? null : namespaces.join(','),
        'pod': pod,
        'exact': exact ? 'true' : null,
        'labels': labels,
        'service': service,
        'from': from,
        'to': to,
        'verdict': verdicts.isEmpty ? null : (verdicts.toList()..sort()).join(','),
        'protocol': protocol,
        'port': port,
        'direction': direction,
      };

  @override
  bool operator ==(Object other) => other is FlowQuery && _same(toParams(), other.toParams());
  @override
  int get hashCode => Object.hashAll(toParams().entries.map((e) => '${e.key}=${e.value}'));

  static bool _same(Map<String, String?> a, Map<String, String?> b) => a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}

/// The Hubble endpoints, cached per [ApiClient]. Tests set [debugOverride].
class HubbleApi {
  final ApiClient api;
  final BackendHttp _http;
  HubbleApi(this.api) : _http = BackendHttp(api, '/api/hubble/');

  static final _of = PerApi(HubbleApi.new);
  static set debugOverride(HubbleApi Function(ApiClient api)? f) => _of.debugOverride = f;
  static HubbleApi of(ApiClient api) => _of(api);

  Future<HubbleStatus> status({bool refresh = false}) async =>
      HubbleStatus.fromJson(jsonObjectBody(await _http.get('status', {'refresh': refresh ? 'true' : null})));

  Future<List<DropGroup>> drops({List<String> namespaces = const [], String since = '15m'}) async {
    final j = jsonObjectBody(await _http.get('drops', {'namespace': namespaces.isEmpty ? null : namespaces.join(','), 'since': since}));
    return [for (final g in asMapList(j['groups'])) DropGroup.fromJson(g)];
  }

  Future<Connectivity> connectivity(String from, String to, {String since = '15m'}) async =>
      Connectivity.fromJson(jsonObjectBody(await _http.get('connectivity', {'from': from, 'to': to, 'since': since})));

  /// GET /api/hubble/map: traffic between namespaces and the world over
  /// [window]. Asking keeps the backend counting (it stops a minute after
  /// the last request).
  Future<TrafficMap> trafficMap({String window = '5m'}) async => TrafficMap.fromJson(jsonObjectBody(await _http.get('map', {'window': window})));

  /// WS /api/hubble/flows: batched frames `{flows, lost, end, error}`.
  Stream<Json> flowFrames(FlowQuery q, {bool follow = true}) => api.jsonStream('hubble/flows', {...q.toParams(), 'follow': follow ? 'true' : 'false'});

  /// A live list of [q]'s flows (not started: call [FrameStream.start]).
  FrameStream<HubbleFlow> stream(FlowQuery q, {int capacity = 5000}) => FrameStream<HubbleFlow>(
        capacity: capacity,
        connect: () => flowFrames(q),
        decode: decodeFlowFrame,
      );
}

/// Decodes one /api/hubble/flows frame.
StreamFrame<HubbleFlow> decodeFlowFrame(Json j) => (
      items: [for (final f in asMapList(j['flows'])) HubbleFlow.fromJson(f)],
      lost: (j['lost'] as num?)?.toInt() ?? 0,
      end: j['end'] == true,
      error: j['error'] as String?,
    );
