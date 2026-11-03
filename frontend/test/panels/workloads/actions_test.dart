import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/actions/actions.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/registry.dart';
import 'package:k8sman/panels/workloads/rollout.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';
import 'support.dart';

/// Like harness.pumpPanel, but lets the test set AppState.readOnly first.
Future<AppState> pumpWorkload(WidgetTester tester, Json object, ApiClient api, {bool readOnly = false}) async {
  final group = '${object['apiVersion']}'.split('/').first;
  final t = testType(group, '${object['kind']}');
  final app = AppState(api)
    ..types = testTypes
    ..readOnly = readOnly
    ..currentContext = 'kind-k8sman-dev';
  app.openDetail(DetailTarget(type: t, name: '${object['metadata']['name']}', namespace: object['metadata']['namespace']));
  tester.view.physicalSize = const Size(560, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: Builder(builder: (context) {
          final ctx = PanelContext(object: object, type: t, api: api, app: app);
          return ListView(padding: const EdgeInsets.all(12), children: panelFor(t).buildSections(context, ctx));
        }),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return app;
}

void main() {
  late List<Json> pods;
  setUpAll(() => pods = loadLocal('pods-demo.json'));

  FakeApiClient api() => fakeApi({
        'pods': pods,
        'replicasets.apps': deploymentReplicaSets(),
        'horizontalpodautoscalers.autoscaling': [loadFixture('hpa-web.json')],
        'persistentvolumeclaims': loadLocal('pvcs-demo.json'),
      });

  testWidgets('Deployment shows scale control, HPA note, per-revision rollback and pod menus', (tester) async {
    await loadRealFonts();
    await pumpWorkload(tester, loadFixture('deploy-web.json'), api());
    await saveScreenshot(tester, 'workloads-deployment-actions');

    expect(find.byType(ScaleControl), findsOneWidget);
    expect(find.textContaining('manual scaling will be overridden'), findsOneWidget);
    // Revisions 10 (current), 2, 1: only the non-current ones get Roll back.
    expect(find.widgetWithText(ActionButton, 'Roll back'), findsNWidgets(2));
    expect(find.byTooltip('Pod actions'), findsNWidgets(2));

    await tester.tap(find.widgetWithText(ActionButton, 'Roll back').first);
    // The button shows a spinner while its dialog is open: pump, don't settle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text('Roll back web to revision 2?'), findsOneWidget);
    expect(find.textContaining('nginx: nginx:1.28-alpine → nginx:1.27.1-alpine'), findsOneWidget);
    await saveScreenshot(tester, 'workloads-rollback-dialog');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('per-pod menu offers restart and confirms', (tester) async {
    await pumpWorkload(tester, loadFixture('sts-redis.json'), api());
    expect(find.byType(ScaleControl), findsOneWidget);
    expect(find.textContaining('manual scaling will be overridden'), findsNothing); // HPA targets web, not redis
    await tester.tap(find.byTooltip('Pod actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Restart pod (delete)'));
    await tester.pumpAndSettle();
    expect(find.text('Restart pod redis-0?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('paused Deployment shows a Paused callout with Resume', (tester) async {
    await loadRealFonts();
    final d = clone(loadFixture('deploy-web.json'), (c) => c['spec']['paused'] = true);
    await pumpWorkload(tester, d, api());
    await saveScreenshot(tester, 'workloads-deployment-paused');
    expect(find.textContaining('Paused: template changes'), findsOneWidget);
    expect(find.widgetWithText(ActionButton, 'Resume'), findsOneWidget);
  });

  testWidgets('read-only hides every mutating control', (tester) async {
    final d = clone(loadFixture('deploy-web.json'), (c) => c['spec']['paused'] = true);
    await pumpWorkload(tester, d, api(), readOnly: true);
    expect(find.byType(ScaleControl), findsNothing);
    expect(find.byType(ActionButton), findsNothing);
    expect(find.byTooltip('Pod actions'), findsNothing);
    expect(find.textContaining('manual scaling will be overridden'), findsNothing);
    expect(find.textContaining('Paused: template changes'), findsOneWidget); // info stays
    expect(find.text('#2'), findsOneWidget); // history still renders
  });

  test('rollbackSummary describes the image diff', () {
    final rs = rolloutHistory(deploymentReplicaSets(), '3da9fffa-3dd5-4b29-a931-46caa39da1bd');
    expect(rollbackSummary(rs[0], rs[2]), contains('nginx: nginx:1.28-alpine → nginx:1.27-alpine'));
    expect(rollbackSummary(rs[0], rs[0]), contains('Images are unchanged'));
  });
}
