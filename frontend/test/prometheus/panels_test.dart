import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/prometheus/prom_api.dart';
import 'package:k8sman/state/app_state.dart';

import '../support/harness.dart';
import '../support/screenshot.dart';
import 'prom_fixtures.dart';

const _g = 'monitoring.coreos.com';
const ruleType = ResourceType(group: _g, version: 'v1', resource: 'prometheusrules', kind: 'PrometheusRule', custom: true);
const smType = ResourceType(group: _g, version: 'v1', resource: 'servicemonitors', kind: 'ServiceMonitor', custom: true);
const pmType = ResourceType(group: _g, version: 'v1', resource: 'podmonitors', kind: 'PodMonitor', custom: true);
const promType = ResourceType(group: _g, version: 'v1', resource: 'prometheuses', kind: 'Prometheus', custom: true);
const amType = ResourceType(group: _g, version: 'v1', resource: 'alertmanagers', kind: 'Alertmanager', custom: true);

Json obj(String name) => Map<String, dynamic>.from(promFixture(name) as Map);
List<Json> items(String name) => [for (final i in promFixture(name) as List) Map<String, dynamic>.from(i as Map)];

void main() {
  late FixturePromApi prom;
  setUp(() {
    prom = FixturePromApi();
    PromApi.debugOverride = (_) => prom;
  });
  tearDown(() => PromApi.debugOverride = null);

  testWidgets('PrometheusRule shows groups, rules and live state', (tester) async {
    await loadRealFonts();
    final app = await pumpPanel(tester, obj('prometheusrule-k8sman-demo'), type: ruleType, size: const Size(560, 1500));
    expect(tester.takeException(), isNull);
    expect(find.text('k8sman-demo.alerts'), findsOneWidget);
    expect(find.text('k8sman-demo.records'), findsOneWidget);
    expect(find.text('K8smanTestAlert'), findsOneWidget);
    expect(find.text('K8smanDemoPodCrashLooping'), findsOneWidget);
    expect(find.text('vector(1)'), findsOneWidget);
    // Live state from /api/prom/rules: both alerts firing, the record healthy.
    expect(find.text('Firing'), findsNWidgets(2));
    expect(find.text('OK'), findsOneWidget);
    expect(find.textContaining('recording rule'), findsOneWidget);
    await tester.tap(find.text('Open Alerts'));
    expect(app.view, MainView.alerts);
  });

  testWidgets('PrometheusRule without a Prometheus explains calmly', (tester) async {
    prom = FixturePromApi(missing: true);
    await pumpPanel(tester, obj('prometheusrule-k8sman-demo'), type: ruleType);
    expect(find.textContaining('none was found'), findsOneWidget);
    expect(find.text('K8smanTestAlert'), findsOneWidget);
  });

  testWidgets('ServiceMonitor links matching services and shows target health', (tester) async {
    await loadRealFonts();
    final api = FakeApiClient(itemsByResource: {'services': items('services-demo')}, itemsFilter: (r, i, sel, _) => sel == null || (i['metadata']?['labels']?['app'] == 'web'));
    final app = await pumpPanel(tester, obj('servicemonitor-web'), type: smType, api: api, size: const Size(560, 1100));
    expect(tester.takeException(), isNull);
    expect(find.text('app=web'), findsOneWidget);
    expect(find.text('1 matching service'), findsOneWidget);
    expect(find.text('0 up · 2 down', findRichText: true), findsWidgets);
    expect(find.textContaining('unsupported Content-Type'), findsWidgets);
    expect(find.text('http · http/metrics'), findsOneWidget);
    await tester.tap(find.text('web').first);
    await tester.pump();
    expect(app.detail?.type.kind, 'Service');
  });

  testWidgets('PodMonitor looks in its namespaceSelector and shows up targets', (tester) async {
    await loadRealFonts();
    final api = FakeApiClient(itemsByResource: {'pods': items('pods-grafana')});
    await pumpPanel(tester, obj('podmonitor-grafana'), type: pmType, api: api, size: const Size(560, 900));
    expect(tester.takeException(), isNull);
    expect(find.text('monitoring'), findsOneWidget);
    expect(find.text('1 matching pod'), findsOneWidget);
    expect(find.text('1 up · 0 down', findRichText: true), findsWidgets);
  });

  testWidgets('Prometheus and Alertmanager CRs show config and live status', (tester) async {
    await loadRealFonts();
    await pumpPanel(tester, obj('prometheus'), type: promType, size: const Size(560, 1300));
    expect(tester.takeException(), isNull);
    expect(find.text('2d'), findsOneWidget);
    expect(find.text('Reachable'), findsOneWidget);
    expect(find.text('ServiceMonitors'), findsOneWidget);
    expect(find.text('Sends alerts to'), findsOneWidget);

    await pumpPanel(tester, obj('alertmanager'), type: amType, size: const Size(560, 1000));
    expect(tester.takeException(), isNull);
    expect(find.text('24h'), findsOneWidget);
    expect(find.text('Reachable'), findsOneWidget);
    expect(find.text('Open Alerts'), findsOneWidget);
  });

  testWidgets('panels have no overflow from 360 to 900px', (tester) async {
    final api = FakeApiClient(itemsByResource: {'services': items('services-demo'), 'pods': items('pods-grafana')});
    for (final w in [360.0, 560.0, 900.0]) {
      for (final (o, t) in [
        ('prometheusrule-k8sman-demo', ruleType),
        ('servicemonitor-web', smType),
        ('podmonitor-grafana', pmType),
        ('prometheus', promType),
        ('alertmanager', amType),
      ]) {
        await pumpPanel(tester, obj(o), type: t, api: api, size: Size(w, 1600));
        expect(tester.takeException(), isNull, reason: '$o at $w');
      }
    }
  });

  test('fixtures are real captures', () {
    // Guard against hand-edited fixtures drifting from the backend's shape.
    final rules = jsonDecode(File('test/prometheus/fixtures/rules-k8sman-demo.json').readAsStringSync()) as Map;
    expect((rules['groups'] as List).first['source'], {'namespace': 'demo', 'name': 'k8sman-demo'});
  });
}
