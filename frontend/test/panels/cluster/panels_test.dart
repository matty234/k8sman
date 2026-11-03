import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/ui/widgets/common.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';

dynamic _load(String path) => jsonDecode(File(path).readAsStringSync());
Json _dev(String name) => Json.from(_load('../dev/fixtures/$name.json'));
List<Json> _local(String name) => [for (final i in _load('test/panels/cluster/fixtures/$name.json')) Json.from(i)];

const _rbac = 'rbac.authorization.k8s.io';

void main() {
  setUpAll(loadRealFonts);

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
    final app = await pumpPanel(tester, node, api: FakeApiClient(itemsByResource: {'pods': _local('pods-on-node')}));
    await saveScreenshot(tester, 'cluster-node');

    expect(find.text('Cordoned: SchedulingDisabled'), findsOneWidget);
    expect(find.text('Ready'), findsWidgets);
    expect(find.text('MemoryPressure'), findsOneWidget);
    expect(find.text('control-plane'), findsOneWidget);
    expect(find.text('dedicated=gpu:NoExecute'), findsOneWidget);
    expect(find.text('172.18.0.2'), findsOneWidget);
    // Allocation: 1060m of 10 cores; 15 of 110 pods.
    expect(find.text('1.06 / 10'), findsOneWidget);
    expect(find.text('15 / 110'), findsOneWidget);
    expect(find.text('370 MiB / 7.7 GiB'), findsOneWidget);
    expect(find.text('3 completed/failed pods not shown'), findsOneWidget);
    expect(find.text('containerd://1.6.8'), findsWidgets);
    expect(find.text('registry.k8s.io/etcd:3.5.4-0'), findsOneWidget);

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
    final app = await pumpPanel(tester, ns, api: api);
    await saveScreenshot(tester, 'cluster-namespace');

    expect(find.text('Pods'), findsOneWidget);
    expect(find.text('ResourceQuota/compute'), findsOneWidget);
    expect(find.text('BackOff'), findsWidgets);
    expect(find.text('Normal'), findsNothing); // only warnings

    await tester.tap(find.byKey(const ValueKey('inventory-deployments')));
    await tester.pump();
    expect(app.namespace, 'demo');
    expect(app.selectedType?.kind, 'Deployment');
  });

  testWidgets('Namespace: Terminating explains what blocks deletion', (tester) async {
    final ns = _dev('ns-demo');
    ns['metadata'] = {...ns['metadata'] as Map, 'deletionTimestamp': '2026-11-03T11:40:00Z'};
    ns['status'] = {
      'phase': 'Terminating',
      'conditions': [
        {'type': 'NamespaceContentRemaining', 'status': 'True', 'reason': 'SomeResourcesRemain', 'message': 'Some resources are remaining: widgets.example.k8sman.dev has 1 resource instances'},
        {'type': 'NamespaceFinalizersRemaining', 'status': 'True', 'reason': 'SomeFinalizersRemain', 'message': 'Some content in the namespace has finalizers remaining: example.k8sman.dev/cleanup in 1 resource instances'},
        {'type': 'NamespaceDeletionDiscoveryFailure', 'status': 'False', 'reason': 'ResourcesDiscovered'},
      ],
    };
    await pumpPanel(tester, ns, api: FakeApiClient());
    await saveScreenshot(tester, 'cluster-namespace-terminating');
    expect(find.text('spec: kubernetes'), findsOneWidget);
    expect(find.textContaining('NamespaceContentRemaining'), findsOneWidget);
    expect(find.textContaining('ResourcesDiscovered'), findsNothing);
  });

  testWidgets('Event (core): warning with links', (tester) async {
    final events = [for (final e in _load('../dev/fixtures/events-demo.json')) Json.from(e)];
    final ev = events.firstWhere((e) => e['type'] == 'Warning' && e['reason'] == 'BackOff', orElse: () => events.firstWhere((e) => e['type'] == 'Warning'));
    final app = await pumpPanel(tester, ev, api: FakeApiClient(eventItems: events.where((e) => e['involvedObject']['uid'] == ev['involvedObject']['uid']).toList()));
    await saveScreenshot(tester, 'cluster-event');
    expect(find.text('Warning'), findsWidgets);
    expect(find.text('${ev['message']}'), findsWidgets);
    final link = '${ev['involvedObject']['kind']}/${ev['involvedObject']['name']}';
    await tester.tap(find.text(link));
    await tester.pump();
    expect(app.detail?.name, ev['involvedObject']['name']);
  });

  testWidgets('Event (events.k8s.io): regarding/note/series', (tester) async {
    final ev = <String, dynamic>{
      'apiVersion': 'events.k8s.io/v1',
      'kind': 'Event',
      'metadata': {'name': 'crashy.1', 'namespace': 'demo', 'uid': 'e1', 'creationTimestamp': '2026-11-03T11:23:00Z'},
      'eventTime': '2026-11-03T11:23:00.000000Z',
      'type': 'Warning',
      'reason': 'BackOff',
      'note': 'Back-off restarting failed container crashy in pod crashy_demo',
      'action': 'Restarting',
      'reportingController': 'kubelet',
      'reportingInstance': 'k8sman-dev-control-plane',
      'regarding': {'apiVersion': 'v1', 'kind': 'Pod', 'name': 'crashy', 'namespace': 'demo', 'uid': 'p1', 'fieldPath': 'spec.containers{crashy}'},
      'related': {'apiVersion': 'v1', 'kind': 'Node', 'name': 'k8sman-dev-control-plane'},
      'series': {'count': 42, 'lastObservedTime': '2026-11-03T11:40:00.000000Z'},
      'deprecatedCount': 3,
    };
    final app = await pumpPanel(tester, ev,
        type: const ResourceType(group: 'events.k8s.io', version: 'v1', resource: 'events', kind: 'Event'), api: FakeApiClient());
    await saveScreenshot(tester, 'cluster-event-new');
    expect(find.text('×42'), findsOneWidget);
    expect(find.text('Back-off restarting failed container crashy in pod crashy_demo'), findsOneWidget);
    expect(find.text('spec.containers{crashy}'), findsOneWidget);
    expect(find.text('kubelet'), findsOneWidget);
    await tester.tap(find.text('Node/k8sman-dev-control-plane'));
    await tester.pump();
    expect(app.detail?.name, 'k8sman-dev-control-plane');
  });

  testWidgets('ResourceQuota: bars and scopes', (tester) async {
    await pumpPanel(tester, _quota(),
        type: const ResourceType(group: '', version: 'v1', resource: 'resourcequotas', kind: 'ResourceQuota'), size: const Size(560, 900));
    await saveScreenshot(tester, 'cluster-quota');
    expect(find.text('requests.cpu'), findsOneWidget);
    expect(find.text('750m / 2'), findsOneWidget);
    expect(find.text('38%'), findsOneWidget);
    expect(find.text('NotTerminating'), findsOneWidget);
    expect(find.text('PriorityClass In (high)'), findsOneWidget);
  });

  testWidgets('LimitRange: per-type tables', (tester) async {
    await pumpPanel(tester, _limitRange(),
        type: const ResourceType(group: '', version: 'v1', resource: 'limitranges', kind: 'LimitRange'), size: const Size(560, 700));
    await saveScreenshot(tester, 'cluster-limitrange');
    expect(find.text('Container'), findsOneWidget);
    expect(find.text('PersistentVolumeClaim'), findsOneWidget);
    expect(find.text('256 MiB'), findsWidgets);
    expect(find.text('4'), findsNWidgets(2)); // ratio + pod max cpu
  });

  testWidgets('Role: rules and bound-by', (tester) async {
    final app = await pumpPanel(tester, _dev('role-pod-reader'),
        api: FakeApiClient(itemsByResource: {'rolebindings.$_rbac': _local('rolebindings')}), size: const Size(560, 900));
    await saveScreenshot(tester, 'cluster-role');
    expect(find.text('core'), findsOneWidget);
    expect(find.text('pods, pods/log'), findsOneWidget);
    expect(find.text('dangerous'), findsNothing);
    expect(find.text('web-pod-reader'), findsOneWidget);
    await tester.tap(find.text('demo/web'));
    await tester.pump();
    expect(app.detail?.type.kind, 'ServiceAccount');
  });

  testWidgets('ClusterRole view: aggregation and bindings', (tester) async {
    final rbs = <Json>[
      ..._local('rolebindings'),
      {
        'apiVersion': '$_rbac/v1',
        'kind': 'RoleBinding',
        'metadata': {'name': 'devs-view', 'namespace': 'demo'},
        'roleRef': {'apiGroup': _rbac, 'kind': 'ClusterRole', 'name': 'view'},
        'subjects': [
          {'kind': 'Group', 'apiGroup': _rbac, 'name': 'developers'},
          {'kind': 'User', 'apiGroup': _rbac, 'name': 'jane@example.com'},
        ],
      },
    ];
    final crbs = <Json>[
      ..._local('clusterrolebindings'),
      {
        'apiVersion': '$_rbac/v1',
        'kind': 'ClusterRoleBinding',
        'metadata': {'name': 'auditors-view'},
        'roleRef': {'apiGroup': _rbac, 'kind': 'ClusterRole', 'name': 'view'},
        'subjects': [
          {'kind': 'ServiceAccount', 'name': 'auditor', 'namespace': 'kube-system'},
        ],
      },
    ];
    final app = await pumpPanel(tester, _dev('clusterrole-view'),
        api: FakeApiClient(itemsByResource: {'rolebindings.$_rbac': rbs, 'clusterrolebindings.$_rbac': crbs}), size: const Size(560, 2000));
    await saveScreenshot(tester, 'cluster-clusterrole-view');
    expect(find.text('rbac.authorization.k8s.io/aggregate-to-view=true'), findsOneWidget);
    expect(find.text('edit'), findsOneWidget); // aggregated into
    expect(find.text('devs-view'), findsOneWidget);
    expect(find.text('auditors-view'), findsOneWidget);
    expect(find.text('cluster-admin'), findsNothing); // bound to a different role
    expect(find.text('developers'), findsOneWidget);
    await tester.tap(find.text('edit'));
    await tester.pump();
    expect(app.detail?.name, 'edit');
  });

  testWidgets('RoleBinding: roleRef, subjects, inline rules', (tester) async {
    final app = await pumpPanel(tester, _dev('rolebinding-web-pod-reader'),
        api: FakeApiClient(objects: {'roles.$_rbac/demo/pod-reader': _dev('role-pod-reader')}), size: const Size(560, 900));
    await saveScreenshot(tester, 'cluster-rolebinding');
    expect(find.text('pod-reader'), findsOneWidget);
    expect(find.text('pods, pods/log'), findsOneWidget);
    expect(find.text('get'), findsOneWidget);
    await tester.tap(find.text('pod-reader'));
    await tester.pump();
    expect(app.detail?.type.kind, 'Role');
    expect(app.detail?.namespace, 'demo');
  });

  testWidgets('ClusterRoleBinding: dangerous role and missing role', (tester) async {
    final crb = _local('clusterrolebindings').firstWhere((b) => b['metadata']['name'] == 'cluster-admin');
    final admin = <String, dynamic>{
      'apiVersion': '$_rbac/v1',
      'kind': 'ClusterRole',
      'metadata': {'name': 'cluster-admin'},
      'rules': [
        {'apiGroups': ['*'], 'resources': ['*'], 'verbs': ['*']},
        {'nonResourceURLs': ['*'], 'verbs': ['*']},
      ],
    };
    await pumpPanel(tester, crb, api: FakeApiClient(objects: {'clusterroles.$_rbac//cluster-admin': admin}), size: const Size(560, 900));
    await saveScreenshot(tester, 'cluster-crb-admin');
    expect(find.text('Dangerous grants'), findsOneWidget);
    expect(find.textContaining('Full wildcard'), findsOneWidget);
    expect(find.text('system:masters'), findsOneWidget);

    final orphan = {...crb, 'metadata': {...crb['metadata'] as Map, 'uid': 'orphan'}};
    await pumpPanel(tester, orphan, api: FakeApiClient(), size: const Size(560, 900));
    expect(find.text('ClusterRole "cluster-admin" not found'), findsOneWidget);
    expect(find.byType(ResourceLink), findsOneWidget);
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
