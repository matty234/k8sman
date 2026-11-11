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

  String yaml = _yaml;

  @override
  Future<String> objectYaml(ResourceRef r, {String? namespace, required String name, bool managedFields = false}) async => yaml;

  @override
  Future<UpdateResult> updateObject(ResourceRef r, {String? namespace, required String name, required String yaml, bool dryRun = false}) async {
    calls.add(dryRun ? 'dry' : 'apply');
    if (!dryRun && failApplyWith != null) throw failApplyWith!;
    return UpdateResult(dryRun: dryRun, resourceVersion: '101', yaml: yaml, context: 'kind-dev');
  }
}

Future<_EditApi> _pump(WidgetTester tester, {String rv = '100', Size size = const Size(600, 700), String yaml = _yaml}) async {
  final api = _EditApi()..yaml = yaml;
  final app = AppState(api)
    ..currentContext = 'kind-dev'
    ..types = const [ResourceType(group: 'apps', version: 'v1', resource: 'deployments', kind: 'Deployment', verbs: ['get', 'update'])];
  tester.view.physicalSize = size;
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
  setUpAll(loadRealFonts);

  testWidgets('toolbars fit a slim inspector', (tester) async {
    await _pump(tester, size: const Size(300, 700));
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    expect(find.text('Apply…'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('edit → review → apply runs dry-run then apply', (tester) async {
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

  testWidgets('gutter folds a block; sticky header pins enclosing keys and jumps to them', (tester) async {
    final long = 'apiVersion: v1\nkind: ConfigMap\nmetadata:\n  name: big\n  annotations:\n'
        '${[for (var i = 0; i < 80; i++) '    a$i: v$i\n'].join()}data:\n  k: v\n';
    await _pump(tester, yaml: long);
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final c = editor.controller!;
    const h = 12 * 1.45, pad = 5.0;
    final gutter = tester.getRect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_FoldPainter'));

    // Fold metadata (line 3) from the gutter: one line, real text intact.
    await tester.tapAt(Offset(gutter.center.dx, gutter.top + pad + 2.5 * h));
    await tester.pump();
    expect(c.codeLines[2].chunkParent, isTrue);
    expect(c.codeLines.length, 6); // apiVersion, kind, metadata…, data, k, ""
    expect(c.text, long);
    await tester.tapAt(Offset(gutter.center.dx, gutter.top + pad + 2.5 * h));
    await tester.pump();
    expect(c.codeLines.length, long.split('\n').length);

    // Scrolled into the annotations: metadata and annotations stick on top.
    editor.scrollController!.verticalScroller.jumpTo(30 * h);
    await tester.pump();
    expect(find.text('metadata:'), findsOneWidget);
    expect(find.text('  annotations:'), findsOneWidget);
    await tester.tap(find.text('  annotations:'));
    await tester.pump();
    expect(editor.scrollController!.verticalScroller.offset, closeTo(pad + 3 * h, 3));
    expect(c.selection.extentIndex, 4);
    expect(find.text('  annotations:'), findsNothing);
    expect(find.text('metadata:'), findsOneWidget);
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
