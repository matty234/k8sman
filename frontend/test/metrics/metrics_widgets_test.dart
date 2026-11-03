import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/metrics/metrics_page.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/nodes/nodes_view.dart';
import 'package:k8sman/ui/resource_table.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import '../support/screenshot.dart';
import 'metrics_fakes.dart';

Json _fixture(String path) => Map<String, dynamic>.from(jsonDecode(File(path).readAsStringSync()));

/// Pumps a main-area page at [size] with the given API.
Future<AppState> _pumpPage(WidgetTester tester, Widget page, ApiClient api, {Size size = const Size(1200, 760), String? namespace = 'demo'}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(api)
    ..types = testTypes
    ..namespace = namespace
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
      expect(find.text('CPU requests'), findsNothing, reason: 'requests are drawn as outlines once usage is known');
      expect(find.textContaining('requests '), findsOneWidget, reason: 'request totals stay visible as text');
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
      expect(find.text('Install metrics-server?'), findsOneWidget);
      for (var w = 360.0; w <= 1800; w += 120) {
        await _resize(tester, w, 700);
        expect(tester.takeException(), isNull, reason: 'overflow at $w');
      }
    });
  });

  testWidgets('Node panel: Usage section', (tester) async {
    await loadRealFonts();
    await pumpPanel(tester, nodeFixture(), api: MetricsFakeApi(), size: const Size(560, 1600));
    expect(find.text('Usage'), findsOneWidget);
    expect(find.text('limit'), findsOneWidget, reason: 'legend shows the limit tick');
    expect(find.textContaining('sampled'), findsOneWidget);
    await saveScreenshot(tester, 'metrics-node-panel');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pod panel: per-container usage and pod total', (tester) async {
    await loadRealFonts();
    final pod = _fixture('test/metrics/fixtures/pod-web.json');
    await pumpPanel(tester, pod, api: MetricsFakeApi(), size: const Size(560, 2600));
    // Status row + one row per running container.
    expect(find.text('Usage'), findsNWidgets(3));
    expect(find.textContaining('of request'), findsWidgets);
    // nginx has a limit: shown against it.
    expect(find.textContaining('200m lim'), findsOneWidget);
    expect(find.textContaining('5m req'), findsOneWidget, reason: 'log-sidecar has only a request');
    await saveScreenshot(tester, 'metrics-pod-panel');
    expect(tester.takeException(), isNull);
  });

  testWidgets('Pod panel without metrics stays calm', (tester) async {
    final pod = _fixture('test/metrics/fixtures/pod-web.json');
    await pumpPanel(tester, pod, api: MetricsFakeApi(resourceMetrics: false));
    expect(find.text('Install metrics-server'), findsOneWidget, reason: 'one install link in the status summary');
    expect(find.text('Usage'), findsNWidgets(3));
    expect(find.text('—'), findsAtLeastNWidgets(2), reason: 'containers show a dash');
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

  testWidgets('HPA panel: live values and the driving metric', (tester) async {
    await loadRealFonts();
    final hpa = _fixture('test/metrics/fixtures/hpa-web-object.json');
    await pumpPanel(tester, hpa, api: MetricsFakeApi(), size: const Size(560, 1800));
    expect(find.text('Live metrics'), findsOneWidget);
    expect(find.text('driving'), findsOneWidget);
    expect(find.textContaining('drives the decision: 2 replicas'), findsOneWidget);
    expect(find.textContaining('HPA status'), findsNWidgets(2));
    await saveScreenshot(tester, 'metrics-hpa-panel');
    expect(tester.takeException(), isNull);
  });

  group('Metrics page', () {
    testWidgets('Top: status strip, nodes and pods; click opens the inspector', (tester) async {
      await loadRealFonts();
      final app = await _pumpPage(tester, const MetricsPage(), MetricsFakeApi());
      expect(find.text('Metrics'), findsOneWidget);
      expect(find.text('metrics.k8s.io'), findsOneWidget);
      expect(find.text('external.metrics.k8s.io'), findsOneWidget);
      expect(find.text('k8sman-dev-control-plane'), findsOneWidget);
      expect(find.text('redis-0'), findsOneWidget);
      await saveScreenshot(tester, 'metrics-page-top');
      await tester.tap(find.text('redis-0'));
      await tester.pump();
      expect(app.detail?.name, 'redis-0');
      expect(app.detail?.type.kind, 'Pod');
      for (var w = 360.0; w <= 1800; w += 60) {
        await _resize(tester, w, 760);
        expect(tester.takeException(), isNull, reason: 'overflow at $w');
      }
      await _resize(tester, 380, 760);
      await saveScreenshot(tester, 'metrics-page-top-narrow');
    });

    testWidgets('Top sorts by CPU and by name', (tester) async {
      await _pumpPage(tester, const MetricsPage(), MetricsFakeApi());
      double y(String t) => tester.getTopLeft(find.text(t)).dy;
      // Default: CPU descending. redis-0 (13m+) is busier than no-shell (0m).
      expect(y('redis-0'), lessThan(y('no-shell')));
      await tester.tap(find.text('POD'));
      await tester.pump();
      expect(y('no-shell'), lessThan(y('redis-0')));
    });

    testWidgets('Custom metrics browser', (tester) async {
      await loadRealFonts();
      final api = MetricsFakeApi();
      final app = await _pumpPage(tester, const MetricsPage(), api);
      await tester.tap(find.text('Custom metrics'));
      await tester.pumpAndSettle();
      expect(api.calls, contains('custom'));
      expect(find.text('http_requests_per_second'), findsOneWidget);
      expect(find.text('2500m'), findsOneWidget);
      await saveScreenshot(tester, 'metrics-page-custom');
      await tester.tap(find.textContaining('web-6fd47b8fcb-4r4gm'));
      await tester.pump();
      expect(app.detail?.name, 'web-6fd47b8fcb-4r4gm');
      for (var w = 360.0; w <= 1800; w += 120) {
        await _resize(tester, w, 760);
        expect(tester.takeException(), isNull, reason: 'overflow at $w');
      }
    });

    testWidgets('Custom metrics not installed', (tester) async {
      await _pumpPage(tester, const MetricsPage(), MetricsFakeApi(customMetrics: false));
      expect(find.text('not installed'), findsOneWidget);
      await tester.tap(find.text('Custom metrics'));
      await tester.pumpAndSettle();
      expect(find.text('custom.metrics.k8s.io is not available'), findsOneWidget);
      expect(find.textContaining('prometheus-adapter'), findsOneWidget);
    });

    testWidgets('External metrics browser (KEDA via the HPA reference)', (tester) async {
      await loadRealFonts();
      final app = await _pumpPage(tester, const MetricsPage(), MetricsFakeApi());
      await tester.tap(find.text('External metrics'));
      await tester.pumpAndSettle();
      expect(find.text('s1-cron-Etc-UTC-0xxxx-30xxxx'), findsWidgets);
      expect(find.textContaining('HPA demo/web'), findsOneWidget);
      expect(find.text('Namespace demo'), findsOneWidget);
      await saveScreenshot(tester, 'metrics-page-external');
      await tester.tap(find.textContaining('HPA demo/web'));
      await tester.pump();
      expect(app.detail?.type.kind, 'HorizontalPodAutoscaler');
      for (var w = 360.0; w <= 1800; w += 120) {
        await _resize(tester, w, 760);
        expect(tester.takeException(), isNull, reason: 'overflow at $w');
      }
    });

    testWidgets('without metrics-server', (tester) async {
      await _pumpPage(tester, const MetricsPage(), MetricsFakeApi(resourceMetrics: false));
      expect(find.text('Install metrics-server'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
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
