import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/detail/yaml_editor.dart';
import 'package:k8sman/ui/editor/yaml_code_editor.dart';
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

  testWidgets('gutter folds a block; sticky header follows the scroll smoothly and jumps to a key', (tester) async {
    final long = 'apiVersion: v1\nkind: Pod\nmetadata:\n  name: big\n  annotations:\n'
        '${[for (var i = 0; i < 30; i++) '    a$i: v$i\n'].join()}'
        'spec:\n  template:\n    spec:\n      containers:\n      - name: web\n'
        '${[for (var i = 0; i < 30; i++) '        e$i: v\n'].join()}'
        'status:\n${[for (var i = 0; i < 30; i++) '  s$i: v\n'].join()}';
    await _pump(tester, yaml: long);
    final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
    final c = editor.controller!;
    final scroll = editor.scrollController!.verticalScroller;
    const pad = 5.0;
    final h = 12 * 1.45;
    final gutter = tester.getRect(find.byWidgetPredicate((w) => w is CustomPaint && w.painter.runtimeType.toString() == '_FoldPainter'));

    // Fold metadata (line 3) from the gutter: one line, real text intact.
    await tester.tapAt(Offset(gutter.center.dx, gutter.top + pad + 2.5 * h));
    await tester.pump();
    expect(c.codeLines[2].chunkParent, isTrue);
    expect(c.text, long);
    await tester.tapAt(Offset(gutter.center.dx, gutter.top + pad + 2.5 * h));
    await tester.pump();
    expect(c.codeLines.length, long.split('\n').length);

    // Scroll down a pixel at a time, unfolded and with annotations folded.
    // A pinned row stays put or slides up with the scroll, a row only goes
    // once it has slid behind the row above, and none comes back.
    final header = tester.getRect(find.byType(CodeEditor)).top + 1;
    for (final fold in [false, true]) {
      if (fold) tester.state<YamlCodeEditorState>(find.byType(YamlCodeEditor)).toggleFold(4);
      scroll.jumpTo(0);
      await tester.pump();
      var prev = <int, double>{};
      final gone = <int>{};
      for (var y = 0.0; y <= scroll.position.maxScrollExtent; y++) {
        scroll.jumpTo(y);
        await tester.pump();
        final rows = {
          for (final e in find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key! as ValueKey<String>).value.startsWith('sticky-')).evaluate())
            int.parse((e.widget.key! as ValueKey<String>).value.substring(7)): tester.getTopLeft(find.byWidget(e.widget)).dy,
        };
        final rowH = rows.isEmpty ? h : tester.getSize(find.byKey(ValueKey('sticky-${rows.keys.first}'))).height;
        for (final line in rows.keys) {
          expect(gone, isNot(contains(line)), reason: 'line $line came back at $y (fold: $fold)');
          final was = prev[line];
          if (was != null) expect(rows[line]! - was, inInclusiveRange(-1.01, 0), reason: 'line $line jumped at $y (fold: $fold)');
        }
        for (final line in prev.keys.where((l) => !rows.containsKey(l))) {
          final above = prev.entries.where((e) => e.value < prev[line]! - 0.5).map((e) => e.value);
          final cover = above.isEmpty ? header - rowH : above.reduce((a, b) => a > b ? a : b);
          expect(prev[line]!, lessThanOrEqualTo(cover + 1.5), reason: 'line $line vanished mid-slide at $y (fold: $fold)');
          gone.add(line);
        }
        prev = rows;
      }
    }
    tester.state<YamlCodeEditorState>(find.byType(YamlCodeEditor)).unfoldAll();

    // Scrolled into the annotations: metadata and annotations stick on top;
    // clicking annotations scrolls it to just under metadata.
    scroll.jumpTo(20 * h);
    await tester.pump();
    expect(find.text('metadata:'), findsOneWidget);
    expect(find.text('  annotations:'), findsOneWidget);
    await tester.tap(find.text('  annotations:'));
    await tester.pump();
    expect(scroll.offset, closeTo(pad + 3 * h, 3));
    expect(c.selection.extentIndex, 4);
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
