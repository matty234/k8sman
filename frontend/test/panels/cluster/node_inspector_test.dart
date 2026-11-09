import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/pod/pod_section.dart';

import '../../support/harness.dart';

dynamic _load(String path) => jsonDecode(File(path).readAsStringSync());

void main() {
  setUp(PodSectionMemory.reset);

  testWidgets('Node: status header, pods first by problem, collapsed summaries, clean at 320px', (tester) async {
    final node = Json.from(_load('../dev/fixtures/node-k8sman-dev-control-plane.json'));
    node['spec'] = {...node['spec'] as Map, 'unschedulable': true};
    final pods = [for (final p in _load('test/panels/cluster/fixtures/pods-on-node.json')) Json.from(p)];
    await pumpPanel(tester, node, api: FakeApiClient(itemsByResource: {'pods': pods}), size: const Size(320, 2400));
    expect(tester.takeException(), isNull);

    // Header: Ready with the cordoned chip and insight; requests against
    // allocatable (no live metrics here) and pods used of capacity.
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Cordoned'), findsOneWidget);
    expect(find.text('Cordoned: SchedulingDisabled'), findsOneWidget);
    expect(find.text('cpu req'), findsOneWidget);
    expect(find.text('pods'), findsOneWidget);

    // Pods: problems first.
    final rows = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('pod-row-'));
    final first = (tester.widget(rows.first).key! as ValueKey<String>).value;
    expect(first, anyOf('pod-row-demo/bad-image', 'pod-row-demo/crashy'));

    // Reference detail collapsed behind one-line summaries.
    expect(find.text('all OK'), findsOneWidget); // Conditions
    expect(find.text('unschedulable'), findsNothing); // no taints on this copy
    expect(find.text('none'), findsWidgets); // Taints
    expect(find.text('MemoryPressure'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('pod-section-node-conditions')));
    await tester.pump();
    expect(find.text('MemoryPressure'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
