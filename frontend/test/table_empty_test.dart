import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/resource_table.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/harness.dart';

class _EmptyApi extends FakeApiClient {
  final List<String?> watched = [];
  @override
  Stream<WatchMessage> watch(ResourceRef r, {String? namespace, NamespaceScope? scope, String? labelSelector, String? fieldSelector, bool includeObject = false, List<ColumnDef>? columns}) {
    watched.add(namespace);
    return Stream.value(WatchMessage(
      type: 'SNAPSHOT',
      table: TableData(resource: testType('', 'Pod'), columns: const [ColumnDef(name: 'Name', query: '.metadata.name')], isDefaultColumns: true, resourceVersion: '1', rows: const []),
    ));
  }
}

Future<(AppState, _EmptyApi)> _pump(WidgetTester tester, {String? namespace, ResourceType? type}) async {
  final api = _EmptyApi();
  final app = AppState(api)
    ..types = testTypes
    ..namespaces = ['default', 'demo']
    ..namespace = namespace;
  tester.view.physicalSize = const Size(1100, 600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(body: ResourceTableView(type: type ?? testType('', 'Pod')))),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
  return (app, api);
}

void main() {
  testWidgets('empty in a namespace: offers Show all namespaces', (tester) async {
    final (app, api) = await _pump(tester, namespace: 'demo');
    expect(find.text('No pods in demo'), findsOneWidget);
    await tester.tap(find.text('Show all namespaces'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));
    expect(app.namespace, isNull);
    expect(api.watched.last, isNull, reason: 'refetched cluster-wide');
  });

  testWidgets('already all namespaces: no button', (tester) async {
    await _pump(tester);
    expect(find.text('No pods'), findsOneWidget);
    expect(find.text('Show all namespaces'), findsNothing);
  });

  testWidgets('cluster-scoped kinds never offer it', (tester) async {
    await _pump(tester, namespace: 'demo', type: testType('', 'Node'));
    expect(find.text('Show all namespaces'), findsNothing);
  });
}
