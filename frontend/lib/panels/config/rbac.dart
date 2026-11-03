/// Pure helpers for matching RBAC bindings to a ServiceAccount and
/// summarising role rules.
library;

import '../../api/models.dart';
import '../../util/k8s.dart';

const rbacGroup = 'rbac.authorization.k8s.io';

/// A binding that grants something to the ServiceAccount.
class BindingMatch {
  final Json binding;

  /// True for ClusterRoleBindings.
  final bool cluster;

  /// The group subject through which the SA inherits this binding, or null
  /// when the SA is named directly.
  final String? viaGroup;

  const BindingMatch(this.binding, {required this.cluster, this.viaGroup});

  bool get inherited => viaGroup != null;
  String get name => dig<String>(binding, ['metadata', 'name']) ?? '';
  String? get namespace => dig<String>(binding, ['metadata', 'namespace']);
  String get roleKind => dig<String>(binding, ['roleRef', 'kind']) ?? 'ClusterRole';
  String get roleName => dig<String>(binding, ['roleRef', 'name']) ?? '';

  ObjectRef get bindingRef => ObjectRef(group: rbacGroup, kind: cluster ? 'ClusterRoleBinding' : 'RoleBinding', name: name, namespace: cluster ? null : namespace);

  /// A Role is resolved in the binding's namespace; a ClusterRole is global.
  ObjectRef get roleRef => ObjectRef(group: rbacGroup, kind: roleKind, name: roleName, namespace: roleKind == 'Role' ? namespace : null);

  /// Where the granted permissions apply.
  String get scope => cluster ? 'cluster-wide' : 'namespace ${namespace ?? '?'}';
}

/// Group subjects every ServiceAccount in [namespace] belongs to.
List<String> serviceAccountGroups(String namespace) =>
    ['system:serviceaccounts', 'system:serviceaccounts:$namespace', 'system:authenticated'];

/// Finds bindings whose subjects include the ServiceAccount
/// [saNamespace]/[saName], directly (kind ServiceAccount, or the
/// equivalent `system:serviceaccount:<ns>:<name>` User) or via one of its
/// implicit groups. Direct matches are listed first.
List<BindingMatch> matchBindings({
  required String saName,
  required String saNamespace,
  List<Json> roleBindings = const [],
  List<Json> clusterRoleBindings = const [],
}) {
  final groups = serviceAccountGroups(saNamespace);
  final userName = 'system:serviceaccount:$saNamespace:$saName';
  final direct = <BindingMatch>[];
  final inherited = <BindingMatch>[];

  void scan(Json b, bool cluster) {
    final bns = dig<String>(b, ['metadata', 'namespace']);
    // A RoleBinding only grants within its own namespace; one in another
    // namespace can still name this SA, which is legitimate and shown.
    String? via;
    var isDirect = false;
    for (final s in asMapList(b['subjects'])) {
      final kind = s['kind'];
      final name = s['name'];
      if (kind == 'ServiceAccount') {
        final ns = s['namespace'] ?? (cluster ? null : bns);
        if (name == saName && ns == saNamespace) isDirect = true;
      } else if (kind == 'User' && name == userName) {
        isDirect = true;
      } else if (kind == 'Group' && groups.contains(name)) {
        via ??= name as String;
      }
    }
    if (isDirect) {
      direct.add(BindingMatch(b, cluster: cluster));
    } else if (via != null) {
      inherited.add(BindingMatch(b, cluster: cluster, viaGroup: via));
    }
  }

  for (final b in roleBindings) {
    scan(b, false);
  }
  for (final b in clusterRoleBindings) {
    scan(b, true);
  }
  int byName(BindingMatch a, BindingMatch b) {
    if (a.cluster != b.cluster) return a.cluster ? 1 : -1;
    return a.name.compareTo(b.name);
  }

  return [...direct..sort(byName), ...inherited..sort(byName)];
}

/// One compact rule line: `verbs` × `targets`.
class RuleSummary {
  final String verbs;
  final String targets;
  final bool wildcard;
  const RuleSummary(this.verbs, this.targets, {this.wildcard = false});
  @override
  String toString() => '$verbs → $targets';
}

List<String> _strings(dynamic v) => v is List ? [for (final e in v) '$e'] : const [];

/// Summarises role rules. Rules with identical verbs are merged.
List<RuleSummary> summarizeRules(List<Json> rules) {
  final byVerbs = <String, List<String>>{};
  final wild = <String, bool>{};
  for (final r in rules) {
    final verbsList = _strings(r['verbs']);
    final verbs = verbsList.contains('*') ? '*' : verbsList.join(', ');
    final groups = _strings(r['apiGroups']);
    final names = _strings(r['resourceNames']);
    final targets = <String>[];
    for (final res in _strings(r['resources'])) {
      for (final g in groups.isEmpty ? [''] : groups) {
        final qualified = g.isEmpty ? res : '$res.$g';
        targets.add(names.isEmpty ? qualified : '$qualified[${names.join(',')}]');
      }
    }
    for (final u in _strings(r['nonResourceURLs'])) {
      targets.add(u);
    }
    if (targets.isEmpty) continue;
    final list = byVerbs[verbs] ??= [];
    for (final t in targets) {
      if (!list.contains(t)) list.add(t);
    }
    if (verbs == '*' || targets.any((t) => t.startsWith('*'))) wild[verbs] = true;
  }
  return [for (final e in byVerbs.entries) RuleSummary(e.key, e.value.join(', '), wildcard: wild[e.key] ?? false)];
}
