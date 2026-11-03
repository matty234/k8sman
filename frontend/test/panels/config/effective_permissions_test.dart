import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/panels/config/rbac.dart';

void main() {
  BindingMatch crb(String name, {String? via}) => BindingMatch({
        'metadata': {'name': name},
        'roleRef': {'kind': 'ClusterRole', 'name': name},
      }, cluster: true, viaGroup: via);
  BindingMatch rb(String name, String ns) => BindingMatch({
        'metadata': {'name': name, 'namespace': ns},
        'roleRef': {'kind': 'Role', 'name': name},
      }, cluster: false);

  test('default system bindings are recognised', () {
    expect(isDefaultBinding(crb('system:discovery', via: 'system:authenticated')), isTrue);
    expect(isDefaultBinding(crb('system:service-account-issuer-discovery', via: 'system:serviceaccounts')), isTrue);
    expect(isDefaultBinding(crb('system:discovery')), isFalse, reason: 'direct binding is not a default');
    expect(isDefaultBinding(crb('my-team', via: 'system:authenticated')), isFalse);
    expect(isDefaultBinding(crb('system:foo', via: 'system:serviceaccounts:demo')), isFalse, reason: 'namespace-specific group is deliberate');
  });

  test('effective permissions merge verbs and scopes per target, risky first', () {
    final perms = effectivePermissions([
      (rb('pod-reader', 'demo'), {
        'rules': [
          {'apiGroups': [''], 'resources': ['pods', 'pods/log'], 'verbs': ['get', 'list']},
        ]
      }),
      (crb('watcher'), {
        'rules': [
          {'apiGroups': [''], 'resources': ['pods'], 'verbs': ['watch']},
          {'apiGroups': [''], 'resources': ['secrets'], 'verbs': ['get']},
          {'apiGroups': ['apps'], 'resources': ['deployments'], 'verbs': ['patch']},
          {'nonResourceURLs': ['/healthz'], 'verbs': ['get']},
        ]
      }),
    ]);
    expect(perms.map((p) => p.target).toList(), ['secrets', 'deployments.apps', 'pods', 'pods/log', '/healthz']);
    final pods = perms.firstWhere((p) => p.target == 'pods');
    expect(pods.sortedVerbs, ['get', 'list', 'watch']);
    expect(pods.scopes, {'namespace demo', 'cluster-wide'});
    expect(pods.grantedBy, {'Role/pod-reader', 'ClusterRole/watcher'});
    expect(perms.first.risk, PermissionRisk.high);
    expect(perms[1].risk, PermissionRisk.write);
    expect(pods.risk, PermissionRisk.read);
  });
}
