import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/ui/inspector/inspector.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';
import 'samples.dart';

Json fixture(String name) => jsonDecode(File('../dev/fixtures/$name.json').readAsStringSync()) as Json;
Json localFixture(String name) => jsonDecode(File('test/panels/config/fixtures/$name.json').readAsStringSync()) as Json;

FakeApiClient podsApi(List<Json> pods) => FakeApiClient(itemsByResource: {'pods': pods});

Future<void> openSection(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('pod-section-$id')));
  await tester.pump();
}

void main() {
  setUpAll(loadRealFonts);
  setUp(SectionMemory.reset);

  testWidgets('ConfigMap: data entries and used-by from the web pod', (tester) async {
    final app = await pumpPanel(tester, fixture('cm-web-config'), api: podsApi([fixture('pod-web')]));
    expect(find.text('APP_MODE'), findsWidgets);
    expect(find.text('nginx.conf'), findsWidgets);
    expect(find.text('pod uses it'), findsOneWidget);
    expect(find.text('1 workload · 1 pod'), findsOneWidget);
    expect(find.textContaining('/etc/nginx/conf.d', findRichText: true), findsOneWidget);
    expect(find.textContaining('env APP_MODE ← key APP_MODE', findRichText: true), findsOneWidget);

    await tester.tap(find.text('web-6fd47b8fcb-4v4m9'));
    await tester.pump();
    expect(app.detail?.type.kind, 'Pod');
    expect(app.detail?.name, 'web-6fd47b8fcb-4v4m9');
  });

  testWidgets('Secret: masked by default, reveal decodes, reveal all', (tester) async {
    await pumpPanel(tester, fixture('secret-web-secret'), api: podsApi([fixture('pod-web')]));
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

    await tester.tap(find.text('Hide all'));
    await tester.pump();
    expect(find.text('hunter2'), findsNothing);
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
    expect(find.text('web-6fd47b8fcb-4v4m9'), findsOneWidget);
    expect(find.text('api-7d9f-abcde'), findsNothing); // runs as default
    expect(find.text('2 grants · 2 bindings'), findsOneWidget); // the collapsed summary
    await openSection(tester, 'sa-permissions');
    // "Can do": merged rows per target, neutral verbs.
    expect(find.text('Can do'), findsOneWidget);
    expect(find.text('pods'), findsOneWidget);
    expect(find.text('pods/log'), findsOneWidget);
    expect(find.text('get · list · watch'), findsNWidgets(2));
    // "Granted by": role link + binding link, provenance muted.
    expect(find.text('pod-reader'), findsOneWidget);
    expect(find.text('web-pod-reader'), findsOneWidget);
    expect(find.textContaining('dangling binding'), findsOneWidget);
    // The built-in issuer-discovery binding is folded into "Default access".
    expect(find.text('Default access'), findsOneWidget);
    expect(find.textContaining('/openid/v1/jwks'), findsNothing);
    await tester.tap(find.text('Default access'));
    await tester.pump();
    expect(find.textContaining('/openid/v1/jwks'), findsOneWidget);

    await tester.tap(find.text('pod-reader'));
    await tester.pump();
    expect(app.detail?.type.kind, 'Role');
    expect(app.detail?.namespace, 'demo');
  });

}
