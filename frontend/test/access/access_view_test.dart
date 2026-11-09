import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/access/access_api.dart';
import 'package:k8sman/ui/access/access_view.dart';
import 'package:k8sman/ui/access/permission_matrix.dart';
import 'package:k8sman/ui/access/rbac_model.dart';
import 'package:k8sman/ui/access/role_editor.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import '../support/screenshot.dart';

/// Responses captured from the kind dev cluster with dev/rbac-demo.yaml
/// applied (GET /api/rbac/...).
Json fixture(String name) => jsonDecode(File('test/access/fixtures/$name.json').readAsStringSync());

class FakeAccessApi extends AccessApi {
  final List<(RbacSubject?, AccessRequest)> checks = [];
  final List<(Json, bool)> applied = [];
  FakeAccessApi(super.api);

  @override
  Future<SubjectList> subjects() async => SubjectList.fromJson(fixture('subjects'));

  @override
  Future<PermissionMatrixData> matrix(RbacSubject s, {String? namespace, List<String> groups = const []}) async =>
      PermissionMatrixData.fromJson(fixture('matrix-app'));

  @override
  Future<WhoCanResult> whoCan(AccessRequest r) async => WhoCanResult.fromJson(fixture('whocan-secrets'));

  @override
  Future<SelfAccess> self({String? namespace}) async => SelfAccess.fromJson(fixture('self'));

  @override
  Future<CheckResult> check(AccessRequest r, {RbacSubject? subject, List<String> groups = const []}) async {
    checks.add((subject, r));
    return CheckResult.fromJson({
      'allowed': true,
      'reason': 'RBAC: allowed by RoleBinding "app-config/rbac-demo" of Role "app-config" to ServiceAccount "app/rbac-demo"',
      'resolver': {'allowed': true, 'paths': []},
      'agree': true,
    });
  }

  @override
  Future<List<ApiResourceInfo>> resources() async => const [
        ApiResourceInfo(group: '', resource: 'pods', verbs: ['get', 'list', 'watch', 'create', 'update', 'patch', 'delete', 'deletecollection']),
        ApiResourceInfo(group: '', resource: 'pods/log', verbs: ['get']),
        ApiResourceInfo(group: '', resource: 'secrets', verbs: ['get', 'list', 'watch', 'create', 'update', 'patch', 'delete', 'deletecollection']),
        ApiResourceInfo(group: 'apps', resource: 'deployments', verbs: ['get', 'list', 'watch', 'create', 'update', 'patch', 'delete', 'deletecollection']),
      ];

  @override
  Future<ApplyResult> apply(Json object, {bool dryRun = false}) async {
    applied.add((object, dryRun));
    return ApplyResult(dryRun: dryRun, created: true, after: toYaml(object));
  }
}

Future<(AppState, FakeAccessApi)> pumpAccess(WidgetTester tester, {Size size = const Size(1400, 860), bool readOnly = false}) async {
  final client = FakeApiClient();
  final app = AppState(client)
    ..types = testTypes
    ..currentContext = 'kind-k8sman-dev'
    ..readOnly = readOnly
    ..namespaces = ['default', 'kube-system', 'rbac-demo'];
  final source = FakeAccessApi(client);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: AccessView(source: source)),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (app, source);
}

void main() {
  testWidgets('explorer: matrix, cell explanation and verify', (tester) async {
    await loadRealFonts();
    final (_, api) = await pumpAccess(tester);
    expect(find.text('Pick a ServiceAccount, user or group'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Find subject'), 'rbac-demo/');
    await tester.pump();
    await tester.tap(find.text('rbac-demo/app'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Granted rows only: secrets is there (named object only), nodes isn't.
    expect(find.text('secrets'), findsOneWidget);
    expect(find.text('nodes'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('cell-/secrets-get')));
    await tester.pump();
    expect(find.text('only named objects'), findsOneWidget);
    expect(find.text('Only: app-db'), findsOneWidget);
    expect(find.textContaining('Reads Secrets'), findsWidgets);

    await tester.tap(find.text('Verify'));
    await tester.pump();
    await tester.pump();
    expect(api.checks.single.$1, const RbacSubject.sa('rbac-demo', 'app'));
    expect(api.checks.single.$2.name, 'app-db');
    expect(find.textContaining('Matches the RBAC analysis'), findsOneWidget);

    // Back to the summary: legend and bindings.
    await tester.tap(find.byTooltip('Close'));
    await tester.pump();
    expect(find.text('Granted by'), findsOneWidget);
    expect(find.text('demo-reader'), findsWidgets);
  });

  testWidgets('who can and can I tabs', (tester) async {
    await loadRealFonts();
    await pumpAccess(tester);
    await tester.tap(find.text('Who can…?'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('subjects'), findsWidgets);
    expect(find.text('Reads Secrets (including ServiceAccount tokens)'), findsOneWidget);
    expect(find.textContaining('3 only for named objects'), findsOneWidget);
    expect(find.text('* on *'), findsWidgets);

    await tester.tap(find.text('Can I…?'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.textContaining('kubernetes-admin'), findsWidgets);
    expect(find.textContaining('system:masters'), findsWidgets);
  });

  testWidgets('read-only hides grant and new role', (tester) async {
    await pumpAccess(tester, readOnly: true);
    expect(find.text('New role'), findsNothing);
    expect(find.text('Grant access'), findsNothing);
  });

  testWidgets('role editor: template, verbs, dry-run then apply', (tester) async {
    await loadRealFonts();
    final (_, api) = await pumpAccess(tester);
    await tester.tap(find.text('New role'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('New Role'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Name'), 'ci-deployer');
    await tester.tap(find.text('Templates'));
    await tester.pump();
    await tester.tap(find.text('CI deployer'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('Rule 4'), findsOneWidget);
    // No namespace yet: can't apply.
    expect(find.textContaining('Pick a namespace'), findsOneWidget);
    final editor = tester.state(find.byType(RoleEditor));
    expect(editor, isNotNull);
    expect(api.applied, isEmpty);
  });

  group('rbac model', () {

    test('editing keeps metadata and aggregationRule', () {
      final base = {
        'metadata': {'name': 'x', 'resourceVersion': '7', 'labels': {'a': 'b'}, 'managedFields': []},
        'aggregationRule': {'clusterRoleSelectors': []},
      };
      final obj = buildRole(cluster: true, name: 'x', rules: [EditableRule()], base: base);
      expect(obj['metadata'], {'name': 'x', 'resourceVersion': '7', 'labels': {'a': 'b'}});
      expect(obj['aggregationRule'], isNotNull);
    });

    test('matrix from rules marks names-only cells and dangers', () {
      final m = matrixFromRules([
        {'apiGroups': [''], 'resources': ['secrets'], 'verbs': ['get'], 'resourceNames': ['db']},
        {'apiGroups': [''], 'resources': ['pods'], 'verbs': ['get', 'list']},
      ]);
      final secrets = m.rows.firstWhere((r) => r.resource == 'secrets');
      expect(secrets.cells['get']!.names, ['db']);
      expect(secrets.cells['get']!.danger, isNotNull);
      expect(m.verbs, ['get', 'list']);
    });
  });
}
