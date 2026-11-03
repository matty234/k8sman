import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/prometheus/metric_history_chart.dart';
import 'package:k8sman/prometheus/prom_api.dart';

import '../support/harness.dart';
import '../support/screenshot.dart';
import 'prom_fixtures.dart';

Map<String, dynamic> devFixture(String name) => Map<String, dynamic>.from(jsonDecode(File('../dev/fixtures/$name').readAsStringSync()) as Map);

void main() {
  late FixturePromApi prom;
  setUp(() {
    prom = FixturePromApi();
    PromApi.debugOverride = (_) => prom;
  });
  tearDown(() => PromApi.debugOverride = null);

  testWidgets('pod panel shows CPU and memory history with hover values', (tester) async {
    await loadRealFonts();
    await pumpPanel(tester, devFixture('pod-web.json'), size: const Size(560, 1600));
    expect(find.text('Metrics history'), findsOneWidget);
    expect(find.text('CPU'), findsOneWidget);
    expect(find.text('Memory'), findsOneWidget);
    expect(find.byType(AreaChart), findsNWidgets(2));
    expect(find.textContaining('now '), findsNWidgets(2));
    // Scroll the charts into view and hover the CPU chart.
    await tester.ensureVisible(find.text('Metrics history'));
    await tester.pumpAndSettle();
    final chart = find.byType(AreaChart).first;
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: tester.getCenter(chart));
    await gesture.moveTo(tester.getCenter(chart) + const Offset(60, 0));
    await tester.pump();
    expect(find.text('CPU'), findsNWidgets(2)); // chart title + tooltip row
    await saveScreenshot(tester, 'pod-history');
    await gesture.removePointer();

    // Per-container breakdown.
    await tester.tap(find.text('Per container'));
    await tester.pumpAndSettle();
    expect(find.text('nginx'), findsWidgets);
    expect(find.text('log-sidecar'), findsWidgets);
    expect(tester.takeException(), isNull);
    await saveScreenshot(tester, 'pod-history-containers');
  });

  testWidgets('node panel shows history', (tester) async {
    await pumpPanel(tester, devFixture('node-k8sman-dev-control-plane.json'), size: const Size(560, 2400));
    expect(find.text('Metrics history'), findsOneWidget);
    expect(find.byType(AreaChart), findsNWidgets(2));
  });

  testWidgets('hidden when no Prometheus is reachable', (tester) async {
    prom = FixturePromApi(missing: true);
    await pumpPanel(tester, devFixture('pod-web.json'));
    expect(find.text('Metrics history'), findsNothing);
  });

  test('range steps stay near 240 points with a safe rate window', () {
    expect(stepFor(const Duration(hours: 1)), (step: const Duration(seconds: 15), window: '2m'));
    expect(stepFor(const Duration(days: 7)).step, const Duration(seconds: 2520));
    expect(stepFor(const Duration(days: 7)).window, '168m');
    expect(formatMetric(0.0123, MetricUnit.cores), '12m');
    expect(formatMetric(1.5, MetricUnit.cores), '1.50');
    expect(formatMetric(5.5 * 1024 * 1024, MetricUnit.bytes), '5.5 MiB');
  });

  testWidgets('pod queries select the pod and skip the pause container', (tester) async {
    await pumpPanel(tester, devFixture('pod-web.json'));
    final cpu = prom.queries.firstWhere((q) => q.contains('container_cpu_usage_seconds_total'));
    expect(cpu, contains('namespace="demo",pod="web-6fd47b8fcb-4v4m9"'));
    expect(cpu, contains('container!="POD"'));
    expect(cpu, contains('[2m]'));
  });
}
