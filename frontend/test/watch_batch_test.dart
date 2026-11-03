import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:k8sman/state/table_controller.dart';
import 'package:k8sman/ui/detail/detail_sidebar.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/harness.dart';
import 'support/table_fakes.dart';

WatchMessage _ev(String type, TableRowData row) => WatchMessage(type: type, row: row);

TableRowData _row(String name, {String rv = '1', String? status}) =>
    TableRowData(uid: 'uid-$name', name: name, namespace: 'demo', resourceVersion: rv, cells: [name, status ?? 'demo']);

void main() {
  test('WatchMessage parses BATCH frames into events', () {
    final m = WatchMessage.fromJson(jsonDecode('''
      {"type":"BATCH","events":[
        {"type":"ADDED","row":{"uid":"u1","name":"a","namespace":"demo","resourceVersion":"2","cells":["a"]}},
        {"type":"DELETED","row":{"uid":"u2","name":"b","namespace":"demo","resourceVersion":"3","cells":["b"]}}
      ]}'''));
    expect(m.type, 'BATCH');
    expect(m.events.map((e) => '${e.type} ${e.row!.name}'), ['ADDED a', 'DELETED b']);
    expect(WatchMessage.fromJson({'type': 'MODIFIED', 'row': _rowJson('c')}).events, isEmpty);
  });

  group('TableController', () {
    late TableFakeApi api;
    late TableController tc;
    var notified = 0;

    setUp(() async {
      api = TableFakeApi()..onWatch = () => [WatchMessage(type: 'SNAPSHOT', table: fakeTable(deployType, [_row('a'), _row('b'), _row('c')]))];
      tc = TableController(api: api, type: deployType)..addListener(() => notified++);
      await pumpEventQueue();
      notified = 0;
    });
    tearDown(() => tc.dispose());

    test('applies a BATCH in order and notifies once', () async {
      api.watchController!.add(WatchMessage(type: 'BATCH', events: [
        _ev('ADDED', _row('d')),
        _ev('MODIFIED', _row('d', rv: '2', status: 'x')),
        _ev('DELETED', _row('a')),
        _ev('MODIFIED', _row('b', rv: '2', status: 'y')),
      ]));
      await pumpEventQueue();
      expect(notified, 1);
      expect(tc.rows.map((r) => '${r.name}:${r.cells[1]}'), ['b:y', 'c:demo', 'd:x']);
    });

    test('single-row frames (older backends) still work', () async {
      api.watchController!
        ..add(_ev('ADDED', _row('d')))
        ..add(_ev('DELETED', _row('a')))
        ..add(_ev('MODIFIED', _row('b', rv: '2', status: 'y')));
      await pumpEventQueue();
      expect(notified, 3);
      expect(tc.rows.map((r) => '${r.name}:${r.cells[1]}'), ['b:y', 'c:demo', 'd:demo']);
    });

    test('a DELETED inside a BATCH prunes the selection', () async {
      tc
        ..selectOnly('uid-a')
        ..toggleSelected('uid-b');
      api.watchController!.add(WatchMessage(type: 'BATCH', events: [_ev('DELETED', _row('a')), _ev('ADDED', _row('e'))]));
      await pumpEventQueue();
      expect(tc.selection, {'uid-b'});
      expect(tc.rows.map((r) => r.name), ['b', 'c', 'e']);
    });

    test('rows is memoised until rows, filter or sort change', () async {
      final first = tc.rows;
      final n = tc.debugRowsComputations;
      expect(identical(tc.rows, first), isTrue);
      tc.selectOnly('uid-b');
      tc.selectedRows;
      expect(tc.debugRowsComputations, n, reason: 'selection does not re-sort');
      api.watchController!.add(_ev('MODIFIED', _row('c', rv: '2')));
      await pumpEventQueue();
      expect(identical(tc.rows, first), isFalse);
      expect(tc.debugRowsComputations, n + 1);
      tc.setFilter('b');
      expect(tc.rows.map((r) => r.name), ['b']);
      tc.sortBy(0);
      tc.sortBy(0);
      expect(tc.rows.map((r) => r.name), ['b']);
      tc.setFilter('');
      expect(tc.rows.map((r) => r.name), ['c', 'b', 'a'], reason: 'descending by name');
      expect(() => (tc.rows as List).add(_row('z')), throwsUnsupportedError);
    });
  });

  test('reconnect delay: jittered exponential backoff, capped', () {
    final r = math.Random(1);
    for (var attempt = 0; attempt < 10; attempt++) {
      final full = math.min(500 * (1 << math.min(attempt, 5)), 16000);
      for (var i = 0; i < 50; i++) {
        final d = TableController.reconnectDelay(attempt, r).inMilliseconds;
        expect(d, inInclusiveRange(full ~/ 2, full), reason: 'attempt $attempt');
      }
    }
  });

  group('detail sidebar', () {
    testWidgets('applies BATCH events and reconnects with backoff', (tester) async {
      final api = _SidebarApi();
      final cm = jsonDecode(File('../dev/fixtures/cm-web-config.json').readAsStringSync()) as Json;
      Json version(String mode) => jsonDecode(jsonEncode(cm))..['data']['APP_MODE'] = mode;
      TableRowData row(String mode) =>
          TableRowData(uid: 'u', name: 'web-config', namespace: 'demo', resourceVersion: mode, cells: const [], object: version(mode));
      final app = AppState(api)..types = testTypes;
      app.openDetail(DetailTarget(type: testType('', 'ConfigMap'), name: 'web-config', namespace: 'demo'));
      tester.view.physicalSize = const Size(600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: api),
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<LogDock>(create: (_) => LogDock(api)),
        ],
        child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: DetailSidebar())),
      ));
      api.controller!.add(WatchMessage(
        type: 'SNAPSHOT',
        table: TableData(resource: testType('', 'ConfigMap'), columns: const [], isDefaultColumns: true, resourceVersion: '1', rows: [row('one')]),
      ));
      await tester.pump();
      expect(find.text('one'), findsWidgets);

      api.controller!.add(WatchMessage(type: 'BATCH', events: [_ev('MODIFIED', row('two')), _ev('MODIFIED', row('three'))]));
      await tester.pump();
      expect(find.text('three'), findsWidgets);
      expect(find.text('two'), findsNothing);

      api.controller!.add(WatchMessage(type: 'BATCH', events: [_ev('DELETED', row('three'))]));
      await tester.pump();
      expect(find.text('Deleted'), findsOneWidget);

      // The stream closes: reconnect after a short jittered delay (≤ 500 ms
      // the first time), not a flat 2 s.
      expect(api.watches, 1);
      await api.controller!.close();
      await tester.pump(const Duration(milliseconds: 501));
      expect(api.watches, 2);
      // The next drop backs off further (≤ 1 s, ≥ 500 ms).
      await api.controller!.close();
      await tester.pump(const Duration(milliseconds: 499));
      expect(api.watches, 2);
      await tester.pump(const Duration(milliseconds: 502));
      expect(api.watches, 3);

      // Disposing the sidebar cancels the watch and the retry timer.
      await tester.pumpWidget(const SizedBox());
      expect(api.controller!.hasListener, isFalse);
    });
  });
}

Json _rowJson(String name) => {'uid': 'u-$name', 'name': name, 'namespace': 'demo', 'resourceVersion': '1', 'cells': [name]};

class _SidebarApi extends FakeApiClient {
  StreamController<WatchMessage>? controller;
  int watches = 0;
  @override
  Stream<WatchMessage> watch(ResourceRef r, {String? namespace, String? labelSelector, String? fieldSelector, bool includeObject = false}) {
    watches++;
    return (controller = StreamController<WatchMessage>()).stream;
  }
}
