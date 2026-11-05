// Nodes page with a large cluster: scrolling, polling and selection.
//
// The structural checks (lazy cards, bounded rebuilds) always run. The
// timing benchmark is opt-in and prints numbers:
//
//   cd frontend && K8SMAN_PERF=1 flutter test test/perf/nodes_perf_test.dart
//
// Numbers are wall-clock in a debug-mode test VM: compare runs on the same
// machine, not against release-mode frame budgets.
// ignore_for_file: avoid_print

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart' as widgets show debugOnRebuildDirtyWidget;
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/nodes/nodes_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';

final bool _enabled = Platform.environment['K8SMAN_PERF'] == '1';
final Object? _skip = _enabled ? null : 'set K8SMAN_PERF=1 to run the perf benchmarks';

const _nodeCount = 200;
const _podsPerNode = 15;

/// A synthetic worker node (names are made up; no real cluster data).
Json _node(int i) {
  final name = 'perf-node-${i.toString().padLeft(3, '0')}';
  final ready = i % 37 != 5;
  return {
    'apiVersion': 'v1',
    'kind': 'Node',
    'metadata': {
      'name': name,
      'uid': 'uid-$name',
      'labels': {
        'kubernetes.io/hostname': name,
        if (i < 3) 'node-role.kubernetes.io/control-plane': '',
        'topology.kubernetes.io/zone': 'zone-${String.fromCharCode(97 + i % 3)}',
        'node.kubernetes.io/instance-type': 'standard-${4 << (i % 3)}',
      },
    },
    'spec': {
      if (i % 23 == 7) 'unschedulable': true,
      if (i < 3)
        'taints': [
          {'key': 'node-role.kubernetes.io/control-plane', 'effect': 'NoSchedule'},
        ],
    },
    'status': {
      'allocatable': {'cpu': '${4 << (i % 3)}', 'memory': '${16 << (i % 3)}Gi', 'pods': '110'},
      'capacity': {'cpu': '${4 << (i % 3)}', 'memory': '${16 << (i % 3)}Gi', 'pods': '110'},
      'conditions': [
        {'type': 'MemoryPressure', 'status': i % 41 == 9 ? 'True' : 'False'},
        {'type': 'DiskPressure', 'status': 'False'},
        {'type': 'PIDPressure', 'status': 'False'},
        {'type': 'Ready', 'status': ready ? 'True' : 'False'},
      ],
      'addresses': [
        {'type': 'InternalIP', 'address': '10.0.${i ~/ 250}.${i % 250 + 1}'},
        {'type': 'Hostname', 'address': name},
      ],
      'nodeInfo': {'kubeletVersion': 'v1.31.${i % 4}'},
    },
  };
}

Json _pod(int node, int j) => {
      'apiVersion': 'v1',
      'kind': 'Pod',
      'metadata': {'name': 'app-$node-$j', 'namespace': 'team-${j % 6}', 'uid': 'uid-$node-$j'},
      'spec': {
        'nodeName': 'perf-node-${node.toString().padLeft(3, '0')}',
        'containers': [
          {
            'name': 'app',
            'image': 'registry.example.com/app:v1',
            'resources': {
              'requests': {'cpu': '${50 + 25 * (j % 4)}m', 'memory': '${64 << (j % 3)}Mi'},
              'limits': {'cpu': '${500 + 100 * (j % 3)}m', 'memory': '${256 << (j % 3)}Mi'},
            },
          },
        ],
      },
      'status': {'phase': 'Running'},
    };

class _BigClusterApi extends FakeApiClient {
  int metricsGen = 0;
  _BigClusterApi()
      : super(itemsByResource: {
          'nodes': [for (var i = 0; i < _nodeCount; i++) _node(i)],
          'pods': [
            for (var i = 0; i < _nodeCount; i++)
              for (var j = 0; j < _podsPerNode; j++) _pod(i, j),
          ],
        });

  @override
  Future<Json> metrics(String path, [Map<String, String?> query = const {}]) async {
    if (path != 'nodes') throw ApiException(404, 'no metrics');
    final g = metricsGen++;
    return {
      'items': [
        for (var i = 0; i < _nodeCount; i++)
          {
            'name': 'perf-node-${i.toString().padLeft(3, '0')}',
            'cpuMillis': 400 + (i * 97 + g * 13) % 3000,
            'memoryBytes': (2 + (i * 7 + g) % 10) * 1024 * 1024 * 1024,
            'timestamp': '2026-11-05T10:00:00Z',
          },
      ],
    };
  }
}

/// Widget rebuilds, counted by widget type name.
class _BuildCounter {
  final counts = <String, int>{};
  void start() {
    counts.clear();
    widgets.debugOnRebuildDirtyWidget = (e, _) {
      final n = e.widget.runtimeType.toString();
      counts[n] = (counts[n] ?? 0) + 1;
    };
  }

  void stop() => widgets.debugOnRebuildDirtyWidget = null;
  int operator [](String n) => counts[n] ?? 0;
}

final _rowFinder = find.byWidgetPredicate((w) => w.runtimeType.toString() == '_NodeRow');

Future<(_BigClusterApi, AppState)> _pumpNodes(WidgetTester tester, {Size size = const Size(1300, 900)}) async {
  final api = _BigClusterApi();
  final app = AppState(api)
    ..types = testTypes
    ..currentContext = 'kind-perf';
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.dark), home: const Scaffold(body: NodesView())),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
  expect(find.text('$_nodeCount nodes'), findsOneWidget);
  expect(_rowFinder, findsWidgets);
  return (api, app);
}

Finder get _scrollable => find.byWidgetPredicate((w) => w is Scrollable && w.axisDirection == AxisDirection.down).last;

void main() {
  testWidgets('nodes page builds only visible rows and scrolls without rebuilding the page', (tester) async {
    final (api, app) = await _pumpNodes(tester);
    // 900px tall shows ~20 of the 200 rows.
    final built = _rowFinder.evaluate().length;
    expect(built, lessThan(_nodeCount ~/ 4), reason: 'rows must be built lazily, got $built of $_nodeCount');

    // Scrolling builds the newly exposed cards only.
    final counter = _BuildCounter()..start();
    for (var k = 0; k < 20; k++) {
      await tester.drag(_scrollable, const Offset(0, -120));
      await tester.pump();
    }
    counter.stop();
    expect(counter['NodesView'], 0);
    expect(counter['_NodeRow'], lessThan(_nodeCount ~/ 2));

    // Selecting a node (an AppState change) must not rebuild every card.
    counter.start();
    app.openDetail(DetailTarget(type: testType('', 'Node'), name: 'perf-node-150'));
    await tester.pump();
    counter.stop();
    expect(counter['_NodeRow'], lessThan(_nodeCount ~/ 4));

    expect(api.metricsGen, greaterThan(0));
    await tester.pumpWidget(const SizedBox()); // dispose the poll timer
  });

  testWidgets('benchmark: 200 nodes', skip: _skip != null, (tester) async {
    final results = <String, Object>{};
    final sw = Stopwatch()..start();
    final (api, app) = await _pumpNodes(tester);
    sw.stop();
    results['first frame with data (ms)'] = sw.elapsedMilliseconds;
    results['rows built'] = _rowFinder.evaluate().length;

    // Scroll frames: one drag step per frame, down then back up.
    const steps = 60;
    final frames = <int>[];
    final counter = _BuildCounter()..start();
    var paints = 0;
    debugOnProfilePaint = (_) => paints++;
    debugProfilePaintsEnabled = true;
    for (var k = 0; k < steps * 2; k++) {
      final f = Stopwatch()..start();
      await tester.drag(_scrollable, Offset(0, k < steps ? -90 : 90));
      await tester.pump();
      f.stop();
      frames.add(f.elapsedMicroseconds);
    }
    debugProfilePaintsEnabled = false;
    debugOnProfilePaint = null;
    counter.stop();
    frames.sort();
    String ms(int us) => (us / 1000).toStringAsFixed(2);
    results['scroll frame mean (ms)'] = ms(frames.reduce((a, b) => a + b) ~/ frames.length);
    results['scroll frame p50 (ms)'] = ms(frames[frames.length ~/ 2]);
    results['scroll frame p90 (ms)'] = ms(frames[(frames.length * 9) ~/ 10]);
    results['render objects painted / scroll frame'] = paints ~/ (steps * 2);
    results['widget rebuilds / scroll frame'] = counter.counts.values.fold<int>(0, (a, b) => a + b) ~/ (steps * 2);
    results['_NodeRow rebuilds during scroll'] = counter['_NodeRow'];

    // A poll tick (new usage numbers).
    counter.start();
    final p = Stopwatch()..start();
    await tester.pump(const Duration(seconds: 10));
    await tester.pump();
    p.stop();
    counter.stop();
    results['poll tick (ms)'] = p.elapsedMilliseconds;
    results['_NodeRow rebuilds / poll'] = counter['_NodeRow'];

    // Selecting a node.
    counter.start();
    final s = Stopwatch()..start();
    app.openDetail(DetailTarget(type: testType('', 'Node'), name: 'perf-node-150'));
    await tester.pump();
    s.stop();
    counter.stop();
    results['select node (ms)'] = s.elapsedMilliseconds;
    results['_NodeRow rebuilds / select'] = counter['_NodeRow'];
    results['metrics fetches'] = api.metricsGen;

    print('PERF nodes ${const JsonEncoder.withIndent('  ').convert(results)}');
    await tester.pumpWidget(const SizedBox());
  });
}
