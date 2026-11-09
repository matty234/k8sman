import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/detail/yaml_editor.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';

import '../support/screenshot.dart';

const _yaml = '''apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: demo
  resourceVersion: "100"
spec:
  replicas: 2
''';

class _EditApi extends ApiClient {
  _EditApi() : super(base: Uri.parse('http://fake'));
  final calls = <String>[];
  ApiException? failApplyWith;

  @override
  Future<String> objectYaml(ResourceRef r, {String? namespace, required String name, bool managedFields = false}) async => _yaml;

  @override
  Future<UpdateResult> updateObject(ResourceRef r, {String? namespace, required String name, required String yaml, bool dryRun = false}) async {
    calls.add(dryRun ? 'dry' : 'apply');
    if (!dryRun && failApplyWith != null) throw failApplyWith!;
    return UpdateResult(dryRun: dryRun, resourceVersion: '101', yaml: yaml, context: 'kind-dev');
  }
}

Future<_EditApi> _pump(WidgetTester tester, {String rv = '100'}) async {
  final api = _EditApi();
  final app = AppState(api)
    ..currentContext = 'kind-dev'
    ..types = const [ResourceType(group: 'apps', version: 'v1', resource: 'deployments', kind: 'Deployment', verbs: ['get', 'update'])];
  tester.view.physicalSize = const Size(600, 700);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: YamlEditorTab(target: DetailTarget(type: app.types.first, name: 'web', namespace: 'demo'), resourceVersion: rv)),
    ),
  ));
  await tester.pumpAndSettle();
  return api;
}

void main() {

  testWidgets('edit → review → apply runs dry-run then apply', (tester) async {
    await loadRealFonts();
    final api = await _pump(tester);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    editor.controller!.text = _yaml.replaceAll('replicas: 2', 'replicas: 5');
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('Diff'));
    await tester.pumpAndSettle();
    expect(find.text('  replicas: 5'), findsOneWidget);

    await tester.tap(find.text('Review & apply'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Apply changes to Deployment web'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(api.calls, ['dry', 'apply']);
    expect(find.text('Edit'), findsOneWidget); // back to view mode
  });

  testWidgets('conflict shows the server-changed banner', (tester) async {
    final api = await _pump(tester);
    api.failApplyWith = ApiException(409, 'conflict', reason: 'Conflict');
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text = _yaml.replaceAll('replicas: 2', 'replicas: 3');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review & apply'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(find.textContaining('changed on the server'), findsWidgets);
  });
}
