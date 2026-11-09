import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/detail/yaml_editor.dart' show DiffView;
import 'package:k8sman/ui/helm/helm_api.dart';
import 'package:k8sman/ui/helm/helm_view.dart';
import 'package:k8sman/ui/helm/yaml_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import 'fake_helm_api.dart';
import '../support/screenshot.dart';

Future<(AppState, FakeHelmApi)> pumpHelm(
  WidgetTester tester, {
  Size size = const Size(1400, 900),
  String? namespace,
  bool readOnly = false,
  String context = 'kind-k8sman-dev',
}) async {
  final client = FakeApiClient();
  final helm = FakeHelmApi();
  final app = AppState(client)
    ..types = testTypes
    ..namespaces = const ['default', 'helm-demo', 'helm-tools', 'kube-system']
    ..namespace = namespace
    ..readOnly = readOnly
    ..currentContext = context;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: HelmView(api: helm)),
    ),
  ));
  await settle(tester);
  return (app, helm);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}

Future<void> dispose(WidgetTester tester) => tester.pumpWidget(const SizedBox()); // cancels the poll timer

Future<void> selectRelease(WidgetTester tester, String name) async {
  await tester.tap(find.text(name).first);
  await settle(tester);
}

Future<void> openTab(WidgetTester tester, String prefix) async {
  await tester.tap(find.byWidgetPredicate((w) => w is Tab && (w.text ?? '').startsWith(prefix)));
  await tester.pumpAndSettle();
}

void main() {
  test('sortReleases puts pending, then failed, first', () {
    final rs = sortReleases(HelmReleaseList.fromJson(fx('releases.json')).releases);
    expect(rs.map((r) => '${r.name}:${r.status}').take(3), ['worker:pending-upgrade', 'api:failed', 'web:deployed']);
  });

  testWidgets('list: problems first, summary, filter, namespace', (tester) async {
    await loadRealFonts();
    final (app, _) = await pumpHelm(tester);
    expect(find.text('Helm'), findsOneWidget);
    expect(find.text('5 releases · 1 failed · 1 pending'), findsOneWidget);
    // worker (pending) is first and selected by default.
    final y = {for (final n in ['worker', 'api', 'web', 'metrics-server']) n: tester.getTopLeft(find.text(n).first).dy};
    expect(y['worker']! < y['api']! && y['api']! < y['web']! && y['web']! < y['metrics-server']!, isTrue);
    expect(find.textContaining('Stuck in pending-upgrade'), findsOneWidget);

    await tester.enterText(find.byType(TextField).first, 'metrics');
    await settle(tester);
    expect(find.text('web'), findsNothing);
    expect(find.text('metrics-server'), findsWidgets);
    await tester.enterText(find.byType(TextField).first, '');
    await settle(tester);

    app.setNamespace('helm-demo');
    await settle(tester);
    expect(find.text('worker'), findsNothing);
    expect(find.text('2 releases · 1 failed'), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('detail tabs: overview, values, manifest, history diff, hooks', (tester) async {
    await loadRealFonts();
    final (app, helm) = await pumpHelm(tester);
    await selectRelease(tester, 'web');
    // Overview: chart, notes, resources link to real objects.
    expect(find.text('Chart'), findsWidgets);
    expect(find.text('Dependencies'), findsOneWidget);
    expect(find.textContaining('kubectl -n helm-demo port-forward'), findsOneWidget);
    await tester.tap(find.text('web-cache').first);
    await tester.pump();
    expect(app.detail?.name, 'web-cache');
    expect(app.detail?.namespace, 'helm-demo');
    app.closeDetail();
    await settle(tester);

    await openTab(tester, 'Values');
    expect(tester.widget<HelmYamlView>(find.byType(HelmYamlView)).text, contains('replicaCount: 2'));
    await tester.tap(find.text('Computed'));
    await tester.pumpAndSettle();
    expect(tester.widget<HelmYamlView>(find.byType(HelmYamlView)).text, contains('pullPolicy: IfNotPresent'));

    await openTab(tester, 'Manifest');
    expect(tester.widget<HelmYamlView>(find.byType(HelmYamlView)).text, contains('kind: Deployment'));

    await openTab(tester, 'Hooks');
    expect(find.text('Job web-smoke'), findsOneWidget);
    expect(find.text('Succeeded'), findsOneWidget);

    await openTab(tester, 'History');
    expect(find.text('current'), findsOneWidget);
    await tester.tap(find.byTooltip('Diff with current').at(1)); // revision 3
    await tester.pumpAndSettle();
    expect(helm.calls, contains('diff helm-demo/web 3→5'));
    expect(find.text('web: revision 3 → 5'), findsOneWidget);
    expect(find.byType(DiffView), findsOneWidget);
    await tester.tap(find.textContaining('Values  '));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    await dispose(tester);
  });

  testWidgets('upgrade: edit values → dry run → diff confirm → apply', (tester) async {
    await loadRealFonts();
    final (_, helm) = await pumpHelm(tester, namespace: 'helm-demo');
    await selectRelease(tester, 'api');
    expect(find.textContaining('Revision 2 failed'), findsOneWidget);
    await tester.tap(find.text('Edit values'));
    await tester.pumpAndSettle();
    expect(find.text('Edit values of api'), findsOneWidget);
    await tester.tap(find.text('Dry run & review'));
    await tester.pumpAndSettle();
    expect(helm.calls, ['upgrade helm-demo/api dryRun=true']);
    expect(find.text('Upgrade api with these values?'), findsOneWidget);
    expect(find.byType(DiffView), findsOneWidget);
    expect(find.text('kind-k8sman-dev'), findsOneWidget);

    // Cancel goes back to the editor with the edits kept…
    await tester.tap(find.text('Cancel').last);
    await tester.pumpAndSettle();
    expect(find.text('Edit values of api'), findsOneWidget);
    // …and confirming applies.
    await tester.tap(find.text('Dry run & review'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Upgrade'));
    await tester.pumpAndSettle();
    expect(helm.calls.last, 'upgrade helm-demo/api dryRun=false');
    expect(find.text('Upgraded api to revision 3 (deployed)'), findsOneWidget);
    await dispose(tester);
  });

  testWidgets('non-local context: uninstall warns about the cluster, no typing needed', (tester) async {
    final (_, helm) = await pumpHelm(tester, namespace: 'helm-demo', context: 'prod-eu');
    await selectRelease(tester, 'web');
    expect(tester.widget<FilledButton>(find.ancestor(of: find.text('Edit values'), matching: find.byWidgetPredicate((w) => w is FilledButton))).onPressed, isNull,
        reason: 'web uses subcharts, so upgrading from the stored chart is blocked');
    await tester.tap(find.text('Uninstall'));
    await tester.pumpAndSettle();
    final confirm = find.widgetWithText(FilledButton, 'Uninstall').last;
    expect(find.textContaining('not a local cluster'), findsOneWidget);
    expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(helm.calls, ['uninstall helm-demo/web keepHistory=true']);
    await dispose(tester);
  });

  testWidgets('history: roll back to a revision', (tester) async {
    final (_, helm) = await pumpHelm(tester, namespace: 'helm-demo');
    await selectRelease(tester, 'web');
    await openTab(tester, 'History');
    await tester.tap(find.byTooltip('Roll back to this revision').at(1)); // revision 3
    await tester.pumpAndSettle();
    expect(find.text('Roll back web to revision 3?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Roll back'));
    await tester.pumpAndSettle();
    expect(helm.calls.last, 'rollback helm-demo/web 3');
    await dispose(tester);
  });

  testWidgets('read-only hides every mutation', (tester) async {
    await pumpHelm(tester, readOnly: true);
    expect(find.textContaining('Stuck in pending-upgrade'), findsOneWidget);
    expect(find.text('Roll back to 1'), findsNothing);
    expect(find.text('Edit values'), findsNothing);
    expect(find.text('Uninstall'), findsNothing);
    await openTab(tester, 'History');
    expect(find.byTooltip('Roll back to this revision'), findsNothing);
    expect(find.byTooltip('Diff with current'), findsWidgets);
    await dispose(tester);
  });

  testWidgets('no overflow from 360 to 1800 wide, on every tab', (tester) async {
    await loadRealFonts();
    for (final w in [360.0, 900.0, 1800.0]) {
      for (final h in [900.0]) {
        await pumpHelm(tester, size: Size(w, h));
        await selectRelease(tester, 'web');
        for (final tab in ['Values', 'Manifest', 'History', 'Hooks', 'Overview']) {
          await openTab(tester, tab);
          expect(tester.takeException(), isNull, reason: 'overflow at ${w}x$h on $tab');
        }
        await selectRelease(tester, 'worker');
        expect(tester.takeException(), isNull, reason: 'overflow at ${w}x$h (stuck banner)');
        await dispose(tester);
      }
    }
  });
}
