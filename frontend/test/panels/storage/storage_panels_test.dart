import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/storage/pv_panel.dart';
import 'package:k8sman/panels/storage/pvc_panel.dart';
import 'package:k8sman/panels/storage/sc_panel.dart';
import 'package:k8sman/panels/registry.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';

Json fixture(String name) => jsonDecode(File('../dev/fixtures/$name.json').readAsStringSync()) as Json;
Json localFixture(String name) => jsonDecode(File('test/panels/storage/fixtures/$name.json').readAsStringSync()) as Json;
Json clone(Json j) => jsonDecode(jsonEncode(j)) as Json;

const scKey = 'storageclasses.storage.k8s.io';

void main() {
  late Json pvc, pv, sc, sts, pod;

  setUp(() {
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
      await saveScreenshot(tester, 'storage-pvc-bound');

      expect(find.text('Claim'), findsOneWidget);
      expect(find.text('requested'), findsOneWidget);
      expect(find.text('provisioned'), findsOneWidget);
      expect(find.text('RWO'), findsOneWidget);
      expect(find.textContaining('read-write by pods on a single node', findRichText: true), findsOneWidget);
      expect(find.text('standard'), findsOneWidget);
      expect(find.text('StatefulSet redis'), findsOneWidget);
      expect(find.textContaining('template "data", replica #0'), findsOneWidget);
      // Mounted by
      expect(find.text('redis-0'), findsOneWidget);
      expect(find.text('Running'), findsOneWidget);
      expect(find.text('/data'), findsOneWidget);
      expect(find.textContaining('Pending:'), findsNothing);

      await tester.tap(find.text('pvc-9d785c8b-67b1-49c9-90b9-2b58c4e2b9cb'));
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
      await saveScreenshot(tester, 'storage-pvc-pending');
      expect(find.text('Pending: waiting for a pod to be scheduled'), findsOneWidget);
      expect(find.textContaining('No pod in this namespace uses this claim'), findsOneWidget);
    });

    testWidgets('pending with Immediate class points at provisioner events', (tester) async {
      final p = clone(pvc);
      p['spec'].remove('volumeName');
      p['status'] = {'phase': 'Pending'};
      final immediate = clone(sc)..['volumeBindingMode'] = 'Immediate';
      await pumpPanel(tester, p, api: api(storageClass: immediate));
      expect(find.text('Pending: waiting for the provisioner'), findsOneWidget);
      expect(find.textContaining('Events tab'), findsOneWidget);
    });

    testWidgets('pending with missing class', (tester) async {
      final p = clone(pvc);
      p['spec']
        ..remove('volumeName')
        ..['storageClassName'] = 'fast';
      p['status'] = {'phase': 'Pending'};
      await pumpPanel(tester, p, api: api());
      expect(find.text('Pending: StorageClass "fast" does not exist'), findsOneWidget);
    });

    testWidgets('RWO claim on two nodes warns about multi-attach', (tester) async {
      final other = clone(pod);
      other['metadata']['name'] = 'redis-debug';
      other['spec']['nodeName'] = 'worker-2';
      await pumpPanel(tester, pvc, api: api(pods: [pod, other]));
      expect(find.text('ReadWriteOnce claim used on 2 nodes'), findsOneWidget);
      expect(find.text('worker-2'), findsOneWidget);
    });

    testWidgets('resize in progress', (tester) async {
      final p = clone(pvc);
      p['spec']['resources']['requests']['storage'] = '5Gi';
      p['status']['allocatedResources'] = {'storage': '5Gi'};
      p['status']['allocatedResourceStatuses'] = {'storage': 'NodeResizePending'};
      p['status']['conditions'] = [
        {'type': 'FileSystemResizePending', 'status': 'True', 'lastTransitionTime': '2026-11-03T11:30:00Z'}
      ];
      await pumpPanel(tester, p, api: api());
      expect(find.text('Resize in progress: 1Gi to 5Gi'), findsOneWidget);
      expect(find.text('Conditions'), findsOneWidget);
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
    testWidgets('hostPath volume from kind', (tester) async {
      await loadRealFonts();
      final app = await pumpPanel(tester, pv, api: api());
      await saveScreenshot(tester, 'storage-pv-hostpath');
      expect(find.text('Source · hostPath'), findsOneWidget);
      expect(find.text('Reclaim policy: Delete'), findsOneWidget);
      expect(find.text('demo/data-redis-0'), findsOneWidget);
      expect(find.text('k8sman-dev-control-plane'), findsOneWidget);
      expect(find.text('rancher.io/local-path'), findsOneWidget);

      await tester.tap(find.text('k8sman-dev-control-plane'));
      expect(app.detail?.type.kind, 'Node');
    });

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
      await saveScreenshot(tester, 'storage-pv-csi');
      expect(find.text('Source · CSI'), findsOneWidget);
      expect(find.text('ebs.csi.aws.com'), findsOneWidget);
      expect(find.text('vol-0a1b2c3d4e5f67890'), findsOneWidget);
      expect(find.text('gp3'), findsOneWidget);
      expect(find.text('kube-system/ebs-creds'), findsOneWidget);
      expect(find.text('Released'), findsWidgets);
      expect(find.textContaining('Reclaim policy is Retain'), findsOneWidget);
      expect(find.text('Reclaim policy: Delete'), findsNothing);
      expect(find.text('Mount options'), findsOneWidget);
      expect(find.text('eu-west-1b'), findsOneWidget);
    });

    testWidgets('NFS volume and failed phase', (tester) async {
      final p = clone(pv);
      (p['spec'] as Map)
        ..remove('hostPath')
        ..remove('nodeAffinity');
      p['spec']['nfs'] = {'server': '10.0.0.5', 'path': '/exports/data', 'readOnly': true};
      p['status'] = {'phase': 'Failed', 'message': 'recycler pod failed'};
      await pumpPanel(tester, p, api: api());
      expect(find.text('Source · NFS'), findsOneWidget);
      expect(find.text('10.0.0.5:/exports/data'), findsOneWidget);
      expect(find.text('read-only'), findsOneWidget);
      expect(find.textContaining('recycler pod failed'), findsOneWidget);
      expect(find.text('Node affinity'), findsNothing);
    });

    test('source detection covers fallback types', () {
      expect(detectPvSource({'capacity': {}, 'cephfs': {'monitors': ['a']}})?.$1, 'cephfs');
      expect(detectPvSource({'capacity': {}, 'claimRef': {}}), isNull);
    });

    testWidgets('generic source fallback renders fields', (tester) async {
      final p = clone(pv);
      (p['spec'] as Map).remove('hostPath');
      p['spec']['rbd'] = {'image': 'img1', 'monitors': ['10.0.0.1:6789']};
      await pumpPanel(tester, p, api: api());
      expect(find.text('Source · Ceph RBD'), findsOneWidget);
      expect(find.text('img1'), findsOneWidget);
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
      await saveScreenshot(tester, 'storage-sc-standard');
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

    testWidgets('parameters and topologies', (tester) async {
      final s = clone(sc);
      s['parameters'] = {'type': 'gp3', 'iops': '3000'};
      s['allowVolumeExpansion'] = true;
      s['allowedTopologies'] = [
        {
          'matchLabelExpressions': [
            {'key': 'topology.kubernetes.io/zone', 'values': ['eu-west-1a']}
          ]
        }
      ];
      (s['metadata']['annotations'] as Map).clear();
      await pumpPanel(tester, s, api: api(pvcs: [], pvs: []));
      expect(find.text('3000'), findsOneWidget);
      expect(find.text('allowed'), findsOneWidget);
      expect(find.text('eu-west-1a'), findsOneWidget);
      expect(find.text('default'), findsNothing);
      expect(find.text('No claims or volumes use this class.'), findsOneWidget);
    });
  });

  test('panels are registered for all three kinds', () {
    expect(panelFor(testType('', 'PersistentVolumeClaim')), isA<PvcPanel>());
    expect(panelFor(testType('', 'PersistentVolume')), isA<PvPanel>());
    expect(panelFor(testType('storage.k8s.io', 'StorageClass')), isA<StorageClassPanel>());
  });
}
