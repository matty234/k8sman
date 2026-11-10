import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/metrics/quantity_cell.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/nodes/nodes_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import 'metrics_fakes.dart';
import 'package:k8sman/ui/widgets/namespace_picker.dart';

Json _fixture(String path) => Map<String, dynamic>.from(jsonDecode(File(path).readAsStringSync()));

/// Pumps a main-area page at [size] with the given API.
Future<AppState> _pumpPage(WidgetTester tester, Widget page, ApiClient api, {Size size = const Size(1200, 760), String? namespace = 'demo', String? scope = 'demo'}) async {
  // The Metrics page's own scope (session-wide), independent of app.namespace.
  PageScope.reset();
  PageScope.set('metrics', NamespaceScope.single(scope));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(api)
    ..types = testTypes
    ..namespace = namespace
    ..namespaces = ['default', 'demo', 'kube-system']
    ..currentContext = 'kind-k8sman-dev';
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.dark), home: Scaffold(body: page)),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  return app;
}

Future<void> _resize(WidgetTester tester, double w, double h) async {
  tester.view.physicalSize = Size(w, h);
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  group('Nodes page', () {
    testWidgets('shows usage meters next to requests', (tester) async {
      await _pumpPage(tester, const NodesView(), MetricsFakeApi());
      expect(find.text('CPU'), findsOneWidget);
      expect(find.text('Memory'), findsOneWidget);
      expect(find.textContaining('used'), findsWidgets);
      expect(find.text('used'), findsOneWidget, reason: 'legend');
      expect(find.text('CPU requests'), findsNothing, reason: 'the columns show usage once it is known');
      expect(find.text('CPU requested'), findsOneWidget, reason: 'request totals are in the stat strip');
      expect(find.byType(UsageCell), findsNWidgets(2), reason: 'CPU and memory usage cells');
      for (var w = 360.0; w <= 1800; w += 60) {
        await _resize(tester, w, 700);
        expect(tester.takeException(), isNull, reason: 'overflow at $w');
      }
    });

    testWidgets('without metrics-server: request bars and an install link', (tester) async {
      await _pumpPage(tester, const NodesView(), MetricsFakeApi(resourceMetrics: false));
      expect(find.text('CPU requests'), findsOneWidget);
      expect(find.text('Metrics unavailable'), findsOneWidget);
      await tester.tap(find.text('Install metrics-server'));
      await tester.pumpAndSettle();
      expect(find.text('Dry run'), findsOneWidget);
      for (var w = 360.0; w <= 1800; w += 120) {
        await _resize(tester, w, 700);
        expect(tester.takeException(), isNull, reason: 'overflow at $w');
      }
    });
  });

  testWidgets('Pod panel: per-container usage', (tester) async {
    final pod = _fixture('test/metrics/fixtures/pod-web.json');
    await pumpPanel(tester, pod, api: MetricsFakeApi(), size: const Size(560, 2600));
    await tester.pumpAndSettle();
    // Per-container usage: mini-bars in each row, figures in their tooltip.
    Finder tip(String s) => find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').contains(s));
    // nginx has a limit: shown against it, with the request.
    expect(tip('of 200m limit · 50m request'), findsOneWidget);
    expect(tip('of 5m request'), findsOneWidget, reason: 'log-sidecar has only a request');
    expect(tester.takeException(), isNull);
  });

  testWidgets('HPA panel: live current values next to the targets, and the driving metric', (tester) async {
    final hpa = _fixture('test/metrics/fixtures/hpa-web-object.json');
    await pumpPanel(tester, hpa, api: MetricsFakeApi(), size: const Size(560, 1800));
    // One Metrics section: the External metric's live value (custom/external
    // metrics API) beside its target, and CPU's.
    expect(find.text('Live metrics'), findsNothing);
    expect(find.textContaining('avg 1  /  target avg 1', findRichText: true), findsOneWidget);
    expect(find.textContaining('7%  /  target 70%', findRichText: true), findsOneWidget);
    expect(find.text('driving'), findsOneWidget);
    expect(find.textContaining('drives the decision: 2 replicas'), findsOneWidget);
    expect(find.textContaining('HPA status'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });


}
