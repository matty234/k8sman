import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/panels/pod/pod_section.dart';

import '../../support/harness.dart';
import 'net_support.dart';

void main() {
  setUp(PodSectionMemory.reset);

  testWidgets('Service: status header, collapsed summaries, clean at 320px', (tester) async {
    final svc = devFixture('svc-web')
      ..['metadata']['name'] = 'crashy'
      ..['spec']['selector'] = {'app': 'crashy'};
    final api = FakeApiClient(itemsByResource: {'endpointslices.discovery.k8s.io': [], 'pods': demoPods()}, itemsFilter: labelSelectorFilter);
    await pumpPanel(tester, svc, api: api, size: const Size(320, 2000));
    expect(tester.takeException(), isNull);

    // Header: type, no ready endpoints as a red insight with the selector.
    expect(find.text('ClusterIP'), findsOneWidget);
    expect(find.text('no endpoints'), findsOneWidget);
    expect(find.text('1 pod matches but it is not ready'), findsOneWidget);
    expect(find.textContaining('Selector: app=crashy'), findsOneWidget);

    // Secondary sections collapsed behind a one-line summary.
    expect(find.text('app=crashy'), findsOneWidget); // the Selector summary
    expect(find.text('IPv4 · SingleStack'), findsOneWidget);
    expect(find.text('Session affinity'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pod-section-svc-traffic')));
    await tester.pump();
    expect(find.text('Session affinity'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
