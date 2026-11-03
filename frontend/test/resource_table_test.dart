import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/resource_table.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

class _TableApi extends ApiClient {
  final String fixture;
  _TableApi(this.fixture) : super(base: Uri.parse('http://fake'));
  @override
  Stream<WatchMessage> watch(ResourceRef r, {String? namespace, String? labelSelector, String? fieldSelector, bool includeObject = false}) =>
      Stream.value(WatchMessage(type: 'SNAPSHOT', table: TableData.fromJson(jsonDecode(File('../dev/fixtures/$fixture').readAsStringSync()))));
}

void main() {
  for (final fixture in ['api-table-deployments.json', 'api-table-pods.json']) {
    testWidgets('table has no overflow at any width ($fixture)', (tester) async {
      final table = TableData.fromJson(jsonDecode(File('../dev/fixtures/$fixture').readAsStringSync()));
      final api = _TableApi(fixture);
      final app = AppState(api)..types = [table.resource];
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      // Sweep widths, including the awkward band just around the columns' natural width.
      for (var w = 520.0; w <= 1700; w += 7) {
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
}
