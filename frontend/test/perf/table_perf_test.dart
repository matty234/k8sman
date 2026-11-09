// Performance benchmarks for the table, the log dock and page polling.
//
// Opt-in (they print numbers rather than assert tight budgets, and take a
// few seconds):
//
//   cd frontend && K8SMAN_PERF=1 flutter test test/perf/table_perf_test.dart
//
// Numbers are wall-clock in a debug-mode test VM: compare runs on the same
// machine, not against release-mode frame budgets.
// ignore_for_file: avoid_print

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/widgets.dart' as widgets show debugOnRebuildDirtyWidget;
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:k8sman/state/table_controller.dart';
import 'package:k8sman/ui/logs/log_dock_view.dart';
import 'package:k8sman/ui/nodes/nodes_view.dart';
import 'package:k8sman/ui/portforward/portforward_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import '../support/table_fakes.dart';

final bool _enabled = Platform.environment['K8SMAN_PERF'] == '1';
final Object? _skip = _enabled ? null : 'set K8SMAN_PERF=1 to run the perf benchmarks';

const _rowCount = 1500;
const _events = 200;
const _burst = 20;

const _columns = [
  ColumnDef(name: 'Name', query: '.metadata.name'),
  ColumnDef(name: 'Namespace', query: '.metadata.namespace'),
  ColumnDef(name: 'Status', query: '.status.phase', type: 'status'),
  ColumnDef(name: 'Restarts', query: '.restarts', type: 'number'),
  ColumnDef(name: 'Node', query: '.spec.nodeName'),
  ColumnDef(name: 'Image', query: '.spec.containers[0].image'),
  ColumnDef(name: 'Age', query: '.metadata.creationTimestamp', type: 'age'),
];

final _epoch = DateTime.utc(2026, 11, 1);

TableRowData _row(int i, int gen) {
  final name = 'pod-${i.toString().padLeft(4, '0')}-${(i * 7919 % 100000).toRadixString(36)}';
  final ns = 'team-${i % 12}';
  return TableRowData(
    uid: 'uid-$i',
    name: name,
    namespace: ns,
    resourceVersion: '$gen',
    cells: [
      name,
      ns,
      gen.isOdd ? 'Running' : 'Pending',
      gen,
      'node-${i % 40}',
      'registry.example.com/team-${i % 12}/service-with-a-long-image-name:v1.$gen.${i % 9}',
      _epoch.subtract(Duration(minutes: i)).toIso8601String(),
    ],
  );
}

Json _rowJson(TableRowData r) =>
    {'uid': r.uid, 'name': r.name, 'namespace': r.namespace, 'resourceVersion': r.resourceVersion, 'cells': r.cells};

class _PerfApi extends TableFakeApi {}

/// Row/cell widget rebuilds, counted by widget type name.
class _BuildCounter {
  final counts = <String, int>{};
  int total = 0;
  void start() {
    counts.clear();
    total = 0;
    widgets.debugOnRebuildDirtyWidget = (e, _) {
      final n = e.widget.runtimeType.toString();
      counts[n] = (counts[n] ?? 0) + 1;
      total++;
    };
  }

  void stop() => widgets.debugOnRebuildDirtyWidget = null;
  int operator [](String n) => counts[n] ?? 0;
}

String _ms(Duration d, int n) => (d.inMicroseconds / n / 1000).toStringAsFixed(3);

Future<TableController> _pumpBigTable(WidgetTester tester, _PerfApi api) async {
  api.onWatch = () => [
        WatchMessage(
          type: 'SNAPSHOT',
          table: TableData(
            resource: podType,
            columns: _columns,
            isDefaultColumns: true,
            resourceVersion: '1',
            rows: [for (var i = 0; i < _rowCount; i++) _row(i, 0)],
          ),
        ),
      ];
  await pumpTable(tester, api, podType, size: const Size(1600, 1000));
  return Provider.of<TableController>(tester.element(find.byType(ListView)), listen: false);
}

/// Indices touched by event [k]: every third one is on screen (the top 30
/// rows in display order are team-0's: indices 0, 12, 24, …).
int _target(int k) => k % 3 == 0 ? (k % 30) * 12 : (k * 37) % _rowCount;

void main() {
  group('table', skip: _skip, () {
    testWidgets('1,500 rows under watch churn', (tester) async {
      final api = _PerfApi();
      final tc = await _pumpBigTable(tester, api);
      expect(tc.totalCount, _rowCount);
      final counter = _BuildCounter();
      final results = <String, String>{};

      // rows() cost: filter+sort over 1,500 rows, called directly.
      var sw = Stopwatch()..start();
      for (var i = 0; i < 50; i++) {
        tc.rows;
      }
      sw.stop();
      results['rows() per call, default sort (ms)'] = _ms(sw.elapsed, 50);
      tc.setFilter('team-3');
      sw = Stopwatch()..start();
      for (var i = 0; i < 50; i++) {
        tc.rows;
      }
      sw.stop();
      results['rows() per call, filter "team-3" (ms)'] = _ms(sw.elapsed, 50);
      tc.setFilter('');
      await tester.pump();

      // Count how often a build calls rows() by timing one build (proxy).
      // Singly: one MODIFIED per frame.
      var gen = 1;
      counter.start();
      final buildSw = Stopwatch();
      final handleSw = Stopwatch();
      for (var k = 0; k < _events; k++) {
        handleSw.start();
        api.watchController!.add(WatchMessage(type: 'MODIFIED', row: _row(_target(k), gen++)));
        await null; // deliver the event (microtask)
        handleSw.stop();
        buildSw.start();
        await tester.pump();
        buildSw.stop();
      }
      counter.stop();
      results['single: frame (pump) per event (ms)'] = _ms(buildSw.elapsed, _events);
      results['single: _Row builds per event'] = (counter['_Row'] / _events).toStringAsFixed(1);
      results['single: TableCellView builds per event'] = (counter['TableCellView'] / _events).toStringAsFixed(1);
      results['single: Tooltip builds per event'] = (counter['Tooltip'] / _events).toStringAsFixed(1);
      results['single: all widget rebuilds per event'] = (counter.total / _events).toStringAsFixed(1);
      results['single: top rebuilt widgets (total over $_events events)'] =
          (counter.counts.entries.toList()..sort((a, b) => b.value - a.value)).take(12).map((e) => '${e.key}=${e.value}').join(', ');

      // Bursts: $_burst events delivered before each frame.
      counter.start();
      buildSw.reset();
      handleSw.reset();
      for (var b = 0; b < _events ~/ _burst; b++) {
        handleSw.start();
        for (var j = 0; j < _burst; j++) {
          api.watchController!.add(WatchMessage(type: 'MODIFIED', row: _row(_target(b * _burst + j), gen++)));
        }
        await null;
        handleSw.stop();
        buildSw.start();
        await tester.pump();
        buildSw.stop();
      }
      counter.stop();
      results['burst x$_burst: frame per burst (ms)'] = _ms(buildSw.elapsed, _events ~/ _burst);
      results['burst x$_burst: _Row builds per burst'] = (counter['_Row'] / (_events / _burst)).toStringAsFixed(1);
      results['burst x$_burst: TableCellView builds per burst'] = (counter['TableCellView'] / (_events / _burst)).toStringAsFixed(1);

      // The same bursts as one BATCH frame each (built via fromJson so this
      // file also compiles against backends/clients without BATCH support).
      counter.start();
      buildSw.reset();
      handleSw.reset();
      var notifies = 0;
      void onNotify() => notifies++;
      tc.addListener(onNotify);
      for (var b = 0; b < _events ~/ _burst; b++) {
        handleSw.start();
        api.watchController!.add(WatchMessage.fromJson({
          'type': 'BATCH',
          'events': [
            for (var j = 0; j < _burst; j++) {'type': 'MODIFIED', 'row': _rowJson(_row(_target(b * _burst + j), gen++))},
          ],
        }));
        await null;
        handleSw.stop();
        buildSw.start();
        await tester.pump();
        buildSw.stop();
      }
      tc.removeListener(onNotify);
      counter.stop();
      results['batch x$_burst: frame per BATCH (ms)'] = _ms(buildSw.elapsed, _events ~/ _burst);
      results['batch x$_burst: notifies per BATCH'] = (notifies / (_events / _burst)).toStringAsFixed(1);
      results['batch x$_burst: _Row builds per BATCH'] = (counter['_Row'] / (_events / _burst)).toStringAsFixed(1);

      // Selection change: one click on a row.
      counter.start();
      sw = Stopwatch()..start();
      tc.selectOnly('uid-3');
      await tester.pump();
      sw.stop();
      counter.stop();
      results['select one row: frame (ms)'] = _ms(sw.elapsed, 1);
      results['select one row: _Row builds'] = '${counter['_Row']}';

      print('PERF table ${const JsonEncoder.withIndent('  ').convert(results)}');
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('log dock', skip: _skip, () {
    testWidgets('10k lines x 3 tabs', (tester) async {
      final api = _LogApi();
      final dock = LogDock(api);
      final pods = [for (var i = 0; i < 3; i++) _pod('web-$i')];
      tester.view.physicalSize = const Size(1200, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      for (final p in pods) {
        dock.open(p);
      }
      await tester.pumpWidget(MultiProvider(
        providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<LogDock>.value(value: dock)],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: const Scaffold(body: Column(children: [Spacer(), LogDockView(maxHeight: 600)])),
        ),
      ));
      await tester.pump();
      final results = <String, String>{};
      final counter = _BuildCounter()..start();
      final rssBefore = ProcessInfo.currentRss;
      final sw = Stopwatch();
      // 12,000 lines each (the cap is 10,000), in 50 ms flushes of 200 lines.
      const perTab = 12000, perFlush = 200;
      var flushes = 0;
      for (var n = 0; n < perTab; n += perFlush) {
        sw.start();
        for (final c in api.controllers) {
          for (var j = 0; j < perFlush; j++) {
            c.add(LogMessage(line: '2026-11-03T10:00:00.000Z INFO request ${n + j} GET /api/v1/things?id=${n + j} 200 3ms\n'));
          }
        }
        await tester.pump(const Duration(milliseconds: 60));
        sw.stop();
        flushes++;
      }
      counter.stop();
      final streams = dock.tabs.whereType<LogStream>().toList();
      var chars = 0, lines = 0;
      for (final s in streams) {
        lines += s.lines.length;
        for (final l in s.lines) {
          chars += l.length;
        }
      }
      // One-byte strings: 16-byte header + payload (8-byte aligned); 8 bytes per list slot.
      final estBytes = lines * 8 + streams.fold<int>(0, (a, s) => a + s.lines.fold<int>(0, (b, l) => b + 16 + ((l.length + 7) ~/ 8) * 8));
      results['lines retained (3 tabs)'] = '$lines';
      results['dropped per tab'] = streams.map((s) => s.dropped).join(',');
      results['chars retained'] = '$chars';
      results['estimated bytes (strings + slots)'] = '$estBytes';
      results['RSS delta (MB, noisy)'] = ((ProcessInfo.currentRss - rssBefore) / 1e6).toStringAsFixed(1);
      results['append+frame per 50 ms flush, 3 tabs x $perFlush lines (ms)'] = _ms(sw.elapsed, flushes);
      results['_LogLine builds per flush'] = (counter['_LogLine'] / flushes).toStringAsFixed(1);

      // Append cost at the cap without frames: LogStream bookkeeping only.
      final s = streams.first;
      final sw2 = Stopwatch()..start();
      for (var k = 0; k < 50; k++) {
        for (var j = 0; j < perFlush; j++) {
          api.controllers.first.add(LogMessage(line: 'extra $k $j'));
        }
        await null;
        await tester.pump(const Duration(milliseconds: 60));
      }
      sw2.stop();
      results['flush at cap, 1 hidden tab x $perFlush lines incl. frame (ms)'] = _ms(sw2.elapsed, 50);
      expect(s.lines.length, kMaxLogLines);

      // Search active on the visible tab ("only matching"): each flush
      // updates the matches.
      final active = dock.active!;
      active
        ..setQuery('request 1')
        ..setView(onlyMatching: true);
      await tester.pump();
      final c = api.controllers[streams.indexOf(active)];
      final sw3 = Stopwatch()..start();
      for (var k = 0; k < 50; k++) {
        for (var j = 0; j < perFlush; j++) {
          c.add(LogMessage(line: '2026-11-03T10:00:00.000Z INFO request ${k * perFlush + j} GET /x 200\n'));
        }
        await null;
        await tester.pump(const Duration(milliseconds: 60));
      }
      sw3.stop();
      results['flush at cap with search + only-matching, visible tab (ms)'] = _ms(sw3.elapsed, 50);
      results['matches'] = '${active.matching.length}';
      print('PERF logdock ${const JsonEncoder.withIndent('  ').convert(results)}');
      dock.closeAll();
      await tester.pumpWidget(const SizedBox());
    });
  });

  group('polling', skip: _skip, () {
    Future<Map<String, int>> measure(WidgetTester tester, Widget page, ApiClient api, int Function() calls) async {
      final app = AppState(api)
        ..types = testTypes
        ..currentContext = 'kind-dev';
      final enabled = ValueNotifier(true);
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
        child: MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Scaffold(
            body: ValueListenableBuilder<bool>(
              valueListenable: enabled,
              builder: (_, on, child) => Offstage(offstage: !on, child: TickerMode(enabled: on, child: child!)),
              child: page,
            ),
          ),
        ),
      ));
      await tester.pump();
      final out = <String, int>{};
      var c0 = calls();
      await tester.pump(const Duration(seconds: 60));
      out['visible: fetches / 60s'] = calls() - c0;
      enabled.value = false;
      await tester.pump();
      c0 = calls();
      await tester.pump(const Duration(seconds: 60));
      out['offstage (TickerMode off): fetches / 60s'] = calls() - c0;
      enabled.value = true;
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
      await tester.pump();
      c0 = calls();
      await tester.pump(const Duration(seconds: 60));
      out['app hidden: fetches / 60s'] = calls() - c0;
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      c0 = calls();
      await tester.pump(const Duration(milliseconds: 100));
      out['resume: fetches within 100 ms'] = calls() - c0;
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 60));
      return out;
    }

    testWidgets('port-forwards and nodes pages', (tester) async {
      final pf = _CountingPfApi();
      final pfOut = await measure(tester, const PortForwardView(), pf, () => pf.calls);
      final nodes = _CountingNodesApi();
      final nodesOut = await measure(tester, const NodesView(), nodes, () => nodes.calls);
      print('PERF polling ${const JsonEncoder.withIndent('  ').convert({'PortForwardView (1.5s)': pfOut, 'NodesView (10s)': nodesOut})}');
    });
  });
}

Json _pod(String name) => {
      'apiVersion': 'v1',
      'kind': 'Pod',
      'metadata': {'name': name, 'namespace': 'demo', 'uid': 'uid-$name'},
      'spec': {
        'containers': [
          {'name': 'app', 'image': 'nginx'},
        ],
      },
      'status': {
        'phase': 'Running',
        'containerStatuses': [
          {
            'name': 'app',
            'ready': true,
            'restartCount': 0,
            'state': {
              'running': {'startedAt': '2026-11-03T10:00:00Z'},
            },
          },
        ],
      },
    };

class _LogApi extends FakeApiClient {
  final controllers = <StreamController<LogMessage>>[];
  @override
  Stream<LogMessage> logs({
    required String namespace,
    required String pod,
    String? container,
    int tailLines = 500,
    bool previous = false,
    bool follow = true,
    bool timestamps = false,
    int? sinceSeconds,
  }) {
    final c = StreamController<LogMessage>();
    controllers.add(c);
    return c.stream;
  }
}

class _CountingPfApi extends ApiClient {
  int calls = 0;
  _CountingPfApi() : super(base: Uri.parse('http://fake'));
  @override
  Future<List<PortForward>> portForwards() async {
    calls++;
    return const [];
  }
}

class _CountingNodesApi extends FakeApiClient {
  int calls = 0;
  @override
  Future<List<Json>> items(ResourceRef r, {String? namespace, NamespaceScope? scope, String? labelSelector, String? fieldSelector}) async {
    if (r.resource == 'nodes') calls++;
    return const [];
  }

  @override
  Future<Json> metrics(String path, [Map<String, String?> query = const {}]) async => throw ApiException(404, 'no metrics');
}
