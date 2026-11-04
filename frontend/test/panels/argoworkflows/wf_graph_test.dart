import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/argoworkflows/wf_common.dart';
import 'package:k8sman/panels/argoworkflows/wf_graph.dart';

/// Builds status.nodes from compact specs: id → (type, phase, children,
/// boundary, extra).
Map<String, WfNode> nodes(String wf, Map<String, (String, String, List<String>, String?)> spec, {Map<String, Json> extra = const {}}) {
  return {
    for (final e in spec.entries)
      e.key: WfNode.fromJson(e.key, {
        'id': e.key,
        'name': e.key == wf ? wf : '$wf.${e.key}',
        'displayName': e.key,
        'type': e.value.$1,
        'phase': e.value.$2,
        'children': e.value.$3,
        'boundaryID': ?e.value.$4,
        ...?extra[e.key],
      }),
  };
}

void main() {
  test('DAG: layers follow dependencies, no overlaps, edges top to bottom', () {
    // w → a → (b, c) → d
    final n = nodes('w', {
      'w': ('DAG', 'Running', ['a'], null),
      'a': ('Pod', 'Succeeded', ['b', 'c'], 'w'),
      'b': ('Pod', 'Succeeded', ['d'], 'w'),
      'c': ('Pod', 'Running', ['d'], 'w'),
      'd': ('Pod', 'Pending', [], 'w'),
    });
    final g = layoutWorkflow(n, workflowName: 'w');
    final by = {for (final x in g.nodes) x.id: x};
    expect(by['w']!.layer, 0);
    expect(by['a']!.layer, 1);
    expect(by['b']!.layer, 2);
    expect(by['c']!.layer, 2);
    expect(by['d']!.layer, 3);
    expect(by['w']!.kind, GKind.container);
    // Same layer, side by side without overlap.
    final (l, r) = by['b']!.x < by['c']!.x ? (by['b']!, by['c']!) : (by['c']!, by['b']!);
    expect(r.x, greaterThanOrEqualTo(l.x + l.w));
    // d sits between its parents.
    expect(by['d']!.cx, inInclusiveRange(l.cx, r.cx));
    for (final e in g.edges) {
      expect(e.points.first.$2, lessThan(e.points.last.$2), reason: '${e.from}→${e.to}');
    }
    expect(g.edges.length, 5);
    expect(g.width, greaterThan(0));
  });

  test('long edges get dummy waypoints; crossings are untangled', () {
    // a → b → c → d and a → d (skips two layers); x → z, y → z crossing setup.
    final n = nodes('w', {
      'w': ('DAG', 'Running', ['a', 'y', 'x'], null),
      'a': ('Pod', 'Succeeded', ['b', 'd'], 'w'),
      'b': ('Pod', 'Succeeded', ['c'], 'w'),
      'c': ('Pod', 'Succeeded', ['d'], 'w'),
      'd': ('Pod', 'Succeeded', [], 'w'),
      'x': ('Pod', 'Succeeded', ['xx'], 'w'),
      'y': ('Pod', 'Succeeded', ['yy'], 'w'),
      'xx': ('Pod', 'Succeeded', [], 'w'),
      'yy': ('Pod', 'Succeeded', [], 'w'),
    });
    final g = layoutWorkflow(n, workflowName: 'w');
    final ad = g.edges.firstWhere((e) => e.from == 'a' && e.to == 'd');
    expect(ad.points.length, 4, reason: 'two dummy points for a two-layer skip');
    final by = {for (final x in g.nodes) x.id: x};
    // x/y children keep their parents' left-to-right order (no crossing).
    expect(by['x']!.x < by['y']!.x, by['xx']!.x < by['yy']!.x);
  });

  test('steps: StepGroups are junctions; retries fold their attempts', () {
    final n = nodes('w', {
      'w': ('Steps', 'Failed', ['g0'], null),
      'g0': ('StepGroup', 'Succeeded', ['s1', 'r'], 'w'),
      's1': ('Pod', 'Succeeded', ['g1'], 'w'),
      'r': ('Retry', 'Failed', ['r0', 'r1', 'g1'], 'w'),
      'r0': ('Pod', 'Failed', [], 'w'),
      'r1': ('Pod', 'Failed', [], 'w'),
      'g1': ('StepGroup', 'Omitted', ['s2'], 'w'),
      's2': ('Pod', 'Omitted', [], 'w'),
    }, extra: {
      'r0': {'name': 'w.r(0)', 'outputs': {'exitCode': '3'}},
      'r1': {'name': 'w.r(1)', 'message': 'Error (exit code 3)'},
      'r': {'name': 'w.r'},
    });
    final g = layoutWorkflow(n, workflowName: 'w');
    final by = {for (final x in g.nodes) x.id: x};
    expect(by.containsKey('r0'), isFalse);
    expect(by.containsKey('r1'), isFalse);
    expect(by['r']!.attempts, 2);
    expect(g.repOf['r1'], 'r');
    expect(by['g0']!.kind, GKind.junction);
    expect(g.edges.where((e) => e.from == 'r' && e.to == 'g1'), hasLength(1));
    // The pod shown for the retry is its last attempt.
    expect(podNodeFor(n['r']!, n).id, 'r1');
  });

  test('onExit handler hangs off the leaves with a dashed edge', () {
    final n = nodes('w', {
      'w': ('DAG', 'Succeeded', ['a'], null),
      'a': ('Pod', 'Succeeded', [], 'w'),
      'exit': ('Pod', 'Succeeded', [], null),
    }, extra: {
      'w': {'outboundNodes': ['a']},
      'exit': {'name': 'w.onExit'},
    });
    final g = layoutWorkflow(n, workflowName: 'w');
    final e = g.edges.firstWhere((e) => e.to == 'exit');
    expect(e.from, 'a');
    expect(e.dashed, isTrue);
  });

  test('cycles in malformed input do not hang', () {
    final n = nodes('w', {
      'w': ('DAG', 'Running', ['a'], null),
      'a': ('Pod', 'Running', ['b'], 'w'),
      'b': ('Pod', 'Running', ['a'], 'w'),
    });
    final g = layoutWorkflow(n, workflowName: 'w');
    expect(g.visible.length, 3);
  });

  test('node tree nests by boundary and retry', () {
    final n = nodes('w', {
      'w': ('DAG', 'Failed', ['inner'], null),
      'inner': ('Steps', 'Failed', ['g0'], 'w'),
      'g0': ('StepGroup', 'Failed', ['r'], 'inner'),
      'r': ('Retry', 'Failed', ['r0'], 'inner'),
      'r0': ('Pod', 'Failed', [], 'inner'),
    }, extra: {
      'r': {'name': 'w.r'},
      'r0': {'name': 'w.r(0)'},
    });
    final t = nodeTree(n, workflowName: 'w');
    expect([for (final (x, d) in t) '${x.id}:$d'], ['w:0', 'inner:1', 'r:2', 'r0:3']);
  });

  test('pod names: v2 from template and node id hash, v1 = node id', () {
    final wf = {
      'metadata': {'name': 'build-x1', 'annotations': {annotationPodNameFormat: 'v2'}},
    };
    final node = WfNode.fromJson('build-x1-123456', {
      'id': 'build-x1-123456',
      'name': 'build-x1.tests(0)',
      'type': 'Pod',
      'templateRef': {'name': 'lib', 'template': 'unit'},
    });
    expect(expectedPodName(wf, node), 'build-x1-unit-123456');
    final v1 = {
      'metadata': {'name': 'build-x1', 'annotations': {annotationPodNameFormat: 'v1'}},
    };
    expect(expectedPodName(v1, node), 'build-x1-123456');
    // Found by the node-id annotation even when the name differs.
    final pods = [
      {'metadata': {'name': 'other', 'annotations': {annotationNodeId: 'zzz'}}},
      {'metadata': {'name': 'renamed', 'annotations': {annotationNodeId: 'build-x1-123456'}}},
    ];
    expect(findNodePod(wf, node, pods)?['metadata']['name'], 'renamed');
    expect(findNodePod(wf, node, [
      {'metadata': {'name': 'build-x1-unit-123456'}},
    ]), isNotNull);
  });

  test('durations', () {
    expect(formatRunDuration(const Duration(seconds: 42)), '42s');
    expect(formatRunDuration(const Duration(seconds: 200)), '3m20s');
    expect(formatRunDuration(const Duration(hours: 2, minutes: 5)), '2h05m');
    expect(formatRunDuration(const Duration(days: 3, hours: 4)), '3d4h');
    expect(formatResourcesDuration({'cpu': 12, 'memory': 90}), '12s cpu · 1m30s memory');
  });
}
