import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/panels/workloads/hpa_panel.dart';
import 'package:k8sman/panels/workloads/rollout.dart';
import 'package:k8sman/panels/workloads/statefulset_panel.dart';

import 'support.dart';
import 'package:k8sman/util/pod.dart';

void main() {
  final deploy = loadFixture('deploy-web.json');

  test('rolloutHistory keeps owned ReplicaSets, newest revision first (numeric)', () {
    final h = rolloutHistory(deploymentReplicaSets(), '${deploy['metadata']['uid']}');
    expect(h.map(revisionOf).toList(), [10, 2, 1]);
    expect(h.map((r) => r['metadata']['name']), isNot(contains('web-other')));
  });

  group('podStatus', () {
    final pods = {for (final p in loadLocal('pods-demo.json')) p['metadata']['name']: p};
    test('mirrors the pod table', () {
      expect(podStatus(pods['web-6fd47b8fcb-4v4m9']!), 'Running');
      expect(podStatus(pods['crashy']!), 'CrashLoopBackOff');
      expect(podStatus(pods['bad-image']!), anyOf('ImagePullBackOff', 'ErrImagePull'));
      expect(podStatus(pods['migrate-db-xgbx9']!), 'Completed');
    });
  });

  group('HPA', () {

    test('behavior defaults and custom rules', () {
      expect(describeScalingRules(null, up: true), contains('(default)'));
      expect(describeScalingRules({'selectPolicy': 'Disabled'}, up: false), 'disabled');
      expect(
        describeScalingRules({
          'stabilizationWindowSeconds': 60,
          'policies': [
            {'type': 'Pods', 'value': 1, 'periodSeconds': 60}
          ]
        }, up: false),
        '−1 pod per 60s · stabilization 60s',
      );
    });
  });

  test('statefulSetStatus', () {
    final sts = loadFixture('sts-redis.json');
    expect(statefulSetStatus(sts).$1, 'Up to date');
    final rolling = clone(sts, (c) {
      c['spec']['replicas'] = 3;
      c['status']['updateRevision'] = 'redis-new';
      c['status']['updatedReplicas'] = 1;
    });
    expect(statefulSetStatus(rolling).$1, 'Rolling update: 1 of 3 updated');
  });
}
