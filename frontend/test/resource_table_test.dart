import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/resource_table.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/table_fakes.dart';

class _TableApi extends ApiClient {
  final String fixture;
  _TableApi(this.fixture) : super(base: Uri.parse('http://fake'));
  @override
  Stream<WatchMessage> watch(ResourceRef r, {String? namespace, NamespaceScope? scope, String? labelSelector, String? fieldSelector, bool includeObject = false, List<ColumnDef>? columns}) =>
      Stream.value(WatchMessage(type: 'SNAPSHOT', table: TableData.fromJson(jsonDecode(File('../dev/fixtures/$fixture').readAsStringSync()))));
}

void main() {
  for (final fixture in ['api-table-pods.json']) {
    testWidgets('table has no overflow at narrow, normal and wide widths', (tester) async {
      final table = TableData.fromJson(jsonDecode(File('../dev/fixtures/$fixture').readAsStringSync()));
      final api = _TableApi(fixture);
      final app = AppState(api)..types = [table.resource];
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Sweep widths, including the awkward band just around the columns' natural width.
      for (final w in [520.0, 900.0, 1700.0]) {
        tester.view.physicalSize = Size(w, 600);
        await tester.pumpWidget(MultiProvider(
          providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
          child: MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(body: ResourceTableView(type: table.resource))),
        ));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'overflow at width $w');
      }
    });
  }

  testWidgets('no overflow with 3 rows selected (bulk bar)', (tester) async {
    final api = TableFakeApi()
      ..onWatch = () => [WatchMessage(type: 'SNAPSHOT', table: fakeTable(deployType, [for (final n in ['api', 'cache', 'db', 'web']) fakeRow(n)]))];
    await pumpTable(tester, api, deployType, size: const Size(1200, 600));
    await tester.tap(find.text('api'));
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('db'));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(find.text('3 selected'), findsOneWidget);
    for (final w in [360.0, 900.0, 1800.0]) {
      tester.view.physicalSize = Size(w, 600);
      await tester.pump();
      expect(tester.takeException(), isNull, reason: 'overflow at width $w');
      expect(find.byKey(const ValueKey('bulk-Delete')), findsOneWidget, reason: 'width $w');
    }
  });
}
