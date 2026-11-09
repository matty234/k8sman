import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/ui/inspector/inspector.dart';

import '../../support/harness.dart';

Json fixture(String name) => jsonDecode(File('../dev/fixtures/$name.json').readAsStringSync()) as Json;
Json localFixture(String name) => jsonDecode(File('test/panels/storage/fixtures/$name.json').readAsStringSync()) as Json;
Json clone(Json j) => jsonDecode(jsonEncode(j)) as Json;

const scKey = 'storageclasses.storage.k8s.io';

Future<void> openSection(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('pod-section-$id')));
  await tester.pump();
}

void main() {
  late Json pvc, pv, sc, sts, pod;

  setUp(() {
    SectionMemory.reset();
    pvc = fixture('pvc-data-redis-0');
    pv = fixture('pv-redis');
    sc = fixture('sc-standard');
    sts = fixture('sts-redis');
    pod = localFixture('pod-redis-0');
  });

  FakeApiClient api({List<Json>? pods, List<Json>? pvcs, List<Json>? pvs, Json? storageClass}) => FakeApiClient(
        itemsByResource: {
          'pods': pods ?? [pod],
          'statefulsets.apps': [sts],
          'persistentvolumeclaims': pvcs ?? [pvc],
          'persistentvolumes': pvs ?? [pv],
          scKey: [sc],
        },
        objects: {'$scKey//standard': storageClass ?? sc},
      );

  group('PVC', () {
    testWidgets('bound claim: capacity, links, mounted by, statefulset', (tester) async {
      final app = await pumpPanel(tester, pvc, api: api());

      expect(find.text('Bound'), findsOneWidget);
      expect(find.text('requested'), findsNothing); // same as provisioned
      expect(find.text('provisioned'), findsOneWidget);
      expect(find.text('RWO'), findsOneWidget);
      expect(find.textContaining('read-write by pods on a single node', findRichText: true), findsOneWidget);
      expect(find.text('standard'), findsOneWidget);
      expect(find.text('redis #0'), findsOneWidget); // the collapsed summary
      await openSection(tester, 'pvc-created-by');
      expect(find.text('StatefulSet redis'), findsOneWidget);
      expect(find.textContaining('template "data", replica #0'), findsOneWidget);
      // Mounted by
      expect(find.text('redis-0'), findsOneWidget);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('/data'), findsOneWidget);
      expect(find.textContaining('Pending:'), findsNothing);

      await openSection(tester, 'pvc-volume');
      await tester.tap(find.text('pvc-9d785c8b-67b1-49c9-90b9-2b58c4e2b9cb').last); // the link, under its summary
      expect(app.detail?.type.kind, 'PersistentVolume');
      expect(app.detail?.name, 'pvc-9d785c8b-67b1-49c9-90b9-2b58c4e2b9cb');
    });

    testWidgets('pending with WaitForFirstConsumer explains waiting for a pod', (tester) async {
      final p = clone(pvc);
      p['spec'].remove('volumeName');
      p['metadata']['annotations'].remove('volume.kubernetes.io/selected-node');
      p['status'] = {'phase': 'Pending'};
      await pumpPanel(tester, p, api: api(pods: []));
      expect(find.text('Pending: waiting for a pod to be scheduled'), findsOneWidget);
      expect(find.textContaining('No pod in this namespace uses this claim'), findsOneWidget);
    });

  });

  group('PV', () {

  });

  group('StorageClass', () {

  });

}
