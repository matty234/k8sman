import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/nodes/nodes_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import '../metrics/metrics_fakes.dart';

Json _node() => jsonDecode(File('../dev/fixtures/node-k8sman-dev-control-plane.json').readAsStringSync());
List<Json> _pods() => [for (final p in jsonDecode(File('test/nodes/pods.json').readAsStringSync())) Map<String, dynamic>.from(p)];

/// Same node twice, the second NotReady + cordoned, to exercise sorting.
List<Json> _nodes() {
  final sick = _node();
  sick['metadata']['name'] = 'worker-sick';
  sick['spec'] = {'unschedulable': true};
  for (final c in sick['status']['conditions']) {
    if (c['type'] == 'Ready') c['status'] = 'False';
  }
  return [_node(), sick];
}

void main() {
  test('summarizeNodes groups pods and puts problem nodes first', () {
    final s = summarizeNodes(_nodes(), _pods());
    expect(s.first.name, 'worker-sick');
    expect(s.first.ready, isFalse);
    expect(s.first.alloc.activePods, 0);
    final cp = s.last;
    expect(cp.alloc.activePods, greaterThan(5));
    expect(cp.alloc.total.cpuRequest, greaterThan(0));
    expect(cp.roles, contains('control-plane'));
  });

  testWidgets('a node expands into its pods, problem pods first, grouped by pool', (tester) async {
    // Three nodes in two pools; all the pods are on the control plane.
    final nodes = _nodes();
    final spare = _node()..['metadata']['name'] = 'worker-2';
    nodes.add(spare);
    for (final (n, pool) in [(nodes[0], 'system'), (nodes[1], 'general'), (spare, 'general')]) {
      (n['metadata']['labels'] as Map)['eks.amazonaws.com/nodegroup'] = pool;
    }
    final api = MetricsFakeApi(items: {'nodes': nodes, 'pods': _pods()});
    final app = AppState(api)
      ..types = testTypes
      ..currentContext = 'kind-k8sman-dev';
    tester.view.physicalSize = const Size(1400, 860);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.dark), home: const Scaffold(body: NodesView())),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.text('general'), findsOneWidget);
    expect(find.text('system'), findsOneWidget);
    expect(find.text('crashy'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('expand:k8sman-dev-control-plane')));
    await tester.pump();
    expect(tester.takeException(), isNull);
    double y(String pod) => tester.getTopLeft(find.text(pod)).dy;
    // bad-image (pending) and crashy (restarting) lead, the busy rest follow.
    final firstHealthy = [for (final p in _pods()) p['metadata']['name'] as String].where((n) => n != 'bad-image' && n != 'crashy').map(y).reduce((a, b) => a < b ? a : b);
    expect(y('bad-image'), lessThan(firstHealthy));
    expect(y('crashy'), lessThan(firstHealthy));

    await tester.tap(find.text('crashy'));
    expect((app.detail?.type.kind, app.detail?.namespace, app.detail?.name), ('Pod', 'demo', 'crashy'));
    await tester.pumpWidget(const SizedBox()); // dispose the poll timer
  });

}
