import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';
import 'samples.dart';

Json fixture(String name) => jsonDecode(File('../dev/fixtures/$name.json').readAsStringSync()) as Json;
Json localFixture(String name) => jsonDecode(File('test/panels/config/fixtures/$name.json').readAsStringSync()) as Json;

FakeApiClient podsApi(List<Json> pods) => FakeApiClient(itemsByResource: {'pods': pods});

void main() {
  setUpAll(loadRealFonts);

  testWidgets('ConfigMap: data entries and used-by from the web pod', (tester) async {
    final app = await pumpPanel(tester, fixture('cm-web-config'), api: podsApi([fixture('pod-web')]));
    await saveScreenshot(tester, 'config-cm-web');
    expect(find.text('APP_MODE'), findsWidgets);
    expect(find.text('nginx.conf'), findsWidgets);
    expect(find.text('1 pod'), findsOneWidget);
    expect(find.textContaining('/etc/nginx/conf.d', findRichText: true), findsOneWidget);
    expect(find.textContaining('env APP_MODE ← key APP_MODE', findRichText: true), findsOneWidget);

    await tester.tap(find.text('web-6fd47b8fcb-4v4m9'));
    await tester.pump();
    expect(app.detail?.type.kind, 'Pod');
    expect(app.detail?.name, 'web-6fd47b8fcb-4v4m9');
  });

  testWidgets('ConfigMap: formats, long values, binaryData and missing keys', (tester) async {
    await pumpPanel(tester, richConfigMap, api: podsApi([richPod]), size: const Size(560, 3000));
    await saveScreenshot(tester, 'config-cm-rich');
    for (final f in ['json', 'yaml', 'properties', 'shell', 'plain']) {
      expect(find.text(f), findsWidgets, reason: f);
    }
    expect(find.text('immutable'), findsOneWidget);
    expect(find.text('16 B'), findsOneWidget); // binaryData size
    expect(find.text('Show all 80 lines'), findsOneWidget);
    expect(find.textContaining('"port": 8080'), findsOneWidget); // pretty-printed
    expect(find.text('1 missing key'), findsOneWidget); // FEATURE_X (optional)
    await tester.tap(find.text('Show all 80 lines'));
    await tester.pumpAndSettle();
    expect(find.text('Show less'), findsOneWidget);
  });

  testWidgets('Secret: masked by default, reveal decodes, reveal all', (tester) async {
    await pumpPanel(tester, fixture('secret-web-secret'), api: podsApi([fixture('pod-web')]));
    await saveScreenshot(tester, 'config-secret-masked');
    expect(find.text('hunter2'), findsNothing);
    expect(find.text('s3cr3t-token'), findsNothing);
    expect(find.textContaining('Arbitrary user-defined'), findsOneWidget);
    expect(find.textContaining('env API_TOKEN ← key API_TOKEN', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('Reveal').last); // DB_PASSWORD (sorted second)
    await tester.pump();
    expect(find.text('hunter2'), findsOneWidget);
    expect(find.text('s3cr3t-token'), findsNothing);

    await tester.tap(find.text('Reveal all'));
    await tester.pump();
    expect(find.text('hunter2'), findsOneWidget);
    expect(find.text('s3cr3t-token'), findsOneWidget);
    await saveScreenshot(tester, 'config-secret-revealed');

    await tester.tap(find.text('Hide all'));
    await tester.pump();
    expect(find.text('hunter2'), findsNothing);
  });

  testWidgets('Secret: TLS shows PEM blocks', (tester) async {
    await pumpPanel(tester, tlsSecret, api: podsApi([]));
    await saveScreenshot(tester, 'config-secret-tls');
    expect(find.textContaining('CERTIFICATE ×2'), findsOneWidget);
    expect(find.text('PRIVATE KEY'), findsOneWidget);
    expect(find.text('not present'), findsOneWidget);
  });

  testWidgets('Secret: dockerconfigjson lists registries, passwords masked', (tester) async {
    await pumpPanel(tester, dockerSecret, api: podsApi([]));
    await saveScreenshot(tester, 'config-secret-docker');
    expect(find.text('ghcr.io'), findsOneWidget);
    expect(find.text('robot'), findsOneWidget);
    expect(find.text('ghp_dummy'), findsNothing);
    await tester.tap(find.text('Reveal all'));
    await tester.pump();
    expect(find.text('ghp_dummy'), findsOneWidget);
  });

  testWidgets('Secret: service-account-token links SA; binary reveal', (tester) async {
    final app = await pumpPanel(tester, saTokenSecret, api: podsApi([]));
    await tester.tap(find.text('Reveal all'));
    await tester.pump();
    await saveScreenshot(tester, 'config-secret-satoken');
    expect(find.text('binary · 5 bytes'), findsOneWidget);
    expect(find.textContaining('ff fe 00 01 02'), findsOneWidget);
    await tester.tap(find.text('web'));
    await tester.pump();
    expect(app.detail?.type.kind, 'ServiceAccount');
  });

  testWidgets('ServiceAccount: used-by and permissions', (tester) async {
    final api = FakeApiClient(
      itemsByResource: {
        'pods': [fixture('pod-web'), richPod],
        'rolebindings.rbac.authorization.k8s.io': [fixture('rolebinding-web-pod-reader')],
        'clusterrolebindings.rbac.authorization.k8s.io': [
          localFixture('crb-sa-issuer-discovery'),
          {
            'metadata': {'name': 'dangling'},
            'roleRef': {'kind': 'ClusterRole', 'name': 'gone'},
            'subjects': [
              {'kind': 'ServiceAccount', 'name': 'web', 'namespace': 'demo'}
            ],
          },
        ],
      },
      objects: {
        'roles.rbac.authorization.k8s.io/demo/pod-reader': fixture('role-pod-reader'),
        'clusterroles.rbac.authorization.k8s.io//system:service-account-issuer-discovery': localFixture('clusterrole-sa-issuer-discovery'),
      },
    );
    final app = await pumpPanel(tester, fixture('sa-web'), api: api);
    await saveScreenshot(tester, 'config-sa-web');
    expect(find.text('web-6fd47b8fcb-4v4m9'), findsOneWidget);
    expect(find.text('api-7d9f-abcde'), findsNothing); // runs as default
    expect(find.text('RoleBinding/web-pod-reader'), findsOneWidget);
    expect(find.text('Role/pod-reader'), findsOneWidget);
    expect(find.text('pods, pods/log'), findsOneWidget);
    expect(find.text('via system:serviceaccounts'), findsOneWidget);
    expect(find.textContaining('dangling binding'), findsOneWidget);
    expect(find.text('2 direct · 1 inherited'), findsOneWidget);

    await tester.tap(find.text('Role/pod-reader'));
    await tester.pump();
    expect(app.detail?.type.kind, 'Role');
    expect(app.detail?.namespace, 'demo');
  });
}
