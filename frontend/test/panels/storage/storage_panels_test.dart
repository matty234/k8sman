import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/storage/pvc_panel.dart';
import 'package:k8sman/ui/inspector/inspector.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';

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
      await loadRealFonts();
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
      await loadRealFonts();
      final p = clone(pvc);
      p['spec'].remove('volumeName');
      p['metadata']['annotations'].remove('volume.kubernetes.io/selected-node');
      p['status'] = {'phase': 'Pending'};
      await pumpPanel(tester, p, api: api(pods: []));
      expect(find.text('Pending: waiting for a pod to be scheduled'), findsOneWidget);
      expect(find.textContaining('No pod in this namespace uses this claim'), findsOneWidget);
    });

    test('findMounts handles init containers and subPath', () {
      final p = clone(pod);
      (p['spec']['initContainers'] = [
        {
          'name': 'init',
          'volumeMounts': [
            {'name': 'data', 'mountPath': '/seed', 'subPath': 'x'}
          ]
        }
      ]);
      final m = findMounts([p], 'data-redis-0');
      expect(m, hasLength(1));
      expect(m.single.mounts.map((e) => e.$2), ['/seed', '/data']);
      expect(m.single.mounts.first.$5, isTrue);
    });
  });

  group('PV', () {

    testWidgets('CSI volume with attributes and secret ref', (tester) async {
      await loadRealFonts();
      final p = clone(pv);
      (p['spec'] as Map).remove('hostPath');
      p['spec']['persistentVolumeReclaimPolicy'] = 'Retain';
      p['spec']['mountOptions'] = ['noatime', 'discard'];
      p['spec']['nodeAffinity'] = {
        'required': {
          'nodeSelectorTerms': [
            {
              'matchExpressions': [
                {'key': 'topology.ebs.csi.aws.com/zone', 'operator': 'In', 'values': ['eu-west-1a', 'eu-west-1b']}
              ]
            }
          ]
        }
      };
      p['spec']['csi'] = {
        'driver': 'ebs.csi.aws.com',
        'volumeHandle': 'vol-0a1b2c3d4e5f67890',
        'fsType': 'ext4',
        'volumeAttributes': {'storage.kubernetes.io/csiProvisionerIdentity': '1730000000000-1234-ebs.csi.aws.com', 'type': 'gp3'},
        'nodeStageSecretRef': {'name': 'ebs-creds', 'namespace': 'kube-system'},
      };
      p['status'] = {'phase': 'Released'};
      await pumpPanel(tester, p, api: api());
      expect(find.text('Source · CSI'), findsOneWidget);
      await openSection(tester, 'pv-source');
      await openSection(tester, 'pv-affinity');
      expect(find.text('ebs.csi.aws.com'), findsNWidgets(2)); // the summary and the driver
      expect(find.text('vol-0a1b2c3d4e5f67890'), findsOneWidget);
      expect(find.text('gp3'), findsOneWidget);
      expect(find.text('kube-system/ebs-creds'), findsOneWidget);
      expect(find.text('Released'), findsWidgets);
      expect(find.textContaining('Reclaim policy is Retain'), findsOneWidget);
      expect(find.text('Reclaim policy: Delete'), findsNothing);
      expect(find.text('Mount options'), findsOneWidget);
      expect(find.text('eu-west-1b'), findsOneWidget);
    });

  });

  group('StorageClass', () {
    testWidgets('default class with usage', (tester) async {
      await loadRealFonts();
      final pending = clone(pvc);
      pending['metadata']['name'] = 'scratch';
      pending['metadata']['namespace'] = 'tools';
      pending['spec']['resources']['requests']['storage'] = '512Mi';
      pending['status'] = {'phase': 'Pending'};
      final other = clone(pvc);
      other['metadata']['name'] = 'elsewhere';
      other['spec']['storageClassName'] = 'fast';
      final app = await pumpPanel(tester, sc, api: api(pvcs: [pvc, pending, other]));
      expect(find.text('default'), findsOneWidget);
      expect(find.text('WaitForFirstConsumer'), findsOneWidget);
      expect(find.textContaining('only once a pod using the claim is scheduled'), findsOneWidget);
      expect(find.text('claims'), findsOneWidget);
      expect(find.text('1.5 GiB'), findsOneWidget);
      expect(find.text('demo/data-redis-0'), findsWidgets);
      expect(find.text('tools/scratch'), findsOneWidget);
      expect(find.text('demo/elsewhere'), findsNothing);
      expect(find.text('pvc-9d785c8b-67b1-49c9-90b9-2b58c4e2b9cb'), findsOneWidget);

      await tester.tap(find.text('tools/scratch'));
      expect(app.detail?.name, 'scratch');
      expect(app.detail?.namespace, 'tools');
    });

  });

}
