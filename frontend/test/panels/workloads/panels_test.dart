import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/ui/inspector/inspector.dart';
import 'package:k8sman/panels/workloads/widgets/pods_list.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';
import 'support.dart';

void main() {
  late List<Json> pods;
  late List<Json> pvcs;

  setUp(SectionMemory.reset);
  setUpAll(() async {
    pods = loadLocal('pods-demo.json');
    pvcs = loadLocal('pvcs-demo.json');
  });

  /// A pod with web's labels whose owner RS is not this deployment's.
  Json strayWebPod() => clone(pods.firstWhere((p) => p['metadata']['name'] == 'web-6fd47b8fcb-4v4m9'), (c) {
        c['metadata']['name'] = 'web-stray-zzzzz';
        c['metadata']['ownerReferences'][0]['uid'] = 'uid-other';
      });

  testWidgets('Deployment: rollout status, history order, owner-filtered pods', (tester) async {
    await loadRealFonts();
    final rs = deploymentReplicaSets();
    // Owner of the live pods is the live rev-1 RS uid; add it with that uid.
    final api = fakeApi({'pods': [...pods, strayWebPod()], 'replicasets.apps': rs});
    final app = await pumpPanel(tester, loadFixture('deploy-web.json'), api: api);

    expect(find.text('Available 2/2'), findsOneWidget);
    expect(find.text('Rollout complete · revision 1'), findsOneWidget);
    expect(find.text('RollingUpdate · 1 surge · 0 unavailable'), findsOneWidget);

    // History: #10, #2, #1 in that order; stranger RS excluded.
    await expandSection(tester, 'history');
    final revs = ['#10', '#2', '#1'].map((t) => tester.getTopLeft(find.text(t)).dy).toList();
    expect(revs[0] < revs[1] && revs[1] < revs[2], isTrue);
    expect(find.text('web-other'), findsNothing);
    expect(find.text('current'), findsOneWidget);

    // Pods: both live web pods, not the stray one (owned by a foreign RS).
    expect(find.text('web-6fd47b8fcb-4v4m9'), findsOneWidget);
    expect(find.text('web-6fd47b8fcb-z7wpf'), findsOneWidget);
    expect(find.text('web-stray-zzzzz'), findsNothing);

    // Template: copyable images and a ServiceAccount link.
    await expandSection(tester, 'template');
    expect(find.text('busybox:1.36'), findsWidgets);
    await tester.tap(find.text('web').last);
    await tester.pump();
    expect(app.detail?.type.kind, 'ServiceAccount');
  });

  testWidgets('StatefulSet: service link, PVCs by ordinal, pods', (tester) async {
    await loadRealFonts();
    final retained = clone(pvcs.first, (c) => c['metadata']['name'] = 'data-redis-3');
    final api = fakeApi({'pods': pods, 'persistentvolumeclaims': [...pvcs, retained]});
    final app = await pumpPanel(tester, loadFixture('sts-redis.json'), api: api);

    expect(find.text('Up to date'), findsOneWidget);
    await expandSection(tester, 'claims');
    expect(find.text('data-redis-0'), findsOneWidget);
    expect(find.text('data-redis-3'), findsOneWidget);
    expect(find.text('retained'), findsOneWidget);
    expect(find.text('redis-0'), findsOneWidget);
    expect(find.text('node-agent-h8g6x'), findsNothing);

    await tester.tap(find.text('redis').first);
    await tester.pump();
    expect(app.detail?.type.kind, 'Service');
  });

  testWidgets('HPA with all metric kinds and behavior', (tester) async {
    await loadRealFonts();
    final hpa = clone(loadFixture('hpa-web.json'), (c) {
      c['spec']['metrics'] = [
        {'type': 'Resource', 'resource': {'name': 'cpu', 'target': {'type': 'Utilization', 'averageUtilization': 70}}},
        {'type': 'Resource', 'resource': {'name': 'memory', 'target': {'type': 'AverageValue', 'averageValue': '100Mi'}}},
        {'type': 'Pods', 'pods': {'metric': {'name': 'http_requests'}, 'target': {'type': 'AverageValue', 'averageValue': '50'}}},
        {
          'type': 'External',
          'external': {'metric': {'name': 'sqs_messages', 'selector': {'matchLabels': {'queue': 'jobs'}}}, 'target': {'type': 'Value', 'value': '30'}}
        },
      ];
      c['spec']['behavior'] = {
        'scaleDown': {
          'stabilizationWindowSeconds': 120,
          'policies': [
            {'type': 'Pods', 'value': 1, 'periodSeconds': 60}
          ]
        }
      };
      c['status'] = {
        'currentReplicas': 5,
        'desiredReplicas': 5,
        'lastScaleTime': '2026-11-03T11:30:00Z',
        'currentMetrics': [
          {'type': 'Resource', 'resource': {'name': 'cpu', 'current': {'averageUtilization': 93, 'averageValue': '93m'}}},
          {'type': 'Resource', 'resource': {'name': 'memory', 'current': {'averageValue': '60Mi'}}},
          {'type': 'Pods', 'pods': {'metric': {'name': 'http_requests'}, 'current': {'averageValue': '20'}}},
        ],
        'conditions': [
          {'type': 'AbleToScale', 'status': 'True', 'reason': 'ReadyForNewScale'},
          {'type': 'ScalingActive', 'status': 'True', 'reason': 'ValidMetricFound'},
          {'type': 'ScalingLimited', 'status': 'True', 'reason': 'TooManyReplicas'},
        ],
      };
    });
    await pumpPanel(tester, hpa);
    expect(find.text('Scaling limited'), findsOneWidget);
    expect(find.text('ScalingLimited: TooManyReplicas'), findsOneWidget);
    await expandSection(tester, 'behavior');
    expect(find.text('sqs_messages'), findsOneWidget);
    expect(find.textContaining('−1 pod per 60s'), findsOneWidget);
  });

  testWidgets('PDB: zero disruptions warns, matched pods', (tester) async {
    await loadRealFonts();
    final pdb = <String, dynamic>{
      'apiVersion': 'policy/v1',
      'kind': 'PodDisruptionBudget',
      'metadata': {'name': 'web', 'namespace': 'demo', 'uid': 'pdb-uid', 'creationTimestamp': '2026-11-03T11:22:57Z'},
      'spec': {
        'minAvailable': 2,
        'selector': {'matchLabels': {'app': 'web'}},
      },
      'status': {
        'currentHealthy': 2,
        'desiredHealthy': 2,
        'disruptionsAllowed': 0,
        'expectedPods': 2,
        'observedGeneration': 1,
        'conditions': [
          {'type': 'DisruptionAllowed', 'status': 'False', 'reason': 'InsufficientPods', 'lastTransitionTime': '2026-11-03T11:23:12Z'}
        ],
      },
    };
    await pumpPanel(tester, pdb, api: fakeApi({'pods': pods}), type: pdbType);
    expect(find.text('Blocks voluntary evictions'), findsOneWidget);
    expect(find.text('0 disruptions allowed'), findsOneWidget);
    expect(find.text('web-6fd47b8fcb-4v4m9'), findsOneWidget);
    expect(find.text('redis-0'), findsNothing);
    expect(find.text('minAvailable 2'), findsWidgets);
  });

  testWidgets('PodsList fetches once per uid and refetches when the refresh key changes', (tester) async {
    var calls = 0;
    final api = CountingApi(fakeApi({'pods': pods}), () => calls++);
    final app = AppState(api)..types = testTypes;
    var refresh = 'a';
    late StateSetter setOuter;
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: StatefulBuilder(builder: (context, setState) {
            setOuter = setState;
            return PodsList(
              key: const ValueKey('uid-1'),
              api: api,
              namespace: 'demo',
              selector: const {'matchLabels': {'app': 'redis'}},
              ownerUid: '4d2a15ca-c84a-4159-b23d-85e672249774',
              refreshKey: refresh,
            );
          }),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(find.text('redis-0'), findsOneWidget);

    setOuter(() {}); // live watch tick, nothing meaningful changed
    await tester.pumpAndSettle();
    expect(calls, 1);

    setOuter(() => refresh = 'b'); // e.g. observedGeneration bumped
    await tester.pumpAndSettle();
    expect(calls, 2);
  });
}

class CountingApi extends FakeApiClient {
  final FakeApiClient inner;
  final void Function() onItems;
  CountingApi(this.inner, this.onItems);

  @override
  Future<List<Json>> items(ResourceRef r, {String? namespace, NamespaceScope? scope, String? labelSelector, String? fieldSelector}) {
    if (r.resource == 'pods') onItems();
    return inner.items(r, namespace: namespace, labelSelector: labelSelector, fieldSelector: fieldSelector);
  }
}
