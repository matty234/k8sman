import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/actions/actions.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/custom/crd_schema.dart';
import 'package:k8sman/panels/custom/generic_panel.dart';
import 'package:k8sman/panels/registry.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../../support/harness.dart';

Json _load(String path) => jsonDecode(File(path).readAsStringSync()) as Json;
Json _fixture(String name) => _load('test/panels/custom/fixtures/$name');

const _backupType = ResourceType(group: 'ops.example.dev', version: 'v1', resource: 'backups', kind: 'Backup', custom: true);

/// Like [pumpPanel] but always renders [GenericPanel], so built-ins that may
/// later get a dedicated panel keep exercising the fallback.
Future<AppState> pumpGeneric(WidgetTester tester, Json object, ResourceType t, {Size size = const Size(560, 2400)}) async {
  final client = FakeApiClient();
  final app = AppState(client)..types = testTypes;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: Builder(builder: (context) {
          final ctx = PanelContext(object: object, type: t, api: client, app: app);
          return ListView(padding: const EdgeInsets.all(12), children: const GenericPanel().buildSections(context, ctx));
        }),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return app;
}

void main() {
  setUp(CrdCache.clear);

  group('helpers', () {

  });

  group('CRD panel', () {

  });

  group('generic fallback', () {

    testWidgets('scale control for CRs with a scale subresource, hidden when read-only', (tester) async {
      final crd = _fixture('crd-backups.ops.example.dev.json');
      final obj = _fixture('backup-nightly.json');
      (obj['spec'] as Map)['replicas'] = 2;
      Future<AppState> pump({bool readOnly = false, Json? crdOverride}) async {
        CrdCache.clear();
        final api = FakeApiClient(objects: {'customresourcedefinitions.apiextensions.k8s.io//backups.ops.example.dev': crdOverride ?? crd});
        final app = AppState(api)
          ..types = testTypes
          ..readOnly = readOnly;
        await tester.pumpWidget(const SizedBox());
        await tester.pumpWidget(MultiProvider(
          providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
          child: MaterialApp(
            theme: buildTheme(Brightness.dark),
            home: Scaffold(
              body: Builder(builder: (context) {
                final ctx = PanelContext(object: obj, type: _backupType, api: api, app: app);
                return ListView(children: const GenericPanel().buildSections(context, ctx));
              }),
            ),
          ),
        ));
        await tester.pumpAndSettle();
        return app;
      }

      tester.view.physicalSize = const Size(560, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await pump();
      expect(find.byType(ScaleControl), findsOneWidget);
      expect(find.text('Replicas'), findsOneWidget);

      await pump(readOnly: true);
      expect(find.byType(ScaleControl), findsNothing);

      // No scale subresource → no control.
      final noScale = jsonDecode(jsonEncode(crd)) as Json;
      for (final v in (noScale['spec']['versions'] as List)) {
        (v['subresources'] as Map).remove('scale');
      }
      await pump(crdOverride: noScale);
      expect(find.byType(ScaleControl), findsNothing);
      expect(find.text('Replicas'), findsOneWidget);
    });

  });
}
