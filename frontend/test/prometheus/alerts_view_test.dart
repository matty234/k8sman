import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/prometheus/prom_api.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/alerts/alerts_view.dart';
import 'package:k8sman/ui/alerts/alerts_widgets.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import '../support/screenshot.dart';
import 'prom_fixtures.dart';
import 'package:k8sman/ui/widgets/namespace_picker.dart';

Future<AppState> pumpAlerts(
  WidgetTester tester, {
  FixturePromApi? api,
  Size size = const Size(1200, 900),
  String context = 'kind-k8sman-dev',
  String? namespace,
  String? scope,
  bool silences = false,
  bool readOnly = false,
}) async {
  // The Alerts page's own scope (session-wide), independent of app.namespace.
  PageScope.reset();
  PageScope.set('alerts', NamespaceScope.single(scope));
  final prom = api ?? FixturePromApi();
  final client = FakeApiClient();
  final app = AppState(client)
    ..types = testTypes
    ..currentContext = context
    ..namespaces = ['default', 'demo', 'kube-system']
    ..namespace = namespace
    ..readOnly = readOnly;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: AlertsView(source: prom, initialSilences: silences, clock: () => DateTime.utc(2026, 11, 3, 13, 10))),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
  return app;
}

Future<void> disposeView(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
}

void main() {
  final data = AlertsData.fromJson(Map<String, dynamic>.from(promFixture('alerts') as Map));
  final firing = [for (final g in data.groups) ...g.alerts].where((a) => a.state == AlertState.firing).length;
  final pending = [for (final g in data.groups) ...g.alerts].where((a) => a.state == AlertState.pending).length;

  testWidgets('groups alerts by alertname with a firing/pending subtitle', (tester) async {
    await pumpAlerts(tester);
    expect(find.text('Alerts'), findsWidgets);
    expect(find.text('$firing firing · $pending pending'), findsOneWidget);
    expect(find.text('K8smanDemoPodCrashLooping'), findsOneWidget);
    expect(find.text('KubePodNotReady'), findsOneWidget);
    // Severity "none" (Watchdog) is hidden by default…
    expect(find.text('Watchdog'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('sev-none')));
    await tester.pump();
    expect(find.text('Watchdog'), findsOneWidget);
    // …and pending alerts can be filtered out.
    expect(find.text('KubeContainerWaiting'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('state-pending')));
    await tester.pump();
    expect(find.text('KubeContainerWaiting'), findsNothing);
    await disposeView(tester);
  });

  testWidgets('expanded group shows labels, runbook and a link to the pod', (tester) async {
    await loadRealFonts();
    final app = await pumpAlerts(tester);
    await tester.tap(find.text('K8smanDemoPodCrashLooping'));
    await tester.pump();
    await tester.tap(find.text('KubePodNotReady'));
    await tester.pump();
    expect(find.text('Runbook'), findsWidgets);
    expect(find.byType(AlertLabelChips), findsWidgets);
    final link = find.descendant(of: find.byType(AlertTargetLink), matching: find.textContaining('demo/crashy'));
    expect(link, findsWidgets);
    await tester.tap(link.first);
    await tester.pump();
    expect(app.detail?.name, 'crashy');
    expect(app.detail?.type.kind, 'Pod');
    await disposeView(tester);
  });

  testWidgets('has its own scope: defaults to all namespaces, ignores app.namespace, picker refetches', (tester) async {
    final api = FixturePromApi();
    final app = await pumpAlerts(tester, api: api, namespace: 'kube-system');
    // Independent of the table's namespace: starts cluster-wide.
    expect(find.text('All namespaces'), findsOneWidget);
    expect(find.text('K8smanDemoPodCrashLooping'), findsOneWidget);
    expect(find.text('NodeClockNotSynchronising'), findsOneWidget);
    final fetches = api.alertFetches;

    // Changing the table's namespace doesn't change the page scope.
    app.setNamespace('default');
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('NodeClockNotSynchronising'), findsOneWidget);
    expect(api.alertFetches, fetches);

    // Picking a namespace in the header scopes the list and refetches.
    await tester.tap(find.byKey(const ValueKey('page-scope-picker')));
    await tester.pump();
    await tester.tap(find.text('demo').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(api.alertFetches, fetches + 1);
    expect(PageScope.of('alerts').single, 'demo');
    expect(find.text('K8smanDemoPodCrashLooping'), findsOneWidget);
    expect(find.text('NodeClockNotSynchronising'), findsNothing);

    // "Show all" goes back to all namespaces.
    expect(find.text('Show all'), findsOneWidget);
    await tester.tap(find.text('Show all'));
    await tester.pump();
    expect(find.text('NodeClockNotSynchronising'), findsOneWidget);
    expect(PageScope.of('alerts').single, isNull);
    await disposeView(tester);
  });

  testWidgets('Silence… prefills matchers and goes through the confirm dialog', (tester) async {
    await loadRealFonts();
    final api = FixturePromApi();
    await pumpAlerts(tester, api: api);
    expect(find.text('Silence…'), findsNothing, reason: 'collapsed groups keep actions out of the way');
    await tester.tap(find.text('K8smanDemoPodCrashLooping'));
    await tester.pump();
    await tester.tap(find.text('Silence…').first);
    await tester.pumpAndSettle();
    expect(find.text('Silence K8smanDemoPodCrashLooping'), findsOneWidget);
    expect(find.text('Context: '), findsOneWidget);
    expect(find.byKey(const ValueKey('matcher-alertname')), findsOneWidget);
    expect(find.byKey(const ValueKey('matcher-namespace')), findsOneWidget);
    expect(find.byKey(const ValueKey('matcher-service')), findsNothing);
    expect(find.textContaining('Matches 1 current alert'), findsOneWidget);
    await tester.tap(find.text('4h'));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, 'Silence'));
    await tester.pumpAndSettle();
    expect(api.sent, hasLength(1));
    final (method, path, body) = api.sent.single;
    expect('$method $path', 'POST silences');
    final j = body as Map;
    expect(j['duration'], '4h');
    expect(j['createdBy'], 'k8sman');
    expect([for (final m in j['matchers'] as List) '${m['name']}=${m['value']}'], containsAll(['alertname=K8smanDemoPodCrashLooping', 'namespace=demo']));
    expect(find.textContaining('Silenced K8smanDemoPodCrashLooping'), findsOneWidget);
    await disposeView(tester);
  });

  testWidgets('non-local contexts get a prominent warning before silencing', (tester) async {
    final api = FixturePromApi();
    await pumpAlerts(tester, api: api, context: 'prod-eu-1');
    await tester.tap(find.text('K8smanDemoPodCrashLooping'));
    await tester.pump();
    await tester.tap(find.text('Silence…').first);
    await tester.pumpAndSettle();
    expect(find.textContaining('not a local cluster', findRichText: true), findsWidgets);
    expect(tester.takeException(), isNull);
    await disposeView(tester);
  });

  testWidgets('empty state offers to install the stack', (tester) async {
    await loadRealFonts();
    await pumpAlerts(tester, api: FixturePromApi(missing: true), size: const Size(900, 600));
    expect(find.text('No Alertmanager found'), findsOneWidget);
    await tester.tap(find.text('Install Prometheus stack…'));
    await tester.pumpAndSettle();
    expect(find.text('Install Prometheus stack'), findsOneWidget);
    expect(find.text('Dry run'), findsOneWidget);
    await disposeView(tester);
  });

  testWidgets('a failed search shows the error and Retry, not an install offer', (tester) async {
    await pumpAlerts(tester, api: FixturePromApi(missing: true, discoveryFailed: true), size: const Size(900, 600));
    expect(find.textContaining("Couldn't check for Prometheus"), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Install Prometheus stack…'), findsNothing);
    await disposeView(tester);
  });

  testWidgets('no overflow from 360 to 1800px, expanded and on both tabs', (tester) async {
    for (final w in [360.0, 480.0, 700.0, 1000.0, 1400.0, 1800.0]) {
      for (final silences in [false, true]) {
        await pumpAlerts(tester, size: Size(w, 900), silences: silences, scope: w < 500 ? 'demo' : null);
        if (!silences) {
          await tester.tap(find.text('K8smanDemoPodCrashLooping'));
          await tester.pump();
        }
        expect(tester.takeException(), isNull, reason: 'width $w silences=$silences');
        await disposeView(tester);
      }
    }
    await loadRealFonts();
    await pumpAlerts(tester, size: const Size(360, 900));
    await tester.tap(find.text('K8smanDemoPodCrashLooping'));
    await tester.pump();
    await disposeView(tester);
  });
}
