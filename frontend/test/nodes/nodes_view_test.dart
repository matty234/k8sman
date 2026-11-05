import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/metrics/metrics_api.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/nodes/nodes_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import '../support/screenshot.dart';

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

  test('sortNodes and groupNodesByRole', () {
    Json node(String name, {String? role, String cpu = '4'}) => {
          'metadata': {
            'name': name,
            'labels': {if (role != null) 'node-role.kubernetes.io/$role': ''},
          },
          'status': {
            'allocatable': {'cpu': cpu, 'memory': '8Gi', 'pods': '110'},
            'conditions': [
              {'type': 'Ready', 'status': 'True'},
            ],
          },
        };
    final s = summarizeNodes([node('w-b', cpu: '2'), node('w-a'), node('cp', role: 'control-plane'), node('gpu-1', role: 'gpu')], const []);
    final usage = {
      'w-a': const NodeUsage('w-a', Usage(3000, 0)), // 75%
      'w-b': const NodeUsage('w-b', Usage(1000, 0)), // 50%
      'cp': const NodeUsage('cp', Usage(400, 0)), // 10%
    };
    expect(sortNodes(s, NodeSort.cpu, ascending: false, usage: usage).map((n) => n.name), ['w-a', 'w-b', 'cp', 'gpu-1']);
    expect(sortNodes(s, NodeSort.name, ascending: false).map((n) => n.name), ['w-b', 'w-a', 'gpu-1', 'cp']);
    final groups = groupNodesByRole(sortNodes(s, NodeSort.name));
    expect(groups.map((g) => g.$1), ['control-plane', 'gpu', 'worker']);
    expect(groups.last.$2.map((n) => n.name), ['w-a', 'w-b']);
  });

  testWidgets('nodes view renders rows without overflow', (tester) async {
    await loadRealFonts();
    final api = FakeApiClient(itemsByResource: {'nodes': _nodes(), 'pods': _pods()});
    final app = AppState(api)
      ..types = testTypes
      ..currentContext = 'kind-k8sman-dev';
    // Sweep widths, including the narrow main area you get with the sidebar open.
    for (var w = 360.0; w <= 1600; w += 31) {
      final size = Size(w, 700);
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.dark), home: const Scaffold(body: NodesView())),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull, reason: 'overflow at width $w');
      if (w == 701 || w == 1259) await saveScreenshot(tester, 'nodes-${size.width.toInt()}');
    }
    expect(find.text('worker-sick'), findsOneWidget);
    // Cordon / uncordon live in the row menu, not on the page.
    expect(find.text('Uncordon'), findsNothing);
    await tester.tap(find.text('k8sman-dev-control-plane'));
    expect(app.detail?.name, 'k8sman-dev-control-plane');
    // Problem nodes sort first: the first menu is worker-sick's.
    await tester.tap(find.byTooltip('Node actions').first);
    await tester.pump();
    expect(find.text('Uncordon'), findsOneWidget);
    expect(find.text('Cordon'), findsNothing);
    await tester.tap(find.text('Show details'));
    await tester.pump();
    expect(app.detail?.name, 'worker-sick');
    await tester.pumpWidget(const SizedBox()); // dispose the poll timer
  });
}
