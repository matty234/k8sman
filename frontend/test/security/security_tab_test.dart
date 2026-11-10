import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/panels/registry.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/inspector/inspector.dart';
import 'package:k8sman/ui/security/security_api.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/util/k8s.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';

class _FakeSecurityApi extends SecurityApi {
  _FakeSecurityApi(super.api);

  @override
  Future<ObjectSecurity> forObject({required String namespace, required String kind, required String name, String group = ''}) async =>
      ObjectSecurity.fromJson({
        'object': {'kind': kind, 'name': name, 'namespace': namespace},
        'target': {'group': 'apps', 'kind': 'Deployment', 'name': 'web', 'namespace': 'default'},
        'findings': [
          {
            'id': 'workloads.pss-baseline/default/apps/Deployment/web',
            'check': 'workloads.pss-baseline',
            'severity': 'critical',
            'category': 'workloads',
            'title': 'Deployment web fails the baseline Pod Security profile',
            'remediation': 'Remove privileged mode.',
            'namespace': 'default',
            'objects': [{'group': 'apps', 'kind': 'Deployment', 'name': 'web', 'namespace': 'default'}],
          },
        ],
        'images': [
          {
            'container': 'app',
            'image': 'example/app:1.0',
            'scanned': true,
            'source': 'trivy-operator',
            'counts': {'critical': 1, 'high': 6, 'fixableCritical': 1},
            'cves': [
              {'id': 'CVE-2024-0001', 'severity': 'critical', 'package': 'openssl', 'installed': '3.0.1', 'fixed': '3.0.14', 'link': 'https://example.com/CVE-2024-0001'},
              for (var i = 2; i <= 7; i++) {'id': 'CVE-2024-000$i', 'severity': 'high', 'package': 'libc', 'installed': '2.36'},
            ],
            'report': {'group': 'aquasecurity.github.io', 'kind': 'VulnerabilityReport', 'name': 'replicaset-web-1-app', 'namespace': 'default'},
          },
        ],
        'trivyOperator': true,
      });
}

void main() {
  testWidgets('Security tab: inherited findings, image CVEs, security context and a red count badge', (tester) async {
    securityApiFor = _FakeSecurityApi.new;
    addTearDown(() => securityApiFor = SecurityApi.new);
    SectionMemory.reset();
    final pod = <String, dynamic>{
      'apiVersion': 'v1',
      'kind': 'Pod',
      'metadata': {
        'name': 'web-1-abc',
        'namespace': 'default',
        'uid': 'uid-web',
        'ownerReferences': [{'apiVersion': 'apps/v1', 'kind': 'ReplicaSet', 'name': 'web-1', 'controller': true}],
      },
      'spec': {
        'securityContext': {'runAsNonRoot': true},
        'containers': [
          {'name': 'app', 'image': 'example/app:1.0', 'securityContext': {'privileged': true}},
        ],
      },
    };
    final client = FakeApiClient();
    final app = AppState(client)..types = testTypes;
    final t = testType('', 'Pod');
    final ctx = PanelContext(object: pod, type: t, api: client, app: app);
    final tab = panelFor(t).tabs(ctx).singleWhere((x) => x.label == 'Security');
    tester.view.physicalSize = const Size(700, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (c) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Row(children: [const Text('Security'), tab.badge!(c, ctx)]),
              Expanded(child: tab.builder(c, ctx)),
            ]),
          ),
        ),
      ),
    ));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();

    // Findings live on the Deployment.
    expect(find.text('Deployment/web'), findsOneWidget);
    expect(find.text('Deployment web fails the baseline Pod Security profile'), findsOneWidget);
    // Counts, the top five CVEs, then all of them.
    expect(find.text('1 critical'), findsWidgets);
    expect(find.textContaining('CVE-2024-0001', findRichText: true), findsOneWidget);
    expect(find.textContaining('CVE-2024-0007', findRichText: true), findsNothing);
    await tester.tap(find.text('Show all 7'));
    await tester.pump();
    expect(find.textContaining('CVE-2024-0007', findRichText: true), findsOneWidget);
    // Effective security context: privileged flagged, runAsNonRoot from the pod.
    expect(find.text('Privileged'), findsOneWidget);
    expect(find.text('yes'), findsWidgets);
    // Badge: 1 finding + 1 critical + 6 high, in the critical colour.
    final badge = tester.widget<Text>(find.descendant(of: find.byKey(const ValueKey('security-badge')), matching: find.byType(Text)));
    expect(badge.data, '8');
    expect(badge.style?.color, severityColor(tester.element(find.byKey(const ValueKey('security-badge'))), Severity.error));
  });
}
