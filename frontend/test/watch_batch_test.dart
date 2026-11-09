import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/table_controller.dart';

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

    test('a DELETED inside a BATCH prunes the selection', () async {
      tc
        ..selectOnly('uid-a')
        ..toggleSelected('uid-b');
      api.watchController!.add(WatchMessage(type: 'BATCH', events: [_ev('DELETED', _row('a')), _ev('ADDED', _row('e'))]));
      await pumpEventQueue();
      expect(tc.selection, {'uid-b'});
      expect(tc.rows.map((r) => r.name), ['b', 'c', 'e']);
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

  });
}

Json _rowJson(String name) => {'uid': 'u-$name', 'name': name, 'namespace': 'demo', 'resourceVersion': '1', 'cells': [name]};
