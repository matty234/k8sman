import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/resource_table.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

const deployType = ResourceType(
  group: 'apps',
  version: 'v1',
  resource: 'deployments',
  kind: 'Deployment',
  verbs: ['get', 'list', 'watch', 'delete', 'patch'],
);

const podType = ResourceType(group: '', version: 'v1', resource: 'pods', kind: 'Pod', verbs: ['get', 'list', 'watch', 'delete']);

const testColumns = [
  ColumnDef(name: 'Name', query: '.metadata.name'),
  ColumnDef(name: 'Namespace', query: '.metadata.namespace'),
];

TableRowData fakeRow(String name, {String ns = 'demo', bool controlled = false}) =>
    TableRowData(uid: 'uid-$name', name: name, namespace: ns, resourceVersion: '1', cells: [name, ns], controlled: controlled);

TableData fakeTable(ResourceType type, List<TableRowData> rows) =>
    TableData(resource: type, columns: testColumns, isDefaultColumns: true, resourceVersion: '1', rows: rows);

/// A live watch the test drives, plus a recorder for actions.
class TableFakeApi extends ApiClient {
  StreamController<WatchMessage>? watchController;
  int watches = 0;

  /// Messages sent to each new watch right away (e.g. an ERROR, or a SNAPSHOT).
  List<WatchMessage> Function()? onWatch;

  /// Throw this from every watch (a transport failure).
  Object? watchError;

  final List<String> actions = [];

  /// Names whose action fails with this message.
  Map<String, String> failures = {};

  /// Delay each action, to observe progress.
  Duration actionDelay = Duration.zero;

  List<String> namespaceList = const ['default', 'demo', 'kube-system'];

  TableFakeApi() : super(base: Uri.parse('http://fake'));

  @override
  Stream<WatchMessage> watch(ResourceRef r, {String? namespace, String? labelSelector, String? fieldSelector, bool includeObject = false}) {
    watches++;
    final c = StreamController<WatchMessage>();
    watchController = c;
    if (watchError != null) {
      scheduleMicrotask(() {
        c.addError(watchError!);
        c.close();
      });
    } else {
      for (final m in onWatch?.call() ?? const <WatchMessage>[]) {
        c.add(m);
      }
    }
    return c.stream;
  }

  @override
  Future<ActionResult> runAction(ResourceRef r, {String? namespace, required String name, required String action, Json body = const {}}) async {
    if (actionDelay > Duration.zero) await Future<void>.delayed(actionDelay);
    actions.add('$action $namespace/$name');
    final f = failures[name];
    if (f != null) throw ApiException(409, f);
    return ActionResult(message: '$action $name');
  }

  @override
  Future<Json> object(ResourceRef r, {String? namespace, required String name}) async => {
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {'name': name, 'namespace': namespace},
        'spec': {'replicas': 1},
      };
}

Future<AppState> pumpTable(
  WidgetTester tester,
  TableFakeApi api,
  ResourceType type, {
  Size size = const Size(1200, 700),
  Brightness brightness = Brightness.light,
  String context = 'kind-dev',
  bool readOnly = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(api)
    ..types = [type]
    ..currentContext = context
    ..contexts = [
      ContextInfo(name: context, cluster: 'c', user: 'u'),
      const ContextInfo(name: 'prod-eu', cluster: 'p', user: 'u'),
    ]
    ..namespaces = api.namespaceList
    ..readOnly = readOnly;
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(brightness), home: Scaffold(body: ResourceTableView(type: type))),
  ));
  await tester.pump();
  await tester.pump();
  return app;
}
