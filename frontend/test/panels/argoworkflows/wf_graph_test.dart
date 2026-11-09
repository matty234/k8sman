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

  test('cycles in malformed input do not hang', () {
    final n = nodes('w', {
      'w': ('DAG', 'Running', ['a'], null),
      'a': ('Pod', 'Running', ['b'], 'w'),
      'b': ('Pod', 'Running', ['a'], 'w'),
    });
    final g = layoutWorkflow(n, workflowName: 'w');
    expect(g.visible.length, 3);
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

  test('hide skipped: skipped steps leave, shown steps stay connected', () {
    // a → s (skipped) → t; a → b → t; s2 (skipped) → u (ran after a skip).
    final n = nodes('w', {
      'w': ('DAG', 'Succeeded', ['a', 's2'], null),
      'a': ('Pod', 'Succeeded', ['s', 'b'], 'w'),
      's': ('Skipped', 'Skipped', ['t'], 'w'),
      'b': ('Pod', 'Succeeded', ['t'], 'w'),
      't': ('Pod', 'Succeeded', [], 'w'),
      's2': ('Skipped', 'Omitted', ['u'], 'w'),
      'u': ('Pod', 'Succeeded', [], 'w'),
    });
    final all = layoutWorkflow(n, workflowName: 'w');
    expect(all.byId('s')!.kind, GKind.compact);
    expect(all.byId('s')!.w, lessThan(all.byId('a')!.w));
    final g = layoutWorkflow(n, workflowName: 'w', hideSkipped: true);
    expect(g.hidden, 2);
    expect(g.byId('s'), isNull);
    // t keeps its real parent b, no bypass needed; u is bridged to w.
    expect(g.edges.where((e) => e.to == 't').map((e) => e.from), ['b']);
    final bridge = g.edges.singleWhere((e) => e.to == 'u');
    expect((bridge.from, bridge.dashed), ('w', true));
    expect(skippedShare(n), closeTo(2 / 6, 0.01));
  });

}
