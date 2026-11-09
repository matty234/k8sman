import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/pod/pod_section.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';

Json _json(String path) => jsonDecode(File(path).readAsStringSync()) as Json;

void main() {
  setUp(PodSectionMemory.reset);

  testWidgets('PVC: status header, mounted-by rows, volume and creator collapsed behind summaries, clean at 320', (tester) async {
    await loadRealFonts();
    final sc = _json('../dev/fixtures/sc-standard.json');
    final api = FakeApiClient(
      itemsByResource: {
        'pods': [_json('test/panels/storage/fixtures/pod-redis-0.json')],
        'statefulsets.apps': [_json('../dev/fixtures/sts-redis.json')],
      },
      objects: {'storageclasses.storage.k8s.io//standard': sc},
    );
    final pvc = _json('../dev/fixtures/pvc-data-redis-0.json');
    for (final width in [560.0, 320.0]) {
      await pumpPanel(tester, pvc, api: api, size: Size(width, 1600));
      expect(tester.takeException(), isNull, reason: 'overflow at $width');

      expect(find.text('Bound'), findsOneWidget);
      for (final label in ['provisioned', 'requested']) {
        expect(find.byKey(ValueKey('figure-$label')), findsOneWidget, reason: label);
      }
      expect(find.text('standard'), findsOneWidget); // class
      expect(find.text('Usage'), findsOneWidget);
      expect(find.byKey(const ValueKey('pvc-mount-redis-0')), findsOneWidget);
      // Reference detail collapsed behind one-line summaries.
      expect(find.text('pvc-9d785c8b-67b1-49c9-90b9-2b58c4e2b9cb'), findsOneWidget);
      expect(find.text('redis #0'), findsOneWidget);
      expect(find.text('StatefulSet redis'), findsNothing);
    }

    // Pending: amber, with the reason as an insight.
    final pending = jsonDecode(jsonEncode(pvc)) as Json;
    pending['status'] = {'phase': 'Pending'};
    (pending['spec'] as Map).remove('volumeName');
    await pumpPanel(tester, pending, api: api, size: const Size(320, 1600));
    expect(tester.takeException(), isNull);
    expect(find.text('Pending'), findsOneWidget);
    expect(find.text('Pending: waiting for the provisioner'), findsOneWidget);
    expect(find.text('not bound'), findsOneWidget);
  });
}
