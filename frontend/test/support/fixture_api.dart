import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/main.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:provider/provider.dart';

dynamic fixture(String name) => jsonDecode(File('../dev/fixtures/$name').readAsStringSync());

/// Serves the whole app from captured backend responses (dev/fixtures).
class FixtureApi extends ApiClient {
  /// Log streams handed out, keyed `ns/pod/container` (latest wins),
  /// so tests can check they get cancelled.
  final Map<String, StreamController<LogMessage>> logControllers = {};

  /// Leave log streams open after the canned lines (a "live" stream).
  final bool liveLogs;

  FixtureApi({this.liveLogs = true}) : super(base: Uri.parse('http://fake'));

  static final Map<String, String> _objects = {
    'pods/web-6fd47b8fcb-4v4m9': 'pod-web.json',
    'pods/web-6fd47b8fcb-z7wpf': 'pod-web.json',
    'pods/crashy': 'pod-crashy.json',
    'pods/bad-image': 'pod-bad-image.json',
    'deployments.apps/web': 'deploy-web.json',
    'secrets/web-secret': 'secret-web-secret.json',
    'jobs.batch/migrate-db': 'job-migrate-db.json',
  };

  static List<ResourceType>? _types;
  static List<ResourceType> get types => _types ??= [for (final r in fixture('api-resources.json')) ResourceType.fromJson(r)];

  static Json objectFor(String resourceKey, String name) {
    final f = _objects['$resourceKey/$name'] ?? _objects.entries.where((e) => e.key.startsWith('$resourceKey/')).firstOrNull?.value;
    if (f == null) throw ApiException(404, 'not found');
    final o = Map<String, dynamic>.from(fixture(f) as Map);
    // Two web replicas share one fixture: give the second its own name.
    if (o['metadata']?['name'] != name) o['metadata'] = {...(o['metadata'] as Map), 'name': name};
    return o;
  }

  @override
  Future<Map<String, dynamic>> health() async => {'readOnly': false};

  @override
  Future<({String current, List<ContextInfo> contexts})> contexts() async {
    final j = fixture('api-contexts.json');
    return (current: j['current'] as String, contexts: [for (final c in j['contexts']) ContextInfo.fromJson(c)]);
  }

  @override
  Future<List<ResourceType>> resources({bool refresh = false}) async => types;

  /// The saved sidebar layout (settings.json stand-in).
  Json? sidebarLayout;

  @override
  Future<Json?> getSidebar() async => sidebarLayout;

  @override
  Future<void> putSidebar(Json? layout) async => sidebarLayout = layout;

  @override
  Future<({List<String> namespaces, String? defaultNamespace})> namespaces() async =>
      (namespaces: List<String>.from(fixture('api-namespaces.json')['namespaces']), defaultNamespace: 'demo');

  ResourceType _type(ResourceRef r) => types.firstWhere((t) => t.group == r.group && t.resource == r.resource);

  @override
  Stream<WatchMessage> watch(ResourceRef r, {String? namespace, String? labelSelector, String? fieldSelector, bool includeObject = false}) {
    if (fieldSelector != null) {
      final name = fieldSelector.split('=').last;
      final o = objectFor(r.key, name);
      return Stream.value(WatchMessage(
        type: 'SNAPSHOT',
        table: TableData(
          resource: _type(r),
          columns: const [],
          isDefaultColumns: true,
          resourceVersion: '1',
          rows: [TableRowData(uid: 'x', name: name, namespace: 'demo', resourceVersion: '1', cells: const [], object: o)],
        ),
      ));
    }
    final file = switch (r.key) { 'pods' => 'api-table-pods.json', 'deployments.apps' => 'api-table-deployments.json', _ => null };
    if (file != null) return Stream.value(WatchMessage(type: 'SNAPSHOT', table: TableData.fromJson(fixture(file))));
    return Stream.value(WatchMessage(
      type: 'SNAPSHOT',
      table: TableData(resource: _type(r), columns: const [], isDefaultColumns: true, resourceVersion: '1', rows: const []),
    ));
  }

  @override
  Future<Json> object(ResourceRef r, {String? namespace, required String name}) async => objectFor(r.key, name);

  @override
  Future<List<Json>> items(ResourceRef r, {String? namespace, String? labelSelector, String? fieldSelector}) async {
    if (r.key != 'pods') return [];
    if (labelSelector == 'app=web') return [objectFor('pods', 'web-6fd47b8fcb-4v4m9'), objectFor('pods', 'web-6fd47b8fcb-z7wpf')];
    return [];
  }

  @override
  Future<List<Json>> events({String? namespace, String? uid, String? kind, String? name}) async => [];

  @override
  Future<String> objectYaml(ResourceRef r, {String? namespace, required String name, bool managedFields = false}) async => 'kind: Pod';

  static List<String> sampleLines(String pod, String container) => [
        for (var i = 0; i < 60; i++)
          switch (i % 13) {
            5 => '2026/11/03 11:23:${(i % 60).toString().padLeft(2, '0')} [error] 29#29: *$i upstream timed out (110: Connection timed out) while reading response header from upstream',
            9 => '2026/11/03 11:23:${(i % 60).toString().padLeft(2, '0')} [warn] 29#29: *$i an upstream response is buffered to a temporary file',
            _ => '10.244.0.${i % 7 + 1} - - [03/Nov/2026:11:23:${(i % 60).toString().padLeft(2, '0')} +0000] "GET /${i.isEven ? 'healthz' : 'api/v1/items?page=$i'} HTTP/1.1" 200 ${612 + i} "-" "kube-probe/1.31" ($container)',
          },
      ];

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
    logControllers['$namespace/$pod/$container'] = c;
    for (final l in sampleLines(pod, container ?? '')) {
      c.add(LogMessage(line: l));
    }
    if (!liveLogs || !follow) c.add(const LogMessage(eof: true));
    return c.stream;
  }
}

/// Pumps the whole app (shell) against [api] at [size] and returns the
/// state objects for assertions.
Future<(AppState, LogDock)> pumpShell(WidgetTester tester, FixtureApi api, {Size size = const Size(1600, 1000)}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(api);
  await app.init();
  final dock = LogDock(api);
  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<LogDock>.value(value: dock),
    ],
    child: const K8sManApp(themeMode: ThemeMode.light),
  ));
  await tester.pump(const Duration(milliseconds: 50));
  return (app, dock);
}

/// Lets streams deliver and the 50 ms log flush run.
Future<void> settleLogs(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
}
