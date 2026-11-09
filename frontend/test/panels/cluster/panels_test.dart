import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/ui/inspector/inspector.dart';

import '../../support/harness.dart';

dynamic _load(String path) => jsonDecode(File(path).readAsStringSync());
Json _dev(String name) => Json.from(_load('../dev/fixtures/$name.json'));
List<Json> _local(String name) => [for (final i in _load('test/panels/cluster/fixtures/$name.json')) Json.from(i)];

void main() {
  setUp(SectionMemory.reset);

  testWidgets('Node: status, allocation, pods, system info', (tester) async {
    final node = _dev('node-k8sman-dev-control-plane');
    // Cordon + taint it to exercise the prominent states.
    node['spec'] = {
      ...node['spec'] as Map,
      'unschedulable': true,
      'taints': [
        {'key': 'node.kubernetes.io/unschedulable', 'effect': 'NoSchedule', 'timeAdded': '2026-11-03T11:30:00Z'},
        {'key': 'dedicated', 'value': 'gpu', 'effect': 'NoExecute'},
      ],
    };
    for (final id in ['node-conditions', 'node-taints', 'node-allocation', 'node-system', 'node-images']) {
      SectionMemory.set(id, true);
    }
    final app = await pumpPanel(tester, node, api: FakeApiClient(itemsByResource: {'pods': _local('pods-on-node')}));

    expect(find.text('Cordoned: SchedulingDisabled'), findsOneWidget);
    expect(find.text('Ready'), findsWidgets);
    expect(find.text('MemoryPressure'), findsOneWidget);
    expect(find.textContaining('control-plane ·'), findsOneWidget);
    expect(find.text('dedicated=gpu:NoExecute'), findsOneWidget);
    expect(find.text('172.18.0.2'), findsOneWidget);
    // Allocation: 1060m of 10 cores; 15 of 110 pods.
    expect(find.text('1.06 / 10'), findsOneWidget);
    expect(find.text('15 / 110'), findsOneWidget);
    expect(find.text('370 MiB / 7.7 GiB'), findsOneWidget);
    expect(find.text('3 completed/failed pods not shown'), findsOneWidget);
    expect(find.text('containerd://1.6.8'), findsWidgets);
    expect(find.text('registry.k8s.io/etcd:3.5.4-0'), findsOneWidget);

    if (find.text('coredns-565d847f94-qfldd').evaluate().isEmpty) {
      await tester.tap(find.byKey(const ValueKey('show-more')));
      await tester.pump();
    }
    await tester.tap(find.text('coredns-565d847f94-qfldd'));
    await tester.pump();
    expect(app.detail?.name, 'coredns-565d847f94-qfldd');
    expect(app.detail?.namespace, 'kube-system');
  });

  testWidgets('Namespace: inventory, quotas, warnings', (tester) async {
    final ns = _dev('ns-demo');
    final inv = (_load('test/panels/cluster/fixtures/ns-demo-inventory.json') as Map).map((k, v) => MapEntry(k as String, [for (final i in v) Json.from(i)]));
    final api = FakeApiClient(
      itemsByResource: {
        ...inv,
        'resourcequotas': [_quota()],
        'limitranges': [_limitRange()],
      },
      eventItems: [for (final e in _load('../dev/fixtures/events-demo.json')) Json.from(e)],
    );
    SectionMemory.set('ns-quotas', true);
    final app = await pumpPanel(tester, ns, api: api);

    expect(find.text('Pods'), findsOneWidget);
    expect(find.text('ResourceQuota/compute'), findsOneWidget);
    expect(find.text('BackOff'), findsWidgets);
    expect(find.text('Normal'), findsNothing); // only warnings

    await tester.tap(find.byKey(const ValueKey('inventory-deployments')));
    await tester.pump();
    expect(app.namespace, 'demo');
    expect(app.selectedType?.kind, 'Deployment');
  });

}

Json _quota() => {
      'apiVersion': 'v1',
      'kind': 'ResourceQuota',
      'metadata': {'name': 'compute', 'namespace': 'demo', 'uid': 'q1'},
      'spec': {
        'hard': {'requests.cpu': '2', 'requests.memory': '2Gi', 'limits.memory': '4Gi', 'pods': '10', 'count/deployments.apps': '5', 'requests.storage': '10Gi'},
        'scopes': ['NotTerminating'],
        'scopeSelector': {
          'matchExpressions': [
            {'scopeName': 'PriorityClass', 'operator': 'In', 'values': ['high']},
          ],
        },
      },
      'status': {
        'hard': {'requests.cpu': '2', 'requests.memory': '2Gi', 'limits.memory': '4Gi', 'pods': '10', 'count/deployments.apps': '5', 'requests.storage': '10Gi'},
        'used': {'requests.cpu': '750m', 'requests.memory': '1900Mi', 'limits.memory': '3Gi', 'pods': '9', 'count/deployments.apps': '1', 'requests.storage': '1Gi'},
      },
    };

Json _limitRange() => {
      'apiVersion': 'v1',
      'kind': 'LimitRange',
      'metadata': {'name': 'defaults', 'namespace': 'demo', 'uid': 'l1'},
      'spec': {
        'limits': [
          {
            'type': 'Container',
            'default': {'cpu': '500m', 'memory': '256Mi'},
            'defaultRequest': {'cpu': '100m', 'memory': '128Mi'},
            'min': {'cpu': '10m', 'memory': '16Mi'},
            'max': {'cpu': '2', 'memory': '2Gi'},
            'maxLimitRequestRatio': {'cpu': '4'},
          },
          {
            'type': 'Pod',
            'max': {'cpu': '4', 'memory': '4Gi'},
          },
          {
            'type': 'PersistentVolumeClaim',
            'min': {'storage': '256Mi'},
            'max': {'storage': '50Gi'},
          },
        ],
      },
    };
