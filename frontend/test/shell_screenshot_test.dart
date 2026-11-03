import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/main.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:provider/provider.dart';

import 'support/screenshot.dart';

dynamic fixture(String name) => jsonDecode(File('../dev/fixtures/$name').readAsStringSync());

/// Serves the whole app from captured backend responses.
class FixtureApi extends ApiClient {
  FixtureApi() : super(base: Uri.parse('http://fake'));

  @override
  Future<({String current, List<ContextInfo> contexts})> contexts() async {
    final j = fixture('api-contexts.json');
    return (current: j['current'] as String, contexts: [for (final c in j['contexts']) ContextInfo.fromJson(c)]);
  }

  @override
  Future<List<ResourceType>> resources({bool refresh = false}) async => [for (final r in fixture('api-resources.json')) ResourceType.fromJson(r)];

  @override
  Future<({List<String> namespaces, String? defaultNamespace})> namespaces() async =>
      (namespaces: List<String>.from(fixture('api-namespaces.json')['namespaces']), defaultNamespace: 'demo');

  @override
  Stream<WatchMessage> watch(ResourceRef r, {String? namespace, String? labelSelector, String? fieldSelector, bool includeObject = false}) {
    if (fieldSelector != null) {
      final pod = fixture('pod-web.json') as Json;
      return Stream.value(WatchMessage(
        type: 'SNAPSHOT',
        table: TableData(
          resource: ResourceType.fromJson(fixture('api-table-pods.json')['resource']),
          columns: const [],
          isDefaultColumns: true,
          resourceVersion: '1',
          rows: [TableRowData(uid: 'x', name: pod['metadata']['name'], namespace: 'demo', resourceVersion: '1', cells: const [], object: pod)],
        ),
      ));
    }
    return Stream.value(WatchMessage(type: 'SNAPSHOT', table: TableData.fromJson(fixture('api-table-pods.json'))));
  }

  @override
  Future<List<Json>> events({String? namespace, String? uid, String? kind, String? name}) async => [];

  @override
  Future<String> objectYaml(ResourceRef r, {String? namespace, required String name, bool managedFields = false}) async => 'kind: Pod';
}

void main() {
  testWidgets('shell screenshot', (tester) async {
    await loadRealFonts();
    tester.view.physicalSize = const Size(1600, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = FixtureApi();
    final app = AppState(api);
    await app.init();
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: const K8sManApp(),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.textContaining('web-').first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    final path = await saveScreenshot(tester, 'shell');
    // ignore: avoid_print
    print('screenshot: $path');
  });
}
