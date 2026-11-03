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
    expect(find.text('Network'), findsOneWidget);
    expect(find.byType(AreaChart), findsNWidgets(3));
    expect(find.textContaining('now '), findsNWidgets(3));
    // Network counters: one series per direction, NIC-deduplicated, no lo.
    final net = prom.queries.firstWhere((q) => q.contains('container_network_receive_bytes_total'));
    expect(net, contains('container_network_transmit_bytes_total'));
    expect(net, contains('max by (interface)'));
    expect(net, contains('interface!="lo"'));
    expect(net, isNot(contains('container!=')));
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

  testWidgets('pod panel puts the metrics charts at the top, above Status', (tester) async {
    await pumpPanel(tester, devFixture('pod-web.json'), size: const Size(560, 2400));
    final chartsY = tester.getTopLeft(find.text('Metrics history')).dy;
    final statusY = tester.getTopLeft(find.text('Status').first).dy;
    final containersY = tester.getTopLeft(find.text('Containers').first).dy;
    expect(chartsY, lessThan(statusY));
    expect(statusY, lessThan(containersY));
  });

  testWidgets('node panel shows history', (tester) async {
    await pumpPanel(tester, devFixture('node-k8sman-dev-control-plane.json'), size: const Size(560, 2400));
    expect(find.text('Metrics history'), findsOneWidget);
    expect(find.byType(AreaChart), findsNWidgets(3));
    expect(prom.queries.where((q) => q.contains('node_network_receive_bytes_total{device!~"lo|veth.*')), hasLength(1));
  });

  testWidgets('deployment panel sums its pods by owner, falling back to the pod-name pattern', (tester) async {
    await pumpPanel(tester, devFixture('deploy-web.json'), size: const Size(560, 3200));
    expect(find.text('Metrics history'), findsOneWidget);
    expect(find.byType(AreaChart), findsNWidgets(3));
    final cpu = prom.queries.firstWhere((q) => q.contains('container_cpu_usage_seconds_total'));
    expect(cpu, contains('kube_pod_owner{namespace="demo",owner_kind="ReplicaSet",owner_name=~"web-[a-z0-9]+"}'));
    expect(cpu, contains(' or sum (sum by (namespace, pod) (rate(container_cpu_usage_seconds_total{namespace="demo",pod=~"web-[a-z0-9]+-[a-z0-9]+"'));
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
