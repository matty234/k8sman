import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/config/rbac.dart';
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

  });

  test('buildUsageReport groups by Deployment and counts 0-replica templates', () {
    Json pod(Json spec) => {
          'metadata': {'name': 'web-abc-1', 'namespace': 'ns', 'ownerReferences': [{'kind': 'ReplicaSet', 'name': 'web-abc', 'apiVersion': 'apps/v1', 'controller': true}]},
          'spec': spec,
        };
    final rs = {'metadata': {'name': 'web-abc', 'ownerReferences': [{'kind': 'Deployment', 'name': 'web', 'apiVersion': 'apps/v1', 'controller': true}]}};
    final cm = buildUsageReport(
      pods: [pod({'containers': [{'name': 'c', 'envFrom': [{'configMapRef': {'name': 'cfg'}}], 'volumeMounts': [{'name': 'v', 'mountPath': '/etc/x'}]}], 'volumes': [{'name': 'v', 'projected': {'sources': [{'configMap': {'name': 'cfg'}}]}}]})],
      replicaSets: [rs],
      templates: {'StatefulSet': [{'metadata': {'name': 'idle'}, 'spec': {'replicas': 0, 'template': {'spec': {'containers': [{'name': 'c', 'envFrom': [{'configMapRef': {'name': 'cfg'}}]}]}}}}]},
      kind: RefKind.configMap,
      name: 'cfg',
      namespace: 'ns',
    );
    expect(cm.workloads.map((w) => '${w.ref.kind}/${w.ref.name}:${w.pods.length}'), ['Deployment/web:1', 'StatefulSet/idle:0']);
    expect(cm.standalone, isEmpty);
    expect(cm.pods.single.usages.map((u) => u.kind), containsAll([UsageKind.envFrom, UsageKind.projected]));
    final sec = buildUsageReport(
      pods: [{'metadata': {'name': 'p', 'namespace': 'ns'}, 'spec': {'imagePullSecrets': [{'name': 'reg'}], 'containers': []}}],
      replicaSets: [],
      templates: {},
      kind: RefKind.secret,
      name: 'reg',
      namespace: 'ns',
    );
    expect(sec.standalone.single.usages.single.kind, UsageKind.imagePullSecret);
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

  });
}
