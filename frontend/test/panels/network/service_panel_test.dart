import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/network/service_panel.dart';
import 'package:k8sman/util/k8s.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';
import 'net_support.dart';

FakeApiClient api({List<Json>? slices, List<Json>? pods}) => FakeApiClient(
      itemsByResource: {
        'endpointslices.discovery.k8s.io': slices ?? [devFixture('endpointslice-web'), Map<String, dynamic>.from(netFixture('endpointslice-redis'))],
        'pods': pods ?? demoPods(),
      },
      itemsFilter: labelSelectorFilter,
    );

void main() {
  testWidgets('web: ports resolve named targetPort, endpoints, access hints', (tester) async {
    await loadRealFonts();
    final app = await pumpPanel(tester, devFixture('svc-web'), api: api());
    await saveScreenshot(tester, 'network-svc-web');
    expect(find.text('http → 8080'), findsOneWidget);
    expect(find.text('web.demo.svc.cluster.local'), findsOneWidget);
    expect(find.text('kubectl -n demo port-forward svc/web 80:80'), findsOneWidget);
    expect(find.text('2/2 ready'), findsOneWidget);
    expect(find.text('10.244.0.5'), findsOneWidget);
    await tester.tap(find.text('Pod/web-6fd47b8fcb-4v4m9'));
    expect(app.detail?.name, 'web-6fd47b8fcb-4v4m9');
    expect(app.detail?.type.kind, 'Pod');
  });

  testWidgets('web-nodeport shows nodePort column and traffic policy', (tester) async {
    await loadRealFonts();
    await pumpPanel(tester, devFixture('svc-web-nodeport'), api: api(slices: []));
    await saveScreenshot(tester, 'network-svc-web-nodeport');
    expect(find.text('NODEPORT'), findsOneWidget);
    expect(find.text('30080'), findsOneWidget);
    expect(find.text('External traffic'), findsOneWidget);
  });

  testWidgets('redis headless shows note and per-pod DNS', (tester) async {
    await loadRealFonts();
    await pumpPanel(tester, Map<String, dynamic>.from(netFixture('svc-redis')), api: api());
    await saveScreenshot(tester, 'network-svc-redis');
    expect(find.text('Headless'), findsOneWidget);
    expect(find.text('redis-0.redis.demo.svc.cluster.local'), findsOneWidget);
  });

  testWidgets('diagnosis: pods match but none ready', (tester) async {
    await loadRealFonts();
    final svc = devFixture('svc-web')
      ..['metadata']['name'] = 'crashy'
      ..['spec']['selector'] = {'app': 'crashy'};
    await pumpPanel(tester, svc, api: api());
    await saveScreenshot(tester, 'network-svc-crashy');
    expect(find.text('1 pod matches but it is not ready'), findsOneWidget);
    expect(find.text('Pod/crashy'), findsOneWidget);
  });

  group('diagnoseService', () {
    final svc = devFixture('svc-web');
    test('selector matches 0 pods', () {
      expect(diagnoseService(svc, const ServiceBackends(slices: [], pods: []))?.title, 'Selector matches 0 pods');
    });
    test('pods match but none ready', () {
      final pods = demoPods().where((p) => p['metadata']['name'] == 'crashy').toList();
      expect(diagnoseService(svc, ServiceBackends(slices: const [], pods: pods))?.title, '1 pod matches but it is not ready');
    });
    test('no selector', () {
      final noSel = devFixture('svc-web')..['spec'].remove('selector');
      final d = diagnoseService(noSel, const ServiceBackends(slices: []));
      expect(d?.title, 'Service has no selector (manual endpoints)');
      expect(d?.severity, Severity.error);
    });
    test('healthy returns null', () {
      expect(diagnoseService(svc, ServiceBackends(slices: [devFixture('endpointslice-web')], pods: demoPods())), isNull);
    });
  });

  test('resolveTargetPort: numeric, named via pod, named via slice, unresolved', () {
    final pods = demoPods().where((p) => p['metadata']['labels']?['app'] == 'web').toList();
    expect(resolveTargetPort({'port': 80, 'targetPort': 8080}).text, '8080');
    expect(resolveTargetPort({'name': 'http', 'port': 80, 'targetPort': 'http'}, pods: pods).text, 'http → 8080');
    expect(resolveTargetPort({'name': 'http', 'port': 80, 'targetPort': 'http'}, slices: [devFixture('endpointslice-web')]).text, 'http → 8080');
    final bad = resolveTargetPort({'name': 'x', 'port': 80, 'targetPort': 'nope'}, pods: pods);
    expect(bad.unresolved, isTrue);
  });

  testWidgets('no selector: diagnosis callout', (tester) async {
    final svc = devFixture('svc-web')..['spec'].remove('selector');
    await pumpPanel(tester, svc, api: api(slices: []));
    expect(find.text('Service has no selector (manual endpoints)'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
