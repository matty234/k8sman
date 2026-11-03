import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/security/security_api.dart';
import 'package:k8sman/ui/security/security_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import '../support/screenshot.dart';

/// Real responses captured from the kind dev cluster with the Trivy Operator
/// installed and the deliberately insecure `security-demo` namespace applied
/// (dev/security-demo/insecure.yaml).
Json fixture(String name) => jsonDecode(File('test/security/fixtures/$name.json').readAsStringSync());

class FakeSecurityApi extends SecurityApi {
  Json response;
  Json scannerResponse;
  final List<(String?, bool)> calls = [];
  final List<String> scans = [];
  FakeSecurityApi(this.response, this.scannerResponse, ApiClient api) : super(api);

  @override
  Future<SecurityData> fetch({String? namespace, bool includeSystem = false}) async {
    calls.add((namespace, includeSystem));
    return SecurityData.fromJson(response);
  }

  @override
  Future<ScannerStatus> scanner() async => ScannerStatus.fromJson(scannerResponse);

  @override
  Future<ScanResult> scan(String image, {bool force = false}) async {
    scans.add(image);
    return ScanResult.fromJson({
      'image': image,
      'scannedAt': '2026-11-03T12:40:00Z',
      'counts': {'critical': 2, 'high': 4, 'fixableCritical': 1, 'fixableHigh': 3},
      'vulnerabilities': [
        {'id': 'CVE-2024-45491', 'severity': 'critical', 'package': 'libexpat1', 'installed': '2.5.0-1', 'fixed': '2.5.0-1+deb12u1', 'title': 'libexpat: Integer Overflow'},
      ],
      'total': 6,
    });
  }
}

const extraTypes = <ResourceType>[
  ResourceType(group: 'rbac.authorization.k8s.io', version: 'v1', resource: 'clusterrolebindings', kind: 'ClusterRoleBinding', namespaced: false),
  ResourceType(group: 'rbac.authorization.k8s.io', version: 'v1', resource: 'clusterroles', kind: 'ClusterRole', namespaced: false),
  ResourceType(group: 'rbac.authorization.k8s.io', version: 'v1', resource: 'rolebindings', kind: 'RoleBinding'),
  ResourceType(group: 'rbac.authorization.k8s.io', version: 'v1', resource: 'roles', kind: 'Role'),
  ResourceType(group: 'networking.k8s.io', version: 'v1', resource: 'networkpolicies', kind: 'NetworkPolicy'),
  ResourceType(group: 'networking.k8s.io', version: 'v1', resource: 'ingresses', kind: 'Ingress'),
];

Future<(AppState, FakeSecurityApi)> pumpSecurity(
  WidgetTester tester,
  Json response, {
  Json? scanner,
  Size size = const Size(1000, 900),
  String? namespace,
}) async {
  final client = FakeApiClient();
  final app = AppState(client)
    ..types = [...testTypes, ...extraTypes]
    ..currentContext = 'kind-k8sman-dev'
    ..namespace = namespace;
  final source = FakeSecurityApi(response, scanner ?? fixture('scanner'), client);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: SecurityView(source: source)),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (app, source);
}

Json scannerJson({bool operator = true, bool scanning = false, bool trivy = false}) => {
      'operator': {'installed': operator, 'reports': operator ? ['vulnerabilityreports'] : [], 'hasReports': operator && !scanning, 'scanning': operator && scanning},
      'trivy': trivy ? {'available': true, 'path': '/opt/homebrew/bin/trivy', 'version': '0.57.1'} : {'available': false, 'hint': 'Install trivy (`brew install trivy`) to scan images on demand.'},
      'installHint': 'Install trivy (`brew install trivy`) to scan images on demand.',
    };

/// The live fixture without any Trivy Operator data (as on a cluster without it).
Json withoutOperator() {
  final j = fixture('security-demo');
  j['sources'] = {'trivyOperator': false, 'reports': {}, 'gatewayAPI': false};
  for (final i in j['images'] as List) {
    (i as Map)['scanned'] = false;
    i['counts'] = {};
    i['topCVEs'] = [];
  }
  j['topCVEs'] = [];
  j['findings'] = [for (final f in j['findings'] as List) if ((f as Map)['category'] != 'images') f];
  for (final c in j['categories'] as List) {
    if ((c as Map)['id'] == 'images') {
      c['total'] = 0;
      c['counts'] = {};
    }
  }
  return j;
}

void main() {
  testWidgets('live fixture: summary, tiles, findings, tables', (tester) async {
    await loadRealFonts();
    final (_, source) = await pumpSecurity(tester, fixture('security'), size: const Size(1000, 3400));
    expect(source.calls, [(null, false)]);
    expect(find.text('Security'), findsOneWidget);
    expect(find.text('All namespaces'), findsOneWidget);
    for (final t in ['Network exposure', 'RBAC', 'Workload hardening', 'Images', 'Best practices']) {
      expect(find.text(t), findsWidgets, reason: t);
    }
    expect(find.textContaining('Unused ServiceAccount holds cluster-admin-equivalent access'), findsOneWidget);
    expect(find.text('Network exposure by namespace'), findsOneWidget);
    expect(find.text('Most permissive grants'), findsOneWidget);
    expect(find.text('Unused'), findsWidgets);
    expect(find.text('security-demo-overprivileged'), findsOneWidget);
    expect(find.textContaining('Trivy Operator '), findsOneWidget);
    expect(find.textContaining('brew install trivy'), findsOneWidget);
    await saveScreenshot(tester, 'security-live-1000');
  });

  testWidgets('wide screenshot with an expanded finding', (tester) async {
    await loadRealFonts();
    await pumpSecurity(tester, fixture('security-demo'), size: const Size(1500, 2200), namespace: 'security-demo');
    await tester.tap(find.textContaining('fails the baseline Pod Security profile'));
    await tester.pump();
    expect(find.textContaining('privileged (shell)'), findsWidgets);
    await saveScreenshot(tester, 'security-ns-1500');
  });

  testWidgets('tiles filter the list and the tables', (tester) async {
    await pumpSecurity(tester, fixture('security'), size: const Size(1000, 2400));
    await tester.tap(find.text('RBAC').first);
    await tester.pump();
    expect(find.text('Most permissive grants'), findsOneWidget);
    expect(find.text('Network exposure by namespace'), findsNothing);
    expect(find.textContaining('LoadBalancer Service'), findsNothing);
    expect(find.textContaining('RBAC · '), findsOneWidget); // filter chip
    // Clicking the tile again clears the filter.
    await tester.tap(find.text('RBAC').first);
    await tester.pump();
    expect(find.text('Network exposure by namespace'), findsOneWidget);
  });

  testWidgets('expanding a finding shows remediation and opens objects in the inspector', (tester) async {
    final (app, _) = await pumpSecurity(tester, fixture('security-demo'), size: const Size(1000, 1600), namespace: 'security-demo');
    await tester.tap(find.textContaining('LoadBalancer Service web-public'));
    await tester.pump();
    expect(find.textContaining('loadBalancerSourceRanges'), findsOneWidget);
    await tester.tap(find.text('web-public').first);
    expect(app.detail?.name, 'web-public');
    expect(app.detail?.type.kind, 'Service');
    expect(app.detail?.namespace, 'security-demo');
  });

  testWidgets('include system toggle refetches with includeSystem', (tester) async {
    final (_, source) = await pumpSecurity(tester, fixture('security-demo'), namespace: 'security-demo');
    await tester.tap(find.byType(Switch));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(source.calls.last, ('security-demo', true));
  });

  testWidgets('no operator: install button and the trivy CLI hint', (tester) async {
    await loadRealFonts();
    await pumpSecurity(tester, withoutOperator(), scanner: scannerJson(operator: false), size: const Size(1000, 1600), namespace: 'security-demo');
    await tester.tap(find.text('Images').first);
    await tester.pump();
    expect(find.text('Install Trivy Operator'), findsOneWidget);
    expect(find.textContaining('brew install trivy'), findsOneWidget);
    expect(find.text('not scanned'), findsWidgets);
    // Scan is disabled without the CLI.
    final scan = tester.widget<TextButton>(find.widgetWithText(TextButton, 'Scan').first);
    expect(scan.onPressed, isNull);
    await saveScreenshot(tester, 'security-no-scanner-1000');
    await tester.tap(find.text('Install Trivy Operator'));
    await tester.pumpAndSettle();
    expect(find.text('Install Trivy Operator?'), findsOneWidget);
  });

  testWidgets('operator installed but still scanning', (tester) async {
    await pumpSecurity(tester, withoutOperator(), scanner: scannerJson(scanning: true), namespace: 'security-demo');
    await tester.tap(find.text('Images').first);
    await tester.pump();
    expect(find.textContaining('Trivy Operator is scanning'), findsOneWidget);
    expect(find.text('Install Trivy Operator'), findsNothing);
  });

  testWidgets('on-demand scan with the local trivy', (tester) async {
    final (_, source) = await pumpSecurity(tester, withoutOperator(), scanner: scannerJson(operator: false, trivy: true), size: const Size(1000, 1400), namespace: 'security-demo');
    await tester.tap(find.text('Images').first);
    await tester.pump();
    expect(find.textContaining('Local trivy 0.57.1'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Scan').first);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(source.scans, hasLength(1));
    expect(find.text('scanned locally'), findsOneWidget);
    expect(find.widgetWithText(TextButton, 'Rescan'), findsOneWidget);
  });

  testWidgets('load error offers retry', (tester) async {
    final client = FakeApiClient();
    final app = AppState(client)..types = testTypes;
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(body: SecurityView(source: _FailingApi(client)))),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('forbidden'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
  });

  for (final width in [360.0, 500.0, 700.0, 900.0, 1200.0, 1500.0, 1800.0]) {
    testWidgets('no overflow at ${width.toInt()}px', (tester) async {
      await pumpSecurity(tester, fixture('security'), size: Size(width, 3000));
      // Expand the first few findings too.
      for (final f in find.byIcon(Icons.chevron_right).evaluate().take(4).toList()) {
        await tester.tap(find.byWidget(f.widget).first, warnIfMissed: false);
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Images').first);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }
}

class _FailingApi extends SecurityApi {
  _FailingApi(super.api);
  @override
  Future<SecurityData> fetch({String? namespace, bool includeSystem = false}) async => throw ApiException(403, 'pods is forbidden');
  @override
  Future<ScannerStatus> scanner() async => const ScannerStatus();
}
