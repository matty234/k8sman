import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';

import '../../support/harness.dart';

Json loadFixture(String name) => jsonDecode(File('../dev/fixtures/$name').readAsStringSync()) as Json;

List<Json> loadLocal(String name) =>
    [for (final e in jsonDecode(File('test/panels/workloads/fixtures/$name').readAsStringSync()) as List) e as Json];

/// Deep copy with edits applied by [edit].
Json clone(Json o, [void Function(Json c)? edit]) {
  final c = jsonDecode(jsonEncode(o)) as Json;
  edit?.call(c);
  return c;
}

FakeApiClient fakeApi(Map<String, List<Json>> items) =>
    FakeApiClient(itemsByResource: items, itemsFilter: labelSelectorFilter);

const pdbType = ResourceType(group: 'policy', version: 'v1', resource: 'poddisruptionbudgets', kind: 'PodDisruptionBudget');

/// Live web RS (rev 1) plus synthetic revisions 2 and 10 and an unrelated RS.
List<Json> deploymentReplicaSets() {
  final live = loadLocal('replicasets-demo.json');
  final rev1 = clone(live.firstWhere((r) => r['metadata']['name'] == 'web-6fd47b8fcb'), (c) {
    c['spec']['replicas'] = 0;
    c['status'] = {'replicas': 0, 'observedGeneration': 2};
  });
  Json rev(int n, String name, String nginx, String ts) => clone(rev1, (c) {
        c['metadata']['name'] = name;
        c['metadata']['uid'] = 'uid-$name';
        c['metadata']['annotations']['deployment.kubernetes.io/revision'] = '$n';
        c['metadata']['creationTimestamp'] = ts;
        (c['spec']['template']['spec']['containers'] as List)[0]['image'] = nginx;
      });
  final rev2 = rev(2, 'web-222', 'nginx:1.27.1-alpine', '2026-11-03T12:00:00Z');
  final rev10 = clone(rev(10, 'web-aaa', 'nginx:1.28-alpine', '2026-11-03T13:00:00Z'), (c) {
    c['spec']['replicas'] = 2;
    c['status'] = {'replicas': 2, 'readyReplicas': 1, 'availableReplicas': 1};
  });
  final stranger = clone(rev10, (c) {
    c['metadata']['name'] = 'web-other';
    c['metadata']['uid'] = 'uid-other';
    c['metadata']['annotations']['deployment.kubernetes.io/revision'] = '99';
    c['metadata']['ownerReferences'][0]['uid'] = 'someone-else';
  });
  return [rev2, rev1, stranger, rev10];
}

/// Opens the collapsed workload section [id] (e.g. `history`, `template`).
Future<void> expandSection(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('pod-section-workload-$id')));
  await tester.pumpAndSettle();
}

/// Moves a mouse over [finder], so row actions shown on hover appear.
Future<void> hover(WidgetTester tester, Finder finder) async {
  final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
  addTearDown(mouse.removePointer);
  await mouse.addPointer(location: Offset.zero);
  await mouse.moveTo(tester.getCenter(finder));
  await tester.pumpAndSettle();
}
