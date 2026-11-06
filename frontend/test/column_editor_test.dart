import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/state/namespace_scope.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/ui/column_editor.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/fixture_api.dart' show FixtureApi, fixture;
import 'support/screenshot.dart';

class _ColumnsApi extends FixtureApi {
  @override
  Future<ColumnsConfig> getColumns(ResourceRef r) async {
    final cols = TableData.fromJson(fixture('api-table-pods.json')).columns;
    return ColumnsConfig(columns: cols, defaults: cols, isDefault: true);
  }

  @override
  Future<List<Json>> items(ResourceRef r, {String? namespace, NamespaceScope? scope, String? labelSelector, String? fieldSelector}) async => [fixture('pod-web.json')];

  @override
  Future<TableData> previewColumns(ResourceRef r, List<ColumnDef> cols, {String? namespace, int limit = 25}) async =>
      TableData.fromJson(fixture('api-table-pods.json'));
}

void main() {
  testWidgets('column editor lays out without overflow', (tester) async {
    await loadRealFonts();
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = _ColumnsApi();
    const type = ResourceType(group: '', version: 'v1', resource: 'pods', kind: 'Pod');
    await tester.pumpWidget(Provider<ApiClient>.value(
      value: api,
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: ColumnEditorDialog(type: type, namespace: 'demo'))),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 50));
    await saveScreenshot(tester, 'column-editor');
    expect(tester.takeException(), isNull);
  });
}
