import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/network/service_panel.dart';
import 'package:k8sman/ui/inspector/inspector.dart';
import 'package:k8sman/util/k8s.dart';

import '../../support/harness.dart';
import 'net_support.dart';

FakeApiClient api({List<Json>? slices, List<Json>? pods}) => FakeApiClient(
      itemsByResource: {
        'endpointslices.discovery.k8s.io': slices ?? [devFixture('endpointslice-web'), Map<String, dynamic>.from(netFixture('endpointslice-redis'))],
        'pods': pods ?? demoPods(),
      },
      itemsFilter: labelSelectorFilter,
    );

void main() {
  setUp(SectionMemory.reset);

  testWidgets('web: ports resolve named targetPort, endpoints, access hints', (tester) async {
    final app = await pumpPanel(tester, devFixture('svc-web'), api: api());
    expect(find.textContaining('http → 8080', findRichText: true), findsOneWidget);
    expect(find.text('web.demo.svc.cluster.local'), findsOneWidget);
    expect(find.text('2 ready endpoints of 2'), findsOneWidget);
    expect(find.text('10.244.0.5'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pod-section-svc-access')));
    await tester.pump();
    expect(find.text('kubectl -n demo port-forward svc/web 80:80'), findsOneWidget);
    await tester.tap(find.text('web-6fd47b8fcb-4v4m9'));
    expect(app.detail?.name, 'web-6fd47b8fcb-4v4m9');
    expect(app.detail?.type.kind, 'Pod');
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
  });

  test('resolveTargetPort: numeric, named via pod, named via slice, unresolved', () {
    final pods = demoPods().where((p) => p['metadata']['labels']?['app'] == 'web').toList();
    expect(resolveTargetPort({'port': 80, 'targetPort': 8080}).text, '8080');
    expect(resolveTargetPort({'name': 'http', 'port': 80, 'targetPort': 'http'}, pods: pods).text, 'http → 8080');
    expect(resolveTargetPort({'name': 'http', 'port': 80, 'targetPort': 'http'}, slices: [devFixture('endpointslice-web')]).text, 'http → 8080');
    final bad = resolveTargetPort({'name': 'x', 'port': 80, 'targetPort': 'nope'}, pods: pods);
    expect(bad.unresolved, isTrue);
  });

}
