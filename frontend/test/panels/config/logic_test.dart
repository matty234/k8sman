import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/config/rbac.dart';
import 'package:k8sman/panels/config/serviceaccount_panel.dart';
import 'package:k8sman/panels/config/usage.dart';
import 'package:k8sman/panels/config/values.dart';

import 'samples.dart';

Json fixture(String name) => jsonDecode(File('../dev/fixtures/$name.json').readAsStringSync()) as Json;
Json localFixture(String name) => jsonDecode(File('test/panels/config/fixtures/$name.json').readAsStringSync()) as Json;

void main() {
  group('findUsages', () {
    test('finds volume, env and envFrom refs to the ConfigMap in pod-web', () {
      final pod = fixture('pod-web');
      final u = findUsages([pod], kind: RefKind.configMap, name: 'web-config');
      expect(u, hasLength(1));
      final descs = u.single.usages.map((x) => x.description).toList();
      expect(descs, contains('volume conf → nginx:/etc/nginx/conf.d (keys: nginx.conf)'));
      expect(descs, contains('env APP_MODE ← key APP_MODE (container nginx)'));
      expect(descs, contains('envFrom → all keys as env (container nginx)'));
      expect(descs, hasLength(3));
    });

    test('finds projected ConfigMap sources (kube-root-ca.crt) in every container', () {
      final u = findUsages([fixture('pod-web')], kind: RefKind.configMap, name: 'kube-root-ca.crt');
      final usages = u.single.usages;
      expect(usages.every((x) => x.kind == UsageKind.projected), isTrue);
      expect(usages.map((x) => x.container).toSet(), {'init-wait', 'nginx', 'log-sidecar'});
      expect(usages.firstWhere((x) => x.container == 'init-wait').initContainer, isTrue);
      expect(usages.first.keys, ['ca.crt']);
    });

    test('finds secretKeyRef in pod-web and ignores other kinds', () {
      final u = findUsages([fixture('pod-web')], kind: RefKind.secret, name: 'web-secret');
      expect(u.single.usages.single.description, 'env API_TOKEN ← key API_TOKEN (container nginx)');
      expect(findUsages([fixture('pod-web')], kind: RefKind.secret, name: 'web-config'), isEmpty);
    });

    test('secret volumes, projected secrets, imagePullSecrets, optional and missing keys', () {
      final u = findUsages([richPod], kind: RefKind.secret, name: 'app-secret');
      final kinds = u.single.usages.map((x) => x.kind).toList();
      expect(kinds, containsAll([UsageKind.volume, UsageKind.projected, UsageKind.env, UsageKind.envFrom, UsageKind.imagePullSecret]));
      final env = u.single.usages.firstWhere((x) => x.kind == UsageKind.env && x.envName == 'OPT');
      expect(env.optional, isTrue);
      final missing = missingKeys(u, {'password', 'username'});
      expect(missing.map((m) => m.key), ['nope', 'token']);
      expect(missing.firstWhere((m) => m.key == 'nope').allOptional, isTrue);
      expect(missing.firstWhere((m) => m.key == 'token').allOptional, isFalse);
    });

    test('unmounted volume and namespace filter', () {
      final pod = {
        'metadata': {'name': 'p', 'namespace': 'a'},
        'spec': {
          'volumes': [
            {'name': 'v', 'configMap': {'name': 'cm'}}
          ],
          'containers': [
            {'name': 'c'}
          ],
        },
      };
      final u = findUsages([pod], kind: RefKind.configMap, name: 'cm');
      expect(u.single.usages.single.description, 'volume v (not mounted)');
      expect(findUsages([pod], kind: RefKind.configMap, name: 'cm', namespace: 'b'), isEmpty);
    });

    test('groups identical replicas', () {
      final a = fixture('pod-web');
      final b = jsonDecode(jsonEncode(a)) as Json;
      b['metadata']['name'] = 'web-other';
      final u = findUsages([a, b], kind: RefKind.configMap, name: 'web-config');
      expect(groupIdentical(u), hasLength(1));
    });
  });

  group('matchBindings', () {
    final rb = fixture('rolebinding-web-pod-reader');
    final crb = localFixture('crb-sa-issuer-discovery');

    test('direct RoleBinding and inherited group ClusterRoleBinding', () {
      final m = matchBindings(saName: 'web', saNamespace: 'demo', roleBindings: [rb], clusterRoleBindings: [crb]);
      expect(m, hasLength(2));
      expect(m[0].name, 'web-pod-reader');
      expect(m[0].inherited, isFalse);
      expect(m[0].roleRef.kind, 'Role');
      expect(m[0].roleRef.namespace, 'demo');
      expect(m[1].inherited, isTrue);
      expect(m[1].viaGroup, 'system:serviceaccounts');
      expect(m[1].cluster, isTrue);
      expect(m[1].roleRef.namespace, isNull);
    });

    test('other SA, namespace mismatch and User form', () {
      expect(matchBindings(saName: 'default', saNamespace: 'demo', roleBindings: [rb]), isEmpty);
      expect(matchBindings(saName: 'web', saNamespace: 'other', roleBindings: [rb]), isEmpty);
      final user = {
        'metadata': {'name': 'u'},
        'roleRef': {'kind': 'ClusterRole', 'name': 'view'},
        'subjects': [
          {'kind': 'User', 'name': 'system:serviceaccount:demo:web'}
        ],
      };
      final nsGroup = {
        'metadata': {'name': 'g', 'namespace': 'demo'},
        'roleRef': {'kind': 'ClusterRole', 'name': 'view'},
        'subjects': [
          {'kind': 'Group', 'name': 'system:serviceaccounts:demo'}
        ],
      };
      final otherNsGroup = {
        'metadata': {'name': 'g2'},
        'roleRef': {'kind': 'ClusterRole', 'name': 'view'},
        'subjects': [
          {'kind': 'Group', 'name': 'system:serviceaccounts:kube-system'}
        ],
      };
      final m = matchBindings(saName: 'web', saNamespace: 'demo', roleBindings: [nsGroup], clusterRoleBindings: [user, otherNsGroup]);
      expect(m.map((x) => x.name), ['u', 'g']);
      expect(m[0].inherited, isFalse);
      expect(m[1].viaGroup, 'system:serviceaccounts:demo');
      expect(m[1].scope, 'namespace demo');
    });

    test('RoleBinding SA subject without namespace defaults to the binding namespace', () {
      final b = {
        'metadata': {'name': 'x', 'namespace': 'demo'},
        'roleRef': {'kind': 'Role', 'name': 'r'},
        'subjects': [
          {'kind': 'ServiceAccount', 'name': 'web'}
        ],
      };
      expect(matchBindings(saName: 'web', saNamespace: 'demo', roleBindings: [b]), hasLength(1));
    });
  });

  test('summarizeRules', () {
    final s = summarizeRules([
      ...(fixture('role-pod-reader')['rules'] as List).cast<Json>(),
      {
        'apiGroups': ['apps'],
        'resources': ['deployments'],
        'resourceNames': ['web'],
        'verbs': ['get', 'list', 'watch'],
      },
      {
        'nonResourceURLs': ['/healthz'],
        'verbs': ['get'],
      },
      {
        'apiGroups': ['*'],
        'resources': ['*'],
        'verbs': ['*'],
      },
    ]);
    expect(s.map((r) => r.toString()), [
      'get, list, watch → pods, pods/log, deployments.apps[web]',
      'get → /healthz',
      '* → *.*',
    ]);
    expect(s.last.wildcard, isTrue);
    expect(s.first.wildcard, isFalse);
  });

  test('podsUsingServiceAccount', () {
    final pod = fixture('pod-web');
    expect(podsUsingServiceAccount([pod], 'web'), hasLength(1));
    expect(podsUsingServiceAccount([pod], 'default'), isEmpty);
  });

  group('values', () {
    test('detectFormat', () {
      expect(detectFormat('{"a": 1}'), ValueFormat.json);
      expect(detectFormat('[1,2]'), ValueFormat.json);
      expect(detectFormat('a:\n  b: 1\n  c: [x]\n'), ValueFormat.yaml);
      expect(detectFormat('key: value'), ValueFormat.yaml);
      expect(detectFormat('# c\na.b=1\nc = 2\n'), ValueFormat.properties);
      expect(detectFormat('#!/bin/sh\necho hi\n'), ValueFormat.shell);
      expect(detectFormat('export FOO=bar\n'), ValueFormat.shell);
      expect(detectFormat('production'), ValueFormat.plain);
      expect(detectFormat("server { listen 8080; location / { return 200 'ok'; } }\n"), ValueFormat.plain);
      expect(detectFormat('{not json'), ValueFormat.plain);
    });

    test('prettyValue, lineCount and sizes', () {
      expect(prettyValue('{"a":1}', ValueFormat.json), '{\n  "a": 1\n}');
      expect(lineCount('a\nb\n'), 2);
      expect(lineCount('a\nb'), 2);
      expect(lineCount(''), 0);
      expect(utf8Size('é'), 2);
    });

    test('reveal decodes base64 text and flags binary', () {
      final secret = fixture('secret-web-secret');
      expect(decodeSecretValue(secret['data']['DB_PASSWORD'])!.text, 'hunter2');
      expect(decodeSecretValue(secret['data']['API_TOKEN'])!.text, 's3cr3t-token');
      final bin = decodeSecretValue(base64.encode([0xff, 0x00, 0xd8, 0x10]))!;
      expect(bin.isBinary, isTrue);
      expect(bin.length, 4);
      expect(hexPreview(bin.bytes), 'ff 00 d8 10');
      expect(decodeSecretValue('***'), isNull);
    });

    test('pem and docker config', () {
      expect(pemBlocks(fakeChain), {'CERTIFICATE': 2});
      expect(describePem({'CERTIFICATE': 2, 'PRIVATE KEY': 1}), 'CERTIFICATE ×2, PRIVATE KEY');
      final regs = parseDockerConfig(utf8.decode(base64.decode(dockerSecret['data']['.dockerconfigjson'])))!;
      expect(regs.map((r) => r.registry), ['ghcr.io', 'registry.example.com']);
      expect(regs[0].username, 'octo');
      expect(regs[0].password, 'ghp_dummy');
      expect(regs[1].username, 'robot');
      expect(regs[1].password, 'pw-from-auth');
    });

    test('secret type explanations', () {
      for (final t in ['Opaque', 'kubernetes.io/tls', 'kubernetes.io/dockerconfigjson', 'kubernetes.io/service-account-token', 'kubernetes.io/basic-auth', 'kubernetes.io/ssh-auth', 'bootstrap.kubernetes.io/token']) {
        expect(secretTypeExplanation(t), isNot('Custom secret type.'));
      }
    });
  });
}
