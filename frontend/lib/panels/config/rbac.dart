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

/// True for the built-in bindings every authenticated identity (or every
/// ServiceAccount) inherits: `system:basic-user`, `system:discovery`, etc.
/// These are noise when asking "what can this ServiceAccount do?".
bool isDefaultBinding(BindingMatch m) =>
    m.inherited &&
    m.cluster &&
    m.name.startsWith('system:') &&
    const {'system:authenticated', 'system:serviceaccounts', 'system:unauthenticated'}.contains(m.viaGroup);

/// How risky a set of verbs on a target is, for restrained colouring.
enum PermissionRisk { read, write, high }

const _readVerbs = {'get', 'list', 'watch'};

PermissionRisk permissionRisk(String target, Set<String> verbs) {
  final t = target.toLowerCase();
  if (verbs.contains('*') || t.startsWith('*') || verbs.any(const {'escalate', 'bind', 'impersonate'}.contains)) return PermissionRisk.high;
  if (t.startsWith('secrets') && verbs.any(const {'get', 'list', 'watch'}.contains)) return PermissionRisk.high;
  if (t.startsWith('pods/exec') || t.startsWith('pods/attach')) return PermissionRisk.high;
  if (verbs.any((v) => !_readVerbs.contains(v))) return PermissionRisk.write;
  return PermissionRisk.read;
}

/// One row of the merged "what can it do" view.
class EffectivePermission {
  /// `resource.group[names]` or a non-resource URL.
  final String target;
  final Set<String> verbs;

  /// Human scopes, e.g. `cluster-wide`, `namespace demo`.
  final Set<String> scopes;

  /// `Kind/name` of the roles granting it.
  final Set<String> grantedBy;
  EffectivePermission(this.target) : verbs = {}, scopes = {}, grantedBy = {};

  bool get nonResource => target.startsWith('/');
  PermissionRisk get risk => permissionRisk(target, verbs);

  /// Verbs in a stable, conventional order.
  List<String> get sortedVerbs {
    const order = ['*', 'get', 'list', 'watch', 'create', 'update', 'patch', 'delete', 'deletecollection'];
    final v = verbs.toList()
      ..sort((a, b) {
        final ia = order.indexOf(a), ib = order.indexOf(b);
        if (ia != -1 || ib != -1) return (ia == -1 ? 99 : ia).compareTo(ib == -1 ? 99 : ib);
        return a.compareTo(b);
      });
    return v;
  }
}

/// Merges the rules of every (binding, role) pair into one row per target.
/// Rows are ordered: highest risk first, then resources before URLs, then name.
List<EffectivePermission> effectivePermissions(List<(BindingMatch, Json)> granted) {
  final byTarget = <String, EffectivePermission>{};
  for (final (m, role) in granted) {
    for (final r in asMapList(role['rules'])) {
      final verbs = _strings(r['verbs']).toSet();
      final groups = _strings(r['apiGroups']);
      final names = _strings(r['resourceNames']);
      final targets = <String>[
        for (final res in _strings(r['resources']))
          for (final g in groups.isEmpty ? [''] : groups)
            () {
              final q = g.isEmpty || g == '*' && res == '*' ? res : '$res.$g';
              return names.isEmpty ? q : '$q[${names.join(',')}]';
            }(),
        ..._strings(r['nonResourceURLs']),
      ];
      for (final t in targets) {
        final p = byTarget.putIfAbsent(t, () => EffectivePermission(t));
        p.verbs.addAll(verbs);
        p.scopes.add(m.scope);
        p.grantedBy.add('${m.roleKind}/${m.roleName}');
      }
    }
  }
  final out = byTarget.values.toList()
    ..sort((a, b) {
      final r = b.risk.index.compareTo(a.risk.index);
      if (r != 0) return r;
      if (a.nonResource != b.nonResource) return a.nonResource ? 1 : -1;
      return a.target.compareTo(b.target);
    });
  return out;
}
