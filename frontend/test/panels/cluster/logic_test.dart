import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/cluster/logic.dart';

Json _c(String name, {Map<String, String>? req, Map<String, String>? lim, String? restartPolicy}) => {
      'name': name,
      'restartPolicy': ?restartPolicy,
      'resources': {'requests': ?req, 'limits': ?lim},
    };

Json _pod({List<Json> containers = const [], List<Json> init = const [], String phase = 'Running', Json? overhead}) => {
      'metadata': {'name': 'p', 'namespace': 'x'},
      'spec': {'containers': containers, 'initContainers': init, 'overhead': ?overhead},
      'status': {'phase': phase},
    };

const mi = 1048576.0;

void main() {
  group('effective pod resources', () {
    test('sums app containers', () {
      final r = podResources(_pod(containers: [
        _c('a', req: {'cpu': '100m', 'memory': '64Mi'}, lim: {'cpu': '1', 'memory': '128Mi'}),
        _c('b', req: {'cpu': '50m'}),
      ]));
      expect(r.cpuRequest, 150);
      expect(r.cpuLimit, 1000);
      expect(r.memRequest, 64 * mi);
      expect(r.memLimit, 128 * mi);
    });

    test('init containers: max(max(init), sum(app))', () {
      final big = _pod(init: [_c('i1', req: {'cpu': '2'}), _c('i2', req: {'cpu': '500m'})], containers: [_c('a', req: {'cpu': '100m'}), _c('b', req: {'cpu': '100m'})]);
      expect(effectivePodQuantity(big, 'requests', 'cpu'), 2000);
      final small = _pod(init: [_c('i1', req: {'cpu': '50m'})], containers: [_c('a', req: {'cpu': '300m'})]);
      expect(effectivePodQuantity(small, 'requests', 'cpu'), 300);
    });

    test('sidecar init containers add to app sum and later init peaks', () {
      final p = _pod(init: [
        _c('sidecar', req: {'memory': '100Mi'}, restartPolicy: 'Always'),
        _c('migrate', req: {'memory': '500Mi'}),
      ], containers: [_c('app', req: {'memory': '200Mi'})]);
      // init peak = 100 + 500 = 600; app phase = 200 + 100 = 300.
      expect(effectivePodQuantity(p, 'requests', 'memory'), 600 * mi);
    });

    test('pod overhead is added', () {
      final p = _pod(containers: [_c('a', req: {'cpu': '100m'})], overhead: {'cpu': '250m'});
      expect(effectivePodQuantity(p, 'requests', 'cpu'), 350);
    });

    test('missing resources are zero', () {
      expect(podResources(_pod(containers: [{'name': 'x'}])).cpuRequest, 0);
      expect(podResources({}).memLimit, 0);
    });
  });

  group('nodeAllocation', () {
    test('excludes Succeeded/Failed', () {
      final a = nodeAllocation([
        _pod(containers: [_c('a', req: {'cpu': '100m'})]),
        _pod(containers: [_c('a', req: {'cpu': '1'})], phase: 'Succeeded'),
        _pod(containers: [_c('a', req: {'cpu': '1'})], phase: 'Failed'),
        _pod(containers: [_c('a', req: {'cpu': '200m'})], phase: 'Pending'),
      ]);
      expect(a.activePods, 2);
      expect(a.terminatedPods, 2);
      expect(a.total.cpuRequest, 300);
    });

    test('matches kubectl describe node for the dev cluster', () {
      final pods = [for (final p in jsonDecode(File('test/panels/cluster/fixtures/pods-on-node.json').readAsStringSync())) Json.from(p)];
      final a = nodeAllocation(pods);
      expect(a.activePods, 15);
      expect(a.terminatedPods, 3);
      expect(a.total.cpuRequest, 1060);
      expect(a.total.cpuLimit, 500);
      expect(a.total.memRequest, 370 * mi);
      expect(a.total.memLimit, 646 * mi);
    });
  });

  group('podStatus', () {
    test('waiting reason wins over phase', () {
      expect(
          podStatus({
            'status': {
              'phase': 'Running',
              'containerStatuses': [
                {'ready': false, 'state': {'waiting': {'reason': 'CrashLoopBackOff'}}},
              ],
            },
          }),
          'CrashLoopBackOff');
      expect(podStatus({'metadata': {'deletionTimestamp': 'x'}, 'status': {'phase': 'Running'}}), 'Terminating');
      expect(podStatus({'status': {'phase': 'Succeeded'}}), 'Succeeded');
    });
  });

  group('RBAC verb risk', () {
    test('read / write / escalate', () {
      expect(verbRisk('get', resources: ['pods']), VerbRisk.read);
      expect(verbRisk('watch', resources: ['configmaps']), VerbRisk.read);
      expect(verbRisk('patch', resources: ['pods']), VerbRisk.write);
      expect(verbRisk('deletecollection'), VerbRisk.write);
      for (final v in ['*', 'escalate', 'bind', 'impersonate']) {
        expect(verbRisk(v), VerbRisk.escalate, reason: v);
      }
      expect(verbRisk('use'), VerbRisk.other);
    });

    test('reading secrets is escalation', () {
      expect(verbRisk('get', resources: ['secrets']), VerbRisk.escalate);
      expect(verbRisk('list', resources: ['*']), VerbRisk.escalate);
      expect(verbRisk('create', resources: ['secrets']), VerbRisk.write);
    });
  });

  group('RBAC rule dangers', () {
    test('benign rule has none', () {
      expect(ruleDangers({'apiGroups': [''], 'resources': ['pods', 'pods/log'], 'verbs': ['get', 'list', 'watch']}), isEmpty);
    });

    test('full wildcard', () {
      final d = ruleDangers({'apiGroups': ['*'], 'resources': ['*'], 'verbs': ['*']});
      expect(d, contains(startsWith('Full wildcard')));
      expect(d, contains('Can read Secrets'));
      expect(d, contains('Can exec/attach into pods'));
    });

    test('secrets, exec, escalate/bind/impersonate', () {
      expect(ruleDangers({'apiGroups': [''], 'resources': ['secrets'], 'verbs': ['list']}), ['Can read Secrets']);
      expect(ruleDangers({'apiGroups': ['apps'], 'resources': ['secrets'], 'verbs': ['list']}), isEmpty);
      expect(ruleDangers({'apiGroups': [''], 'resources': ['pods/exec'], 'verbs': ['create']}), ['Can exec/attach into pods']);
      expect(ruleDangers({'apiGroups': ['rbac.authorization.k8s.io'], 'resources': ['clusterroles'], 'verbs': ['bind', 'escalate']}),
          ['Grants "escalate"', 'Grants "bind"']);
      expect(ruleDangers({'apiGroups': [''], 'resources': ['users'], 'verbs': ['impersonate']}), ['Grants "impersonate"']);
    });

    test('nonResourceURLs rules are ignored', () {
      expect(ruleDangers({'nonResourceURLs': ['*'], 'verbs': ['*']}), isEmpty);
    });

    test('clusterrole view fixture is safe', () {
      final view = jsonDecode(File('../dev/fixtures/clusterrole-view.json').readAsStringSync()) as Json;
      expect(rulesDangers([for (final r in view['rules']) Json.from(r)]), isEmpty);
    });
  });

  group('RBAC bindings', () {
    final bindings = <Json>[
      {'metadata': {'name': 'a', 'namespace': 'demo'}, 'roleRef': {'kind': 'Role', 'name': 'r'}},
      {'metadata': {'name': 'b', 'namespace': 'other'}, 'roleRef': {'kind': 'Role', 'name': 'r'}},
      {'metadata': {'name': 'c', 'namespace': 'other'}, 'roleRef': {'kind': 'ClusterRole', 'name': 'r'}},
      {'metadata': {'name': 'd'}, 'roleRef': {'kind': 'ClusterRole', 'name': 'r'}},
    ];
    String n(Json b) => b['metadata']['name'];
    test('Role: same namespace only', () {
      expect(bindingsFor(bindings, kind: 'Role', name: 'r', namespace: 'demo').map(n), ['a']);
    });
    test('ClusterRole: any namespace and cluster bindings', () {
      expect(bindingsFor(bindings, kind: 'ClusterRole', name: 'r').map(n), ['c', 'd']);
    });
    test('aggregate-to labels', () {
      expect(aggregatesInto({'rbac.authorization.k8s.io/aggregate-to-edit': 'true', 'x': 'y', 'rbac.authorization.k8s.io/aggregate-to-view': 'false'}),
          ['edit']);
    });
  });

  group('quantities', () {
    test('parse and format by resource kind', () {
      expect(parseQty('requests.cpu', '500m'), 500);
      expect(parseQty('limits.memory', '1Gi'), 1073741824);
      expect(parseQty('pods', '10'), 10);
      expect(parseQty('count/deployments.apps', '2k'), 2000);
      expect(formatQty('requests.storage', 10737418240), '10 GiB');
      expect(formatQty('cpu', 1500), '1.50');
      expect(formatQty('services', 3), '3');
    });
  });
}
