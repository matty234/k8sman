import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';

import 'support/table_fakes.dart';

/// Counts rebuilt table rows (the private `_Row` widget).
int _rowBuilds = 0;
void _count(Element e, bool _) {
  if (e.widget.runtimeType.toString() == '_Row') _rowBuilds++;
}

TableRowData _row(String name, String cell) =>
    TableRowData(uid: 'uid-$name', name: name, namespace: 'demo', resourceVersion: cell, cells: [name, cell]);

void main() {
  tearDown(() => debugOnRebuildDirtyWidget = null);

  testWidgets('a watch event rebuilds only the changed row', (tester) async {
    final names = [for (var i = 0; i < 40; i++) 'r${i.toString().padLeft(2, '0')}'];
    final api = TableFakeApi()
      ..onWatch = () => [WatchMessage(type: 'SNAPSHOT', table: fakeTable(deployType, [for (final n in names) _row(n, 'demo')]))];
    await pumpTable(tester, api, deployType);
    debugOnRebuildDirtyWidget = _count;

    _rowBuilds = 0;
    api.watchController!.add(WatchMessage(type: 'MODIFIED', row: _row('r03', 'changed')));
    await null; // deliver the event before the frame
    await tester.pump();
    expect(find.text('changed'), findsOneWidget);
    expect(_rowBuilds, 1);

    _rowBuilds = 0;
    api.watchController!.add(WatchMessage(type: 'BATCH', events: [
      WatchMessage(type: 'MODIFIED', row: _row('r01', 'one')),
      WatchMessage(type: 'MODIFIED', row: _row('r02', 'two')),
    ]));
    await null; // deliver the event before the frame
    await tester.pump();
    expect(find.text('one'), findsOneWidget);
    expect(find.text('two'), findsOneWidget);
    expect(_rowBuilds, 2);

    // A deletion shifts the stripes of the rows below it: those rebuild.
    _rowBuilds = 0;
    api.watchController!.add(WatchMessage(type: 'DELETED', row: _row('r38', '')));
    await null; // deliver the event before the frame
    await tester.pump();
    expect(find.text('r38'), findsNothing);
    expect(_rowBuilds, lessThanOrEqualTo(2));

    // Selecting two rows rebuilds just those (plus the inspected one).
    _rowBuilds = 0;
    await tester.tap(find.text('r05'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tap(find.text('r07'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(find.text('2 selected'), findsOneWidget);
    expect(_rowBuilds, lessThanOrEqualTo(4));

    // The age ticker still re-renders every row.
    _rowBuilds = 0;
    await tester.pump(const Duration(seconds: 30));
    expect(_rowBuilds, greaterThan(20));
    await tester.pumpWidget(const SizedBox());
  });
}
