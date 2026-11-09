import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/overview/overview_api.dart';
import 'package:k8sman/ui/overview/overview_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import '../support/screenshot.dart';
import 'package:k8sman/ui/widgets/namespace_picker.dart';

/// Real response captured from the kind dev cluster (`demo` has a
/// CrashLoopBackOff and an ImagePullBackOff pod).
Json liveFixture() => jsonDecode(File('test/overview/fixtures/overview.json').readAsStringSync());

/// The backend's analysis of its unit-test scenario (one of every problem),
/// written by `OVERVIEW_FIXTURE_OUT=... go test ./internal/overview -run Scenario`.
Json scenarioFixture() => jsonDecode(File('test/overview/fixtures/overview-scenario.json').readAsStringSync());

class FakeOverviewApi extends OverviewApi {
  Json response;
  final List<String?> calls = [];
  FakeOverviewApi(this.response, ApiClient api) : super(api);

  @override
  Future<OverviewData> fetch({NamespaceScope scope = NamespaceScope.all}) async {
    calls.add(scope.single);
    return OverviewData.fromJson(response);
  }
}

class RecordingApi extends FakeApiClient {
  final List<String> actions = [];
  RecordingApi({super.objects});

  @override
  Future<ActionResult> runAction(ResourceRef r, {String? namespace, required String name, required String action, Json body = const {}}) async {
    actions.add('$action ${r.resource} $namespace/$name ${jsonEncode(body)}');
    return ActionResult(message: '$action ok', context: 'kind-k8sman-dev');
  }
}

Future<(AppState, FakeOverviewApi)> pumpOverview(
  WidgetTester tester,
  Json response, {
  Size size = const Size(1000, 800),
  bool readOnly = false,
  String? namespace,
  ApiClient? api,
}) async {
  PageScope.reset(); // Overview's scope is session-wide.
  final client = api ?? RecordingApi();
  final app = AppState(client)
    ..types = testTypes
    ..readOnly = readOnly
    ..currentContext = 'kind-k8sman-dev'
    ..namespace = namespace;
  final source = FakeOverviewApi(response, client);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: OverviewView(source: source)),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return (app, source);
}

/// pumpAndSettle never settles while a button spinner runs behind a dialog.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Json healthyResponse() => {
      'generatedAt': '2026-11-03T12:00:00Z',
      'namespace': '',
      'counts': {
        'pods': {'total': 12, 'ready': 10, 'running': 10, 'completed': 2},
        'deployments': {'total': 3, 'healthy': 3},
        'nodes': {'total': 1, 'ready': 1},
      },
      'categories': [],
      'issues': [],
      'nodes': [
        {'name': 'k8sman-dev-control-plane', 'ready': true, 'roles': ['control-plane'], 'pods': 10},
      ],
      'topWarnings': [],
    };

/// Problem rows in the area cards ("1 Stuck terminating · pod legacy-abc").
Finder areaRow(String label) => find.textContaining(label, findRichText: true).first;

/// Moves a mouse over [target] so its row shows its actions.
Future<void> hover(WidgetTester tester, Finder target) async {
  if (_mouse == null) {
    final g = _mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: tester.getCenter(target));
    addTearDown(() async {
      await g.removePointer();
      _mouse = null;
    });
  } else {
    await _mouse!.moveTo(tester.getCenter(target));
  }
  await tester.pump();
}

TestGesture? _mouse;

void main() {
  testWidgets('live fixture: cards, issues, nodes and events', (tester) async {
    await loadRealFonts();
    final (app, source) = await pumpOverview(tester, liveFixture());
    expect(source.calls, [null]);
    expect(find.text('All namespaces'), findsOneWidget);
    expect(find.textContaining('CrashLoopBackOff', findRichText: true), findsWidgets); // card row + reason
    expect(find.textContaining('Image pull errors', findRichText: true), findsOneWidget);
    expect(find.text('All 7 workloads healthy'), findsOneWidget); // a problem-free area folds into a line
    expect(find.text('crashy'), findsWidgets); // issue row + warning event example
    expect(find.text('bad-image'), findsWidgets);
    expect(find.text('k8sman-dev-control-plane'), findsOneWidget);
    expect(find.text('BackOff'), findsOneWidget);
    await saveScreenshot(tester, 'overview-live-1000');

    // Clicking a name opens the sidebar.
    await tester.tap(find.text('crashy').first);
    expect(app.detail?.name, 'crashy');
    expect(app.detail?.namespace, 'demo');
    expect(app.detail?.type.kind, 'Pod');

    tester.view.physicalSize = const Size(1500, 900);
    await tester.pump();
    await saveScreenshot(tester, 'overview-live-1500');
  });

  testWidgets('scenario: grouped by owner, tile filters, expands', (tester) async {
    await loadRealFonts();
    await pumpOverview(tester, scenarioFixture(), size: const Size(1500, 1400));
    await saveScreenshot(tester, 'overview-scenario-1500');

    // Three crashlooping pods of deployment web collapse into one row.
    // (The page is built in full, so web-5c-b may also appear further down,
    // e.g. in warning events: compare counts rather than expect none.)
    expect(find.text('3 pods'), findsOneWidget);
    final before = find.text('web-5c-b').evaluate().length;
    final beforeD = find.text('web-5c-d').evaluate().length;
    await tester.tap(find.text('3 pods'));
    await tester.pump();
    expect(find.text('web-5c-b').evaluate().length, before + 1);
    expect(find.text('web-5c-d').evaluate().length, beforeD + 1);
    await saveScreenshot(tester, 'overview-scenario-expanded');

    // Filter by the count of the "Stuck terminating" row of the Pods card.
    await tester.tap(find.byKey(const ValueKey('area-count-stuckTerminating')));
    await tester.pump();
    expect(find.text('legacy-abc'), findsOneWidget);
    expect(find.text('img-1'), findsNothing);
    expect(find.textContaining('Stuck terminating · 1'), findsOneWidget);
    // Tapping again clears the filter.
    await tester.tap(find.byKey(const ValueKey('area-count-stuckTerminating')));
    await tester.pump();
    expect(find.text('img-1'), findsOneWidget);
  });

  testWidgets('scenario at 1000x800', (tester) async {
    await loadRealFonts();
    await pumpOverview(tester, scenarioFixture(), size: const Size(1000, 800));
    await saveScreenshot(tester, 'overview-scenario-1000');
  });

  for (final width in [360.0, 420.0, 500.0, 600.0, 700.0, 900.0, 1200.0, 1600.0]) {
    testWidgets('no overflow at ${width.toInt()}px', (tester) async {
      await pumpOverview(tester, scenarioFixture(), size: Size(width, 3000));
      // Expand every group too.
      for (final f in find.textContaining(RegExp(r'^\d+ pods$')).evaluate().toList()) {
        await tester.tap(find.byWidget(f.widget));
      }
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('narrow screenshot (700px)', (tester) async {
    await loadRealFonts();
    await pumpOverview(tester, scenarioFixture(), size: const Size(700, 1400));
    await saveScreenshot(tester, 'overview-scenario-700');
  });

  testWidgets('healthy cluster shows a calm state', (tester) async {
    await loadRealFonts();
    await pumpOverview(tester, healthyResponse(), size: const Size(1000, 600));
    expect(find.text('All healthy'), findsOneWidget);
    expect(find.text('All 10 pods healthy · All 3 workloads healthy · 1 node ready'), findsOneWidget);
    expect(find.text('Issues'), findsNothing); // no empty list under the banner
    expect(find.text('No warning events in the last hour.'), findsOneWidget);
    await saveScreenshot(tester, 'overview-healthy');
  });

  testWidgets('restart action fetches the owner and runs restart', (tester) async {
    final api = RecordingApi(objects: {
      'deployments.apps/shop/web': {
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {'name': 'web', 'namespace': 'shop'},
        'spec': {'replicas': 4},
      },
    });
    await pumpOverview(tester, scenarioFixture(), size: const Size(1500, 1400), api: api);
    // The Restart button on the "Deployment web · 3 pods" CrashLoopBackOff row.
    final webRow = find.ancestor(of: find.text('3 pods'), matching: find.byType(InkWell)).first;
    await hover(tester, find.text('3 pods'));
    await tester.tap(find.descendant(of: webRow, matching: find.widgetWithText(OutlinedButton, 'Restart')));
    await settle(tester);
    expect(find.text('Restart Deployment web?'), findsOneWidget);
    expect(find.text('kind-k8sman-dev'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Restart'));
    await settle(tester);
    expect(api.actions, ['restart deployments shop/web {}']);
  });

  testWidgets('force delete for stuck terminating pods and resume for suspended cronjobs', (tester) async {
    final api = RecordingApi(objects: {
      'pods/shop/legacy-abc': {
        'apiVersion': 'v1',
        'kind': 'Pod',
        'metadata': {'name': 'legacy-abc', 'namespace': 'shop'},
      },
      'cronjobs.batch/batch/reports': {
        'apiVersion': 'batch/v1',
        'kind': 'CronJob',
        'metadata': {'name': 'reports', 'namespace': 'batch'},
        'spec': {'suspend': true},
      },
    });
    await pumpOverview(tester, scenarioFixture(), size: const Size(1500, 3000), api: api);
    await hover(tester, find.text('legacy-abc'));
    await tester.tap(find.widgetWithText(OutlinedButton, 'Force delete'));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Force delete'));
    await settle(tester);
    final reportsRow = find.ancestor(of: find.text('reports'), matching: find.byType(InkWell)).first;
    await hover(tester, find.text('reports'));
    await tester.tap(find.descendant(of: reportsRow, matching: find.widgetWithText(OutlinedButton, 'Resume')));
    await settle(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Resume'));
    await settle(tester);
    expect(api.actions, [
      'delete pods shop/legacy-abc {"gracePeriodSeconds":0}',
      'unsuspend cronjobs batch/reports {}',
    ]);
  });

  testWidgets('scenario: area cards, capacity and actions on hover', (tester) async {
    await pumpOverview(tester, scenarioFixture(), size: const Size(1500, 2400));
    // Problems are grouped into one card per area, with the area's total.
    for (final area in ['pods', 'workloads', 'jobs', 'nodes', 'storage', 'network']) {
      expect(find.byKey(ValueKey('area-$area')), findsOneWidget, reason: area);
    }
    final pods = find.byKey(const ValueKey('area-pods'));
    expect(find.descendant(of: pods, matching: find.text('13')), findsOneWidget);
    expect(find.descendant(of: pods, matching: find.textContaining('CrashLoopBackOff · 4 pods, 2 workloads', findRichText: true)), findsOneWidget);
    // Paused rollouts sit in the Workloads card as a muted row.
    expect(find.descendant(of: find.byKey(const ValueKey('area-workloads')), matching: find.textContaining('Paused rollouts', findRichText: true)), findsOneWidget);
    // Cluster requests vs allocatable: 14 pods of 250m / 256Mi on 3 nodes of 4 CPU / 16Gi.
    expect(find.textContaining('3.5 / 12 cores requested · 29%', findRichText: true), findsOneWidget);
    expect(find.textContaining('3.5 GiB / 48 GiB requested · 7%', findRichText: true), findsOneWidget);
    // Severity sub-headings.
    expect(find.textContaining(RegExp(r'^Errors  \d+$'), findRichText: true), findsOneWidget);
    expect(find.textContaining(RegExp(r'^Warnings  \d+$'), findRichText: true), findsOneWidget);
    // Row actions only show on hover, without moving anything.
    Opacity actionsOf(String name) => tester.widget<Opacity>(find.descendant(
        of: find.ancestor(of: find.text(name), matching: find.byType(InkWell)).first, matching: find.byType(Opacity)).first);
    final before = tester.getTopLeft(find.text('img-1'));
    expect(actionsOf('img-1').opacity, 0);
    await hover(tester, find.text('img-1'));
    expect(actionsOf('img-1').opacity, 1);
    expect(tester.getTopLeft(find.text('img-1')), before);
  });

  testWidgets('read-only hides actions', (tester) async {
    await pumpOverview(tester, scenarioFixture(), size: const Size(1500, 2400), readOnly: true);
    expect(find.byType(OutlinedButton), findsNothing);
  });

  testWidgets('defaults to all namespaces, has its own scope picker, auto-refreshes until paused', (tester) async {
    final (app, source) = await pumpOverview(tester, liveFixture(), namespace: 'demo');
    // Independent of the table's namespace: starts cluster-wide.
    expect(source.calls, [null]);
    expect(find.text('All namespaces'), findsOneWidget);

    // Changing the table's namespace doesn't change the Overview scope.
    app.setNamespace('kube-system');
    await tester.pump();
    await tester.pump();
    expect(source.calls, [null]);

    // Pick a namespace in Overview's own picker.
    app.namespaces = ['default', 'demo', 'kube-system'];
    app.setNamespace('kube-system');
    await tester.pump();
    await tester.tap(find.text('All namespaces'));
    await tester.pump();
    await tester.tap(find.text('demo').last);
    await tester.pump();
    await tester.pump();
    expect(source.calls, [null, 'demo']);

    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    expect(source.calls.length, 3);

    await tester.tap(find.byTooltip('Pause auto-refresh'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 30));
    expect(source.calls.length, 3);
    expect(find.textContaining('Paused'), findsOneWidget);

    await tester.tap(find.byTooltip('Refresh now'));
    await tester.pump();
    expect(source.calls.length, 4);

    // Reset the session-wide scope for other tests.
    await tester.tap(find.text('demo').first);
    await tester.pump();
    await tester.tap(find.text('All namespaces').last);
    await tester.pump();
  });

  test('groupIssues groups by owner and category', () {
    final data = OverviewData.fromJson(scenarioFixture());
    final groups = groupIssues(data.issues);
    final web = groups.firstWhere((g) => g.owner?.name == 'web' && g.category == 'crashLoop');
    expect(web.issues.map((i) => i.name), ['web-5c-d', 'web-5c-c', 'web-5c-b']);
    expect(groups.where((g) => g.category == 'crashLoop'), hasLength(2)); // web + a bare pod
    expect(groups.first.severity, IssueSeverity.critical);
    expect(groups.last.severity, IssueSeverity.info);
  });
}
