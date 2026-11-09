import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/inspector/inspector.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/metrics/quantity_cell.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/nodes/nodes_view.dart';
import 'package:k8sman/ui/resource_table.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import '../support/screenshot.dart';
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
      await loadRealFonts();
      await _pumpPage(tester, const NodesView(), MetricsFakeApi());
      expect(find.text('CPU'), findsOneWidget);
      expect(find.text('Memory'), findsOneWidget);
      expect(find.textContaining('used'), findsWidgets);
      expect(find.text('used'), findsOneWidget, reason: 'legend');
      expect(find.text('CPU requests'), findsNothing, reason: 'the columns show usage once it is known');
      expect(find.text('CPU requested'), findsOneWidget, reason: 'request totals are in the stat strip');
      expect(find.byType(UsageCell), findsNWidgets(2), reason: 'CPU and memory usage cells');
      await saveScreenshot(tester, 'metrics-nodes-usage');
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

  testWidgets('Node panel: Usage section', (tester) async {
    await loadRealFonts();
    SectionMemory.set('node-allocation', true); // collapsed by default
    await pumpPanel(tester, nodeFixture(), api: MetricsFakeApi(), size: const Size(560, 1600));
    expect(find.text('Usage & allocation'), findsOneWidget);
    expect(find.text('limit'), findsOneWidget, reason: 'legend shows the limit tick');
    expect(find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith('Sampled')), findsOneWidget);
    await saveScreenshot(tester, 'metrics-node-panel');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pod panel: per-container usage and pod total', (tester) async {
    await loadRealFonts();
    final pod = _fixture('test/metrics/fixtures/pod-web.json');
    await pumpPanel(tester, pod, api: MetricsFakeApi(), size: const Size(560, 2600));
    await tester.pumpAndSettle();
    // Per-container usage: mini-bars in each row, figures in their tooltip.
    Finder tip(String s) => find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').contains(s));
    expect(find.text('Usage'), findsOneWidget, reason: 'the status row');
    // nginx has a limit: shown against it, with the request.
    expect(tip('of 200m limit · 50m request'), findsOneWidget);
    expect(tip('of 5m request'), findsOneWidget, reason: 'log-sidecar has only a request');
    await saveScreenshot(tester, 'metrics-pod-panel');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pod panel without metrics stays calm', (tester) async {
    final pod = _fixture('test/metrics/fixtures/pod-web.json');
    await pumpPanel(tester, pod, api: MetricsFakeApi(resourceMetrics: false));
    await tester.tap(find.byKey(const ValueKey('container-row-nginx')));
    await tester.pumpAndSettle();
    expect(find.text('Install metrics-server'), findsOneWidget, reason: 'one install link in the status summary');
    expect(find.text('Usage'), findsOneWidget, reason: 'the status row; container rows show no bars');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Deployment panel: aggregate usage of its pods', (tester) async {
    await loadRealFonts();
    final deploy = _fixture('../dev/fixtures/deploy-web.json');
    await pumpPanel(tester, deploy, api: MetricsFakeApi(), size: const Size(560, 2600));
    expect(find.textContaining('2 pods · total vs their requests'), findsOneWidget);
    expect(find.textContaining('min – median – max'), findsOneWidget);
    expect(find.text('web-6fd47b8fcb-442dt'), findsWidgets);
    final usage = find.textContaining('total vs their requests');
    await tester.ensureVisible(usage);
    await tester.pump();
    await saveScreenshot(tester, 'metrics-deployment-usage');
    expect(tester.takeException(), isNull);
  });

  testWidgets('HPA panel: live current values next to the targets, and the driving metric', (tester) async {
    await loadRealFonts();
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
    await saveScreenshot(tester, 'metrics-hpa-panel');
    expect(tester.takeException(), isNull);
  });


  testWidgets('quantity table cells: values right-aligned, empty as a dash', (tester) async {
    const col = ColumnDef(name: 'CPU', query: '.k8sman.usage.cpu', type: 'quantity');
    const pct = ColumnDef(name: 'CPU%', query: '.x', type: 'quantity');
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: const Scaffold(
        body: Column(children: [
          TableCellView(value: null, column: col),
          TableCellView(value: '12m', column: col),
          TableCellView(value: '95%', column: pct),
        ]),
      ),
    ));
    expect(find.text('—'), findsOneWidget);
    expect(find.text('12m'), findsOneWidget);
    final hot = tester.widget<Text>(find.text('95%'));
    expect(hot.style?.color, isNot(equals(tester.widget<Text>(find.text('12m')).style?.color)), reason: '≥ 90% is coloured');
  });
}
