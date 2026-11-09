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

    test('pairs Pods/Object/External metrics with current values', () {
      final hpa = {
        'spec': {
          'metrics': [
            {'type': 'Resource', 'resource': {'name': 'memory', 'target': {'type': 'AverageValue', 'averageValue': '500Mi'}}},
            {'type': 'Pods', 'pods': {'metric': {'name': 'rps'}, 'target': {'type': 'AverageValue', 'averageValue': '100'}}},
            {
              'type': 'Object',
              'object': {
                'describedObject': {'apiVersion': 'networking.k8s.io/v1', 'kind': 'Ingress', 'name': 'main'},
                'metric': {'name': 'requests'},
                'target': {'type': 'Value', 'value': '2k'}
              }
            },
            {'type': 'External', 'external': {'metric': {'name': 'queue', 'selector': {'matchLabels': {'q': 'jobs'}}}, 'target': {'type': 'Value', 'value': '30'}}},
          ]
        },
        'status': {
          'currentMetrics': [
            {'type': 'Pods', 'pods': {'metric': {'name': 'rps'}, 'current': {'averageValue': '150'}}},
            {
              'type': 'Object',
              'object': {'describedObject': {'kind': 'Ingress', 'name': 'main'}, 'metric': {'name': 'requests'}, 'current': {'value': '1500'}}
            },
          ]
        }
      };
      final m = hpaMetrics(hpa);
      expect(m.map((x) => x.type), ['Resource', 'Pods', 'Object', 'External']);
      expect(m[0].current, isNull);
      expect(m[1].current, '150');
      expect(m[1].ratio, 1.5);
      expect(m[2].subject, 'Ingress/main');
      expect(m[2].ratio, 0.75);
      expect(m[3].subject, '{q=jobs}');
      expect(m[3].current, isNull);
    });

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
