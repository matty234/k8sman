/// Gateway API helpers: reference parsing, attachment rules and plain-English
/// explanations of status conditions. Pure (no Flutter).
library;

import '../../api/models.dart';
import '../../util/k8s.dart';

const gwGroup = 'gateway.networking.k8s.io';

/// A Gateway API route kind.
class RouteKind {
  final String kind;
  final String resource;
  final bool hasHostnames;
  const RouteKind(this.kind, this.resource, {this.hasHostnames = true});

  String get gk => '$gwGroup/$kind';
  ResourceRef get ref => ResourceRef(group: gwGroup, resource: resource);
}

const routeKinds = [
  RouteKind('HTTPRoute', 'httproutes'),
  RouteKind('GRPCRoute', 'grpcroutes'),
  RouteKind('TLSRoute', 'tlsroutes'),
  RouteKind('TCPRoute', 'tcproutes', hasHostnames: false),
  RouteKind('UDPRoute', 'udproutes', hasHostnames: false),
];

RouteKind? routeKindOf(String kind) => routeKinds.where((k) => k.kind == kind).firstOrNull;

/// A route object together with its kind.
class RouteObj {
  final RouteKind kind;
  final Json object;
  const RouteObj(this.kind, this.object);

  String get name => dig<String>(object, ['metadata', 'name']) ?? '';
  String get namespace => dig<String>(object, ['metadata', 'namespace']) ?? '';
  List<String> get hostnames => [for (final h in (dig<List>(object, ['spec', 'hostnames']) ?? const [])) '$h'];
  List<ParentRef> get parentRefs => [for (final p in asMapList(dig(object, ['spec', 'parentRefs']))) ParentRef.fromJson(p, namespace)];
  List<Json> get rules => asMapList(dig(object, ['spec', 'rules']));
  List<BackendRef> get backendRefs => [for (final r in rules) for (final b in asMapList(r['backendRefs'])) BackendRef.fromJson(b, namespace)];

  /// The status entry for [ref], if a controller reported one.
  Json? statusFor(ParentRef ref) => parentStatus(object, ref);
}

/// Condition [type] from a conditions list, or null.
Json? condOf(dynamic conds, String type) => asMapList(conds).where((c) => c['type'] == type).firstOrNull;

bool condTrue(Json? c) => c?['status'] == 'True';
bool condFalse(Json? c) => c?['status'] == 'False';

/// "HTTPRoutes", "Gateways", "Services".
String pluralKind(String kind) => kind.endsWith('s') ? '${kind}es' : '${kind}s';

// ---------------------------------------------------------------------------
// References

/// A normalised spec.parentRefs entry (defaults filled in).
class ParentRef {
  final String group;
  final String kind;
  final String namespace;
  final String name;
  final String? sectionName;
  final int? port;
  const ParentRef({this.group = gwGroup, this.kind = 'Gateway', required this.namespace, required this.name, this.sectionName, this.port});

  factory ParentRef.fromJson(Json j, String routeNamespace) => ParentRef(
        group: j.containsKey('group') ? '${j['group'] ?? ''}' : gwGroup,
        kind: '${j['kind'] ?? 'Gateway'}',
        namespace: '${j['namespace'] ?? routeNamespace}',
        name: '${j['name'] ?? ''}',
        sectionName: j['sectionName'] as String?,
        port: (j['port'] as num?)?.toInt(),
      );

  bool get isGateway => group == gwGroup && kind == 'Gateway';
  bool targets(String ns, String gwName) => isGateway && namespace == ns && name == gwName;

  /// "gateway-demo/demo-gw".
  String get qualified => '$namespace/$name';

  /// " · listener http" / " · port 80" / ''.
  String get sectionText => [if (sectionName != null) 'listener $sectionName', if (port != null) 'port $port'].join(' · ');

  @override
  bool operator ==(Object other) =>
      other is ParentRef &&
      other.group == group &&
      other.kind == kind &&
      other.namespace == namespace &&
      other.name == name &&
      other.sectionName == sectionName &&
      other.port == port;
  @override
  int get hashCode => Object.hash(group, kind, namespace, name, sectionName, port);
}

/// The status.parents entry of [route] for [ref].
Json? parentStatus(Json route, ParentRef ref) {
  final ns = dig<String>(route, ['metadata', 'namespace']) ?? '';
  for (final p in asMapList(dig(route, ['status', 'parents']))) {
    if (ParentRef.fromJson(asMap(p['parentRef']), ns) == ref) return p;
  }
  return null;
}

/// A normalised backendRef (or mirror / certificate reference).
class BackendRef {
  final String group;
  final String kind;
  final String namespace;
  final String name;
  final int? port;
  final int weight;
  final bool explicitNamespace;
  const BackendRef({this.group = '', this.kind = 'Service', required this.namespace, required this.name, this.port, this.weight = 1, this.explicitNamespace = false});

  factory BackendRef.fromJson(Json j, String routeNamespace) => BackendRef(
        group: '${j['group'] ?? ''}',
        kind: '${j['kind'] ?? 'Service'}',
        namespace: '${j['namespace'] ?? routeNamespace}',
        name: '${j['name'] ?? ''}',
        port: (j['port'] as num?)?.toInt(),
        weight: (j['weight'] as num?)?.toInt() ?? 1,
        explicitNamespace: j['namespace'] != null,
      );

  bool get isService => group.isEmpty && kind == 'Service';
  String get key => '$group/$kind/$namespace/$name';
  ObjectRef get objectRef => ObjectRef(group: group, kind: kind, name: name, namespace: namespace);

  /// "demo/web" when it crosses namespaces, else "web".
  String label(String fromNamespace) => namespace == fromNamespace ? name : '$namespace/$name';
}

/// Weight of [ref] as a whole-number share of [refs] (null when there's one).
int? weightPercent(List<BackendRef> refs, BackendRef ref) {
  if (refs.length < 2) return null;
  final total = refs.fold<int>(0, (s, r) => s + r.weight);
  if (total == 0) return 0;
  return (ref.weight * 100 / total).round();
}

// ---------------------------------------------------------------------------
// ReferenceGrant

/// Whether [grant] (living in the target namespace) lets [fromKind] objects
/// in [fromNamespace] refer to [to].
bool grantPermits(Json grant, {required String fromGroup, required String fromKind, required String fromNamespace, required BackendRef to}) {
  final spec = asMap(grant['spec']);
  if (dig<String>(grant, ['metadata', 'namespace']) != to.namespace) return false;
  final fromOk = asMapList(spec['from']).any((f) => '${f['group'] ?? ''}' == fromGroup && f['kind'] == fromKind && f['namespace'] == fromNamespace);
  if (!fromOk) return false;
  return asMapList(spec['to']).any((t) =>
      '${t['group'] ?? ''}' == to.group && t['kind'] == to.kind && ((t['name'] ?? '').toString().isEmpty || t['name'] == to.name));
}

/// True when some grant in [grants] permits the reference.
bool anyGrantPermits(Iterable<Json> grants, {required String fromKind, required String fromNamespace, required BackendRef to, String fromGroup = gwGroup}) =>
    grants.any((g) => grantPermits(g, fromGroup: fromGroup, fromKind: fromKind, fromNamespace: fromNamespace, to: to));

String _toPhrase(Json t) {
  final kind = '${t['kind'] ?? '?'}';
  final name = (t['name'] ?? '').toString();
  return name.isEmpty ? 'any $kind' : 'the $kind $name';
}

/// One sentence per `from` entry, e.g. "Allows HTTPRoutes in namespace
/// gateway-demo to reference the Service web in demo."
List<String> describeGrant(Json grant) {
  final ns = dig<String>(grant, ['metadata', 'namespace']) ?? '?';
  final spec = asMap(grant['spec']);
  final to = asMapList(spec['to']);
  final targets = to.isEmpty ? 'nothing' : to.map(_toPhrase).join(' or ');
  return [
    for (final f in asMapList(spec['from'])) 'Allows ${pluralKind('${f['kind']}')} in namespace ${f['namespace']} to reference $targets in $ns.',
  ];
}

// ---------------------------------------------------------------------------
// Listeners

/// Route kinds a listener accepts by default for its protocol.
List<String> defaultRouteKinds(String protocol) => switch (protocol) {
      'HTTP' || 'HTTPS' => const ['HTTPRoute', 'GRPCRoute'],
      'TLS' => const ['TLSRoute'],
      'TCP' => const ['TCPRoute'],
      'UDP' => const ['UDPRoute'],
      _ => const [],
    };

/// Route kinds a listener allows (explicit `allowedRoutes.kinds`, else by protocol).
List<String> listenerKinds(Json listener) {
  final explicit = [for (final k in asMapList(dig(listener, ['allowedRoutes', 'kinds']))) '${k['kind']}'];
  return explicit.isNotEmpty ? explicit : defaultRouteKinds('${listener['protocol'] ?? ''}');
}

/// "Same namespace", "All namespaces", "Namespaces with gateway-access=true".
String describeAllowedNamespaces(Json listener, String gatewayNamespace) {
  final ns = asMap(dig(listener, ['allowedRoutes', 'namespaces']));
  return switch ('${ns['from'] ?? 'Same'}') {
    'All' => 'all namespaces',
    'Selector' => 'namespaces with ${selectorToString(ns['selector']).replaceAll(',', ', ')}',
    _ => 'this namespace ($gatewayNamespace)',
  };
}

/// Hostname match per the Gateway API: exact, or a `*.` wildcard on either side.
bool hostnamesIntersect(String? listenerHost, List<String> routeHosts) {
  if (listenerHost == null || listenerHost.isEmpty || routeHosts.isEmpty) return true;
  bool wild(String w, String h) => w.startsWith('*.') && h.endsWith(w.substring(1)) && h.length > w.length - 1;
  return routeHosts.any((h) => h == listenerHost || wild(listenerHost, h) || wild(h, listenerHost) || (h.startsWith('*.') && listenerHost.startsWith('*.') && (h.endsWith(listenerHost.substring(1)) || listenerHost.endsWith(h.substring(1)))));
}

/// Why [listener] would refuse [route], or null if it allows it. When the
/// namespace selector can't be evaluated ([nsLabels] unknown) it's allowed.
String? listenerRefusal(Json listener, String gatewayNamespace, RouteObj route, {Map<String, Json>? nsLabels}) {
  final name = listener['name'];
  final kinds = listenerKinds(listener);
  if (!kinds.contains(route.kind.kind)) {
    return "Listener '$name' (${listener['protocol']}) only accepts ${kinds.isEmpty ? 'no route kinds' : kinds.map(pluralKind).join(', ')}.";
  }
  final ns = asMap(dig(listener, ['allowedRoutes', 'namespaces']));
  final from = '${ns['from'] ?? 'Same'}';
  if (from == 'Same' && route.namespace != gatewayNamespace) {
    return "Listener '$name' only accepts routes from its own namespace ($gatewayNamespace); this route is in ${route.namespace}.";
  }
  if (from == 'Selector' && nsLabels != null) {
    final labels = nsLabels[route.namespace];
    if (labels != null && !_selectorMatches(asMap(ns['selector']), labels)) {
      return "Listener '$name' only accepts routes from ${describeAllowedNamespaces(listener, gatewayNamespace)}; namespace ${route.namespace} doesn't match.";
    }
  }
  final host = listener['hostname'] as String?;
  if (route.kind.hasHostnames && !hostnamesIntersect(host, route.hostnames)) {
    return "None of the route's hostnames (${route.hostnames.join(', ')}) match listener '$name' ($host).";
  }
  return null;
}

bool _selectorMatches(Json sel, Json labels) {
  for (final e in asMap(sel['matchLabels']).entries) {
    if ('${labels[e.key]}' != '${e.value}') return false;
  }
  for (final ex in asMapList(sel['matchExpressions'])) {
    final v = labels[ex['key']];
    final values = [for (final x in (ex['values'] as List? ?? const [])) '$x'];
    final ok = switch (ex['operator']) {
      'In' => v != null && values.contains('$v'),
      'NotIn' => v == null || !values.contains('$v'),
      'Exists' => v != null,
      'DoesNotExist' => v == null,
      _ => true,
    };
    if (!ok) return false;
  }
  return true;
}

/// The listeners of [gateway] that [ref] (from [route]) names or could attach to.
List<Json> listenersFor(Json gateway, ParentRef ref, RouteObj route, {Map<String, Json>? nsLabels}) {
  final gwNs = dig<String>(gateway, ['metadata', 'namespace']) ?? '';
  final all = asMapList(dig(gateway, ['spec', 'listeners']));
  return [
    for (final l in all)
      if ((ref.sectionName == null || l['name'] == ref.sectionName) &&
          (ref.port == null || l['port'] == ref.port) &&
          listenerRefusal(l, gwNs, route, nsLabels: nsLabels) == null)
        l,
  ];
}

// ---------------------------------------------------------------------------
// Diagnoses

enum DiagLevel { info, warn, error }

class Diag {
  final DiagLevel level;
  final String title;
  final String? detail;
  const Diag(this.level, this.title, [this.detail]);

  @override
  String toString() => '$title${detail == null ? '' : ' ($detail)'}';
}

String _msg(Json? c) => '${c?['message'] ?? ''}'.trim();

/// Why a Gateway is not Accepted / Programmed. Empty when healthy.
List<Diag> explainGateway(Json gw, {Json? gatewayClass}) {
  final conds = dig(gw, ['status', 'conditions']);
  final accepted = condOf(conds, 'Accepted');
  final programmed = condOf(conds, 'Programmed');
  final className = dig<String>(gw, ['spec', 'gatewayClassName']) ?? '?';
  final out = <Diag>[];
  final pending = accepted == null || accepted['reason'] == 'Pending' || (accepted['status'] == 'Unknown');
  if (pending) {
    final ctrl = dig<String>(gatewayClass, ['spec', 'controllerName']);
    out.add(Diag(
      DiagLevel.error,
      'No controller has picked up this Gateway',
      'Nothing has reconciled GatewayClass $className${ctrl != null ? ' (controller $ctrl)' : ''}. Check that its controller is installed and running.',
    ));
    return out;
  }
  if (condFalse(accepted)) {
    final detail = switch (accepted['reason']) {
      'InvalidParameters' => 'The GatewayClass or infrastructure parameters are invalid. ${_msg(accepted)}',
      'UnsupportedAddress' => 'A requested spec.addresses entry is not supported. ${_msg(accepted)}',
      'ListenersNotValid' => 'One or more listeners are invalid; see Listeners below. ${_msg(accepted)}',
      _ => _msg(accepted),
    };
    out.add(Diag(DiagLevel.error, 'Not accepted: ${accepted['reason'] ?? 'unknown reason'}', detail.trim().isEmpty ? null : detail.trim()));
  }
  if (programmed != null && !condTrue(programmed)) {
    final detail = switch (programmed['reason']) {
      'AddressNotAssigned' =>
        'The controller could not get an address. On local clusters this is usually a LoadBalancer Service stuck pending: use a ClusterIP or NodePort proxy Service, or install a load balancer (MetalLB, cloud-provider-kind).',
      'Pending' => 'The controller is still provisioning the data plane.',
      _ => _msg(programmed),
    };
    out.add(Diag(DiagLevel.error, 'Not programmed: ${programmed['reason'] ?? 'unknown reason'}', detail.isEmpty ? null : detail));
  }
  return out;
}

/// Problems on one listener from status.listeners, most important first.
List<Diag> listenerProblems(Json? listenerStatus) {
  final conds = listenerStatus?['conditions'];
  final out = <Diag>[];
  final conflicted = condOf(conds, 'Conflicted');
  if (condTrue(conflicted)) {
    out.add(Diag(DiagLevel.error, switch (conflicted!['reason']) {
      'HostnameConflict' => 'Hostname conflicts with another listener on this port',
      'ProtocolConflict' => 'Protocol conflicts with another listener on this port',
      _ => 'Conflicted: ${conflicted['reason']}',
    }, _msg(conflicted)));
  }
  final resolved = condOf(conds, 'ResolvedRefs');
  if (condFalse(resolved)) {
    out.add(Diag(DiagLevel.error, switch (resolved!['reason']) {
      'InvalidCertificateRef' => 'Certificate Secret missing or invalid',
      'RefNotPermitted' => 'Certificate in another namespace is not allowed by a ReferenceGrant',
      'InvalidRouteKinds' => 'allowedRoutes lists an unsupported route kind',
      _ => 'Unresolved references: ${resolved['reason']}',
    }, _msg(resolved)));
  }
  final accepted = condOf(conds, 'Accepted');
  if (condFalse(accepted)) {
    out.add(Diag(DiagLevel.error, switch (accepted!['reason']) {
      'PortUnavailable' => 'Port unavailable',
      'UnsupportedProtocol' => 'Protocol not supported by this implementation',
      _ => 'Not accepted: ${accepted['reason']}',
    }, _msg(accepted)));
  }
  final programmed = condOf(conds, 'Programmed');
  if (out.isEmpty && condFalse(programmed)) {
    out.add(Diag(DiagLevel.warn, 'Not programmed: ${programmed!['reason']}', _msg(programmed)));
  }
  return out;
}

/// Explains one parentRef of a route. [gateway] is the fetched parent
/// (null if unknown); [gatewayMissing] means it was looked up and is 404.
/// [grants] are the ReferenceGrants of the backends' namespaces, when known.
List<Diag> explainRouteParent(
  RouteObj route,
  ParentRef ref, {
  Json? gateway,
  bool gatewayMissing = false,
  Iterable<Json>? grants,
  Set<String> missingBackends = const {},
  Map<String, Json>? nsLabels,
}) {
  final out = <Diag>[];
  final status = route.statusFor(ref);
  final where = '${ref.kind} ${ref.qualified}';
  if (gatewayMissing) {
    out.add(Diag(DiagLevel.error, '$where does not exist', 'Fix parentRefs or create the ${ref.kind}.'));
    return out;
  }
  if (status == null) {
    out.add(Diag(DiagLevel.warn, 'No status from any controller for $where',
        'The parent may use a GatewayClass whose controller is not running, or the controller has not processed this route yet.'));
    return out;
  }
  final conds = status['conditions'];
  final accepted = condOf(conds, 'Accepted');
  if (!condTrue(accepted)) {
    out.add(_explainNotAccepted(route, ref, accepted, gateway, nsLabels));
  }
  final resolved = condOf(conds, 'ResolvedRefs');
  if (condFalse(resolved)) {
    out.addAll(_explainUnresolved(route, resolved!, grants, missingBackends));
  }
  return out;
}

Diag _explainNotAccepted(RouteObj route, ParentRef ref, Json? c, Json? gateway, Map<String, Json>? nsLabels) {
  final where = '${ref.kind} ${ref.qualified}';
  final reason = c?['reason'];
  final listeners = asMapList(dig(gateway, ['spec', 'listeners']));
  final names = [for (final l in listeners) '${l['name']}'];
  final gwNs = ref.namespace;
  switch (reason) {
    case 'NoMatchingParent':
      if (gateway != null && ref.sectionName != null && !names.contains(ref.sectionName)) {
        return Diag(DiagLevel.error, "Listener '${ref.sectionName}' not found on $where",
            'It has: ${names.join(', ')}. Fix sectionName in parentRefs, or add the listener.');
      }
      if (gateway != null && ref.port != null && !listeners.any((l) => l['port'] == ref.port)) {
        return Diag(DiagLevel.error, 'No listener on port ${ref.port} of $where',
            'Its ports: ${{for (final l in listeners) l['port']}.join(', ')}.');
      }
      return Diag(DiagLevel.error, 'No listener on $where matches this parentRef', _msg(c).isEmpty ? null : _msg(c));
    case 'NotAllowedByListeners':
      final candidates = [for (final l in listeners) if (ref.sectionName == null || l['name'] == ref.sectionName) l];
      final why = [for (final l in candidates) listenerRefusal(l, gwNs, route, nsLabels: nsLabels)].whereType<String>().toList();
      return Diag(DiagLevel.error, 'Not allowed by the listeners of $where',
          why.isNotEmpty ? why.join(' ') : (_msg(c).isEmpty ? 'Check allowedRoutes (namespaces and kinds) on the listeners.' : _msg(c)));
    case 'NoMatchingListenerHostname':
      final hosts = [for (final l in listeners) if (ref.sectionName == null || l['name'] == ref.sectionName) l['hostname'] ?? '*'];
      return Diag(DiagLevel.error, 'No hostname overlap with $where',
          "Route hostnames (${route.hostnames.join(', ')}) don't match the listener hostnames (${hosts.join(', ')}).");
    case 'UnsupportedValue':
      return Diag(DiagLevel.error, 'Unsupported value in the route', _msg(c));
    case 'Pending':
    case null when c != null && c['status'] == 'Unknown':
      return Diag(DiagLevel.warn, 'Waiting for the controller of $where', _msg(c).isEmpty ? null : _msg(c));
    default:
      return Diag(DiagLevel.error, 'Not accepted by $where${reason != null ? ': $reason' : ''}', _msg(c).isEmpty ? null : _msg(c));
  }
}

List<Diag> _explainUnresolved(RouteObj route, Json c, Iterable<Json>? grants, Set<String> missingBackends) {
  final reason = c['reason'];
  final refs = route.backendRefs;
  switch (reason) {
    case 'RefNotPermitted':
      final blocked = [
        for (final b in refs)
          if (b.namespace != route.namespace && (grants == null || !anyGrantPermits(grants, fromKind: route.kind.kind, fromNamespace: route.namespace, to: b))) b,
      ];
      if (blocked.isEmpty) return [Diag(DiagLevel.error, 'Cross-namespace reference not permitted', _msg(c))];
      return [
        for (final b in blocked)
          Diag(DiagLevel.error, 'backendRef to ${b.kind} ${b.namespace}/${b.name} requires a ReferenceGrant in ${b.namespace}',
              'Create a ReferenceGrant in ${b.namespace} that allows ${pluralKind(route.kind.kind)} from ${route.namespace} to reference ${b.kind} ${b.name}.'),
      ];
    case 'BackendNotFound':
      final missing = [for (final b in refs) if (missingBackends.contains(b.key)) b];
      if (missing.isEmpty) return [Diag(DiagLevel.error, 'A backend does not exist', _msg(c))];
      return [
        for (final b in missing) Diag(DiagLevel.error, '${b.kind} ${b.namespace}/${b.name} does not exist', 'Traffic to this backend fails (HTTP 500 for HTTPRoutes).'),
      ];
    case 'InvalidKind':
      return [Diag(DiagLevel.error, 'A backendRef uses a kind this implementation does not support', _msg(c))];
    case 'UnsupportedProtocol':
      return [Diag(DiagLevel.error, "A backend's appProtocol is not supported", _msg(c))];
    default:
      return [Diag(DiagLevel.error, 'Unresolved references${reason != null ? ': $reason' : ''}', _msg(c).isEmpty ? null : _msg(c))];
  }
}

// ---------------------------------------------------------------------------
// Rendering helpers

/// Readable parts of one HTTP/GRPC match: ["prefix /api", "header x-canary = true"].
List<String> describeMatch(Json m, {bool grpc = false}) {
  final out = <String>[];
  if (grpc) {
    final method = asMap(m['method']);
    if (method.isNotEmpty) {
      final svc = method['service'] ?? '*';
      final meth = method['method'] ?? '*';
      out.add('${method['type'] == 'RegularExpression' ? '~ ' : ''}$svc/$meth');
    }
  } else {
    final path = asMap(m['path']);
    if (path.isNotEmpty) {
      final v = '${path['value'] ?? '/'}';
      out.add(switch ('${path['type'] ?? 'PathPrefix'}') {
        'Exact' => 'path = $v',
        'RegularExpression' => 'path ~ $v',
        _ => v == '/' ? 'any path' : 'path $v*',
      });
    }
    if (m['method'] != null) out.add('method ${m['method']}');
  }
  for (final h in asMapList(m['headers'])) {
    out.add('header ${h['name']} ${h['type'] == 'RegularExpression' ? '~' : '='} ${h['value']}');
  }
  for (final q in asMapList(m['queryParams'])) {
    out.add('query ${q['name']}${q['type'] == 'RegularExpression' ? ' ~ ' : '='}${q['value']}');
  }
  return out;
}

String _headerOps(Json mod) {
  final parts = <String>[
    for (final h in asMapList(mod['set'])) 'set ${h['name']}: ${h['value']}',
    for (final h in asMapList(mod['add'])) 'add ${h['name']}: ${h['value']}',
    for (final h in (mod['remove'] as List? ?? const [])) 'remove $h',
  ];
  return parts.join('; ');
}

String _pathMod(Json p) => switch (p['type']) {
      'ReplaceFullPath' => 'path ${p['replaceFullPath']}',
      'ReplacePrefixMatch' => 'prefix ${p['replacePrefixMatch']}',
      _ => '',
    };

/// One readable line per filter.
String describeFilter(Json f, {String routeNamespace = ''}) {
  final type = '${f['type'] ?? '?'}';
  switch (type) {
    case 'RequestHeaderModifier':
      return 'Request headers: ${_headerOps(asMap(f['requestHeaderModifier']))}';
    case 'ResponseHeaderModifier':
      return 'Response headers: ${_headerOps(asMap(f['responseHeaderModifier']))}';
    case 'RequestRedirect':
      final r = asMap(f['requestRedirect']);
      final to = [
        if (r['scheme'] != null) 'scheme ${r['scheme']}',
        if (r['hostname'] != null) 'host ${r['hostname']}',
        if (r['port'] != null) 'port ${r['port']}',
        if (r['path'] != null) _pathMod(asMap(r['path'])),
      ].where((s) => s.isNotEmpty).join(', ');
      return 'Redirect${to.isEmpty ? '' : ' to $to'} (${r['statusCode'] ?? 302})';
    case 'URLRewrite':
      final r = asMap(f['urlRewrite']);
      final to = [
        if (r['hostname'] != null) 'host ${r['hostname']}',
        if (r['path'] != null) _pathMod(asMap(r['path'])),
      ].where((s) => s.isNotEmpty).join(', ');
      return 'Rewrite $to';
    case 'RequestMirror':
      final r = asMap(f['requestMirror']);
      final b = BackendRef.fromJson(asMap(r['backendRef']), routeNamespace);
      final pct = r['percent'] ?? (r['fraction'] != null ? '${dig(r, ['fraction', 'numerator'])}/${dig(r, ['fraction', 'denominator']) ?? 100}' : null);
      return 'Mirror to ${b.label(routeNamespace)}${b.port != null ? ':${b.port}' : ''}${pct != null ? ' ($pct${pct is num ? '%' : ''})' : ''}';
    case 'ExtensionRef':
      final r = asMap(f['extensionRef']);
      return 'Extension ${r['kind']}/${r['name']}${(r['group'] ?? '').toString().isNotEmpty ? ' (${r['group']})' : ''}';
    case 'CORS':
      return 'CORS policy';
    default:
      return type;
  }
}

/// Mirror backends referenced by a rule's filters (and backendRef filters).
List<BackendRef> mirrorRefs(Json rule, String routeNamespace) => [
      for (final f in asMapList(rule['filters']))
        if (f['type'] == 'RequestMirror') BackendRef.fromJson(asMap(dig(f, ['requestMirror', 'backendRef'])), routeNamespace),
    ];

/// "request 10s · backend 5s".
String? describeTimeouts(Json rule) {
  final t = asMap(rule['timeouts']);
  final parts = [if (t['request'] != null) 'request ${t['request']}', if (t['backendRequest'] != null) 'backend ${t['backendRequest']}'];
  return parts.isEmpty ? null : parts.join(' · ');
}

/// First concrete host for a hostname that may be a wildcard.
String? concreteHost(Iterable<String?> hosts) {
  for (final h in hosts) {
    if (h == null || h.isEmpty) continue;
    return h.startsWith('*.') ? 'test${h.substring(1)}' : h;
  }
  return null;
}

String _q(String s) => "'${s.replaceAll("'", "'\\''")}'";

/// An example command that exercises [rule], or null when no address is
/// known or the route kind has no request semantics (TCP/UDP/TLS).
String? exampleCommand(RouteObj route, Json rule, {required String? address, Json? listener}) {
  if (address == null || address.isEmpty) return null;
  final protocol = '${listener?['protocol'] ?? 'HTTP'}';
  final port = (listener?['port'] as num?)?.toInt();
  final host = concreteHost([...route.hostnames, listener?['hostname'] as String?]);
  final matches = asMapList(rule['matches']);
  final m = matches.isEmpty ? const <String, dynamic>{} : matches.first;
  final headers = [
    for (final h in asMapList(m['headers']))
      if (h['type'] != 'RegularExpression') '-H ${_q('${h['name']}: ${h['value']}')}',
  ];
  if (route.kind.kind == 'GRPCRoute') {
    final method = asMap(m['method']);
    final target = method['service'] != null && method['method'] != null && method['type'] != 'RegularExpression' ? ' ${method['service']}/${method['method']}' : ' list';
    final tls = protocol == 'HTTPS';
    return [
      'grpcurl',
      tls ? '-insecure' : '-plaintext',
      if (host != null) '-authority $host',
      ...headers,
      '$address:${port ?? (tls ? 443 : 80)}$target',
    ].join(' ');
  }
  if (route.kind.kind != 'HTTPRoute') return null;
  final path = asMap(m['path']);
  var p = path['type'] == 'RegularExpression' ? '/' : '${path['value'] ?? '/'}';
  final query = [
    for (final q in asMapList(m['queryParams']))
      if (q['type'] != 'RegularExpression') '${Uri.encodeQueryComponent('${q['name']}')}=${Uri.encodeQueryComponent('${q['value']}')}',
  ];
  if (query.isNotEmpty) p = '$p?${query.join('&')}';
  final method = m['method'] != null && m['method'] != 'GET' ? '-X ${m['method']} ' : '';
  final h = headers.isEmpty ? '' : '${headers.join(' ')} ';
  if (protocol == 'HTTPS') {
    final portSuffix = port == null || port == 443 ? '' : ':$port';
    if (host == null) return 'curl -k $method$h${_q('https://$address$portSuffix$p')}';
    return 'curl -k --resolve $host:${port ?? 443}:$address $method$h${_q('https://$host$portSuffix$p')}';
  }
  final portSuffix = port == null || port == 80 ? '' : ':$port';
  return 'curl $method${host != null ? '-H ${_q('Host: $host')} ' : ''}$h${_q('http://$address$portSuffix$p')}';
}

/// The overall acceptance of a route over its parents.
class RouteHealth {
  final int parents;
  final int accepted;
  final bool unresolved;
  const RouteHealth(this.parents, this.accepted, this.unresolved);

  factory RouteHealth.of(RouteObj r) {
    final refs = r.parentRefs;
    var ok = 0;
    var unresolved = false;
    for (final p in refs) {
      final s = r.statusFor(p);
      if (condTrue(condOf(s?['conditions'], 'Accepted'))) ok++;
      if (condFalse(condOf(s?['conditions'], 'ResolvedRefs'))) unresolved = true;
    }
    return RouteHealth(refs.length, ok, unresolved);
  }

  bool get healthy => parents > 0 && accepted == parents && !unresolved;

  /// Short badge text: "Accepted", "Not accepted", "1/2 accepted", "Unresolved refs".
  String get label => parents == 0
      ? 'No parents'
      : accepted == 0
          ? 'Not accepted'
          : accepted < parents
              ? '$accepted/$parents accepted'
              : unresolved
                  ? 'Unresolved refs'
                  : 'Accepted';

  DiagLevel get level => healthy ? DiagLevel.info : (accepted == 0 ? DiagLevel.error : DiagLevel.warn);
}
