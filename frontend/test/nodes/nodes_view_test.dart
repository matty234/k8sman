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

  testWidgets('nodes view renders cards without overflow', (tester) async {
    await loadRealFonts();
    final api = FakeApiClient(itemsByResource: {'nodes': _nodes(), 'pods': _pods()});
    final app = AppState(api)
      ..types = testTypes
      ..currentContext = 'kind-k8sman-dev';
    for (final size in const [Size(900, 700), Size(1400, 700)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.dark), home: const Scaffold(body: NodesView())),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(tester.takeException(), isNull);
      await saveScreenshot(tester, 'nodes-${size.width.toInt()}');
    }
    expect(find.text('worker-sick'), findsOneWidget);
    expect(find.text('Uncordon'), findsOneWidget);
    await tester.tap(find.text('k8sman-dev-control-plane'));
    expect(app.detail?.name, 'k8sman-dev-control-plane');
    await tester.pumpWidget(const SizedBox()); // dispose the poll timer
  });
}
