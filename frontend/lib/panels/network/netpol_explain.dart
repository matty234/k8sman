/// Plain-English explanation of a NetworkPolicy spec. Pure (no Flutter).
library;

import '../../api/models.dart';
import '../../util/k8s.dart';

enum PolicyMode {
  /// The policy doesn't list this direction in policyTypes.
  unrestricted,

  /// Listed in policyTypes but with no rules: everything is denied.
  denyAll,

  /// Some rule has neither peers nor ports: everything is allowed.
  allowAll,

  /// Only traffic matching the rules is allowed.
  restricted,
}

class RuleExplanation {
  /// Each peer described; empty means "anywhere".
  final List<String> peers;

  /// Each port described; empty means "any port".
  final List<String> ports;
  const RuleExplanation(this.peers, this.ports);

  String phrase(String preposition) {
    final who = peers.isEmpty ? '$preposition anywhere' : '$preposition ${peers.map((p) => '($p)').join(' OR ')}';
    final where = ports.isEmpty ? ' on any port' : ', on ${ports.join(', ')}';
    return '$who$where';
  }
}

class DirectionExplanation {
  final String direction; // 'Ingress' | 'Egress'
  final PolicyMode mode;
  final List<RuleExplanation> rules;
  const DirectionExplanation(this.direction, this.mode, this.rules);

  String get preposition => direction == 'Ingress' ? 'from' : 'to';

  String get text => switch (mode) {
        PolicyMode.unrestricted => '$direction: not restricted by this policy.',
        PolicyMode.denyAll => '$direction: all traffic denied (no rules allow anything).',
        PolicyMode.allowAll => '$direction: all traffic allowed.',
        PolicyMode.restricted => '$direction: allowed only ${rules.map((r) => r.phrase(preposition)).join('; OR ')}.',
      };
}

class NetpolExplanation {
  final String appliesTo;
  final List<String> policyTypes;
  final bool policyTypesDefaulted;
  final DirectionExplanation ingress;
  final DirectionExplanation egress;
  const NetpolExplanation({
    required this.appliesTo,
    required this.policyTypes,
    required this.policyTypesDefaulted,
    required this.ingress,
    required this.egress,
  });

  String get text => '$appliesTo ${ingress.text} ${egress.text}';
}

/// Effective policyTypes: explicit if set, else Ingress plus Egress when
/// the spec has any egress rules (the API server's defaulting).
List<String> effectivePolicyTypes(Json spec) {
  final explicit = [for (final t in (spec['policyTypes'] as List? ?? const [])) '$t'];
  if (explicit.isNotEmpty) return explicit;
  return ['Ingress', if (asMapList(spec['egress']).isNotEmpty) 'Egress'];
}

/// "app=web and tier in (a, b)" for a LabelSelector; '' when empty.
String describeSelector(dynamic sel) {
  final s = asMap(sel);
  final parts = <String>[for (final e in asMap(s['matchLabels']).entries) '${e.key}=${e.value}'];
  for (final ex in asMapList(s['matchExpressions'])) {
    final values = [for (final v in (ex['values'] as List? ?? const [])) '$v'].join(', ');
    switch (ex['operator']) {
      case 'In':
        parts.add('${ex['key']} in ($values)');
      case 'NotIn':
        parts.add('${ex['key']} not in ($values)');
      case 'Exists':
        parts.add('label ${ex['key']}');
      case 'DoesNotExist':
        parts.add('no label ${ex['key']}');
    }
  }
  return parts.join(' and ');
}

String _describeNamespaces(Json sel) {
  final ml = asMap(sel['matchLabels']);
  if (asMapList(sel['matchExpressions']).isEmpty && ml.length == 1 && ml.containsKey('kubernetes.io/metadata.name')) {
    return 'namespace ${ml['kubernetes.io/metadata.name']}';
  }
  return 'namespaces with ${describeSelector(sel)}';
}

String describePeer(Json peer, {String? namespace}) {
  final ipBlock = asMap(peer['ipBlock']);
  if (ipBlock.isNotEmpty) {
    final except = [for (final e in (ipBlock['except'] as List? ?? const [])) '$e'];
    return 'IPs in ${ipBlock['cidr']}${except.isEmpty ? '' : ' except ${except.join(', ')}'}';
  }
  final hasPod = peer['podSelector'] is Map;
  final hasNs = peer['namespaceSelector'] is Map;
  final podSel = asMap(peer['podSelector']);
  final nsSel = asMap(peer['namespaceSelector']);
  final podPart = podSel.isEmpty ? 'any pod' : 'pods with ${describeSelector(podSel)}';
  final thisNs = namespace == null ? 'this namespace' : 'this namespace ($namespace)';
  if (hasPod && hasNs) {
    // Both in one peer: AND.
    return '$podPart in ${nsSel.isEmpty ? 'any namespace' : _describeNamespaces(nsSel)}';
  }
  if (hasNs) return 'any pod in ${nsSel.isEmpty ? 'any namespace' : _describeNamespaces(nsSel)}';
  if (hasPod) return '$podPart in $thisNs';
  return 'anywhere';
}

String describePort(Json p) {
  final proto = '${p['protocol'] ?? 'TCP'}';
  final port = p['port'];
  if (port == null) return 'all $proto ports';
  if (port is String && int.tryParse(port) == null) return '$proto port "$port"';
  final end = p['endPort'];
  return end != null ? '$proto $port-$end' : '$proto $port';
}

DirectionExplanation _direction(Json spec, String dir, List<String> types) {
  if (!types.contains(dir)) return DirectionExplanation(dir, PolicyMode.unrestricted, const []);
  final rulesKey = dir == 'Ingress' ? 'ingress' : 'egress';
  final peersKey = dir == 'Ingress' ? 'from' : 'to';
  final raw = asMapList(spec[rulesKey]);
  if (raw.isEmpty) return DirectionExplanation(dir, PolicyMode.denyAll, const []);
  final rules = [
    for (final r in raw)
      RuleExplanation(
        [for (final peer in asMapList(r[peersKey])) describePeer(peer)],
        [for (final p in asMapList(r['ports'])) describePort(p)],
      ),
  ];
  // A peer that describes to "anywhere" (e.g. `{}`) makes the rule's peer list unrestricted.
  final normalised = [
    for (final r in rules) r.peers.contains('anywhere') ? RuleExplanation(const [], r.ports) : r,
  ];
  if (normalised.any((r) => r.peers.isEmpty && r.ports.isEmpty)) return DirectionExplanation(dir, PolicyMode.allowAll, normalised);
  return DirectionExplanation(dir, PolicyMode.restricted, normalised);
}

/// Explain [policy] (a full NetworkPolicy object). [matchedPods] is the
/// number of pods its podSelector currently selects, when known.
NetpolExplanation explainNetworkPolicy(Json policy, {int? matchedPods}) {
  final spec = asMap(policy['spec']);
  final ns = dig<String>(policy, ['metadata', 'namespace']);
  final sel = describeSelector(spec['podSelector']);
  final where = ns == null ? '' : ' in $ns';
  final count = matchedPods == null ? '' : ' ($matchedPods pod${matchedPods == 1 ? '' : 's'})';
  final applies = sel.isEmpty ? 'Applies to all pods$where$count.' : 'Applies to pods matching $sel$where$count.';
  final types = effectivePolicyTypes(spec);
  return NetpolExplanation(
    appliesTo: applies,
    policyTypes: types,
    policyTypesDefaulted: (spec['policyTypes'] as List? ?? const []).isEmpty,
    ingress: _direction(spec, 'Ingress', types),
    egress: _direction(spec, 'Egress', types),
  );
}
