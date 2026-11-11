import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/editor/resource_editor_screen.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';
import 'package:re_editor/re_editor.dart';

import '../support/harness.dart';

class _CreateApi extends FakeApiClient {
  final calls = <({String yaml, String? namespace, bool dryRun})>[];

  @override
  Future<ManifestResult> applyManifests(String yaml, {String? namespace, bool dryRun = false, bool serverSide = false}) async {
    calls.add((yaml: yaml, namespace: namespace, dryRun: dryRun));
    return ManifestResult(dryRun: dryRun, context: 'kind-dev', results: [
      ManifestItem(kind: 'ConfigMap', name: 'my-config', namespace: namespace, created: !dryRun),
    ]);
  }
}

class _TemplatesApi extends FakeApiClient {
  String? kind;

  @override
  Future<List<Json>> pluginTemplates({String? kind}) async {
    this.kind = kind;
    return [
      {
        'plugin': 'cert-manager',
        'pluginName': 'cert-manager',
        'icon': 'verified',
        'kind': 'cert-manager.io/ClusterIssuer',
        'name': 'ACME issuer',
        'description': 'HTTP-01',
        'yaml': 'apiVersion: cert-manager.io/v1\nkind: ClusterIssuer\nmetadata:\n  name: \${name:letsencrypt}\nspec:\n  acme:\n    email: \${email}\n'
            '---\napiVersion: v1\nkind: Secret\nmetadata:\n  name: key\n  namespace: \${namespace}\n',
      },
    ];
  }
}

class _StatusApi extends FakeApiClient {
  final calls = <String>[];
  static const yaml = 'apiVersion: example.dev/v1\nkind: Widget\nmetadata:\n  name: w\n  resourceVersion: "7"\nspec:\n  size: 1\nstatus:\n  phase: Stuck\n';

  @override
  Future<String> subresourceYaml(ResourceRef r, String subresource, {String? namespace, required String name}) async => yaml;

  @override
  Future<UpdateResult> updateSubresource(ResourceRef r, String subresource,
      {String? namespace, required String name, required String yaml, bool dryRun = false}) async {
    calls.add('$subresource${dryRun ? ' dry' : ''}');
    return UpdateResult(dryRun: dryRun, resourceVersion: '8', yaml: yaml, context: 'kind-dev');
  }
}

void main() {
  testWidgets('status mode: banner, and saving PUTs the status subresource', (tester) async {
    final api = _StatusApi();
    const type = ResourceType(group: 'example.dev', version: 'v1', resource: 'widgets', kind: 'Widget', namespaced: false, verbs: ['get', 'update'], subresources: ['status']);
    final app = AppState(api)
      ..currentContext = 'kind-dev'
      ..types = const [type];
    tester.view.physicalSize = const Size(1300, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: const ResourceEditorScreen(target: DetailTarget(type: type, name: 'w'), statusMode: true),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.textContaining('Editing status of Widget/'), findsOneWidget);
    expect(find.textContaining('Only changes under .status are saved'), findsOneWidget);

    tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!.text = _StatusApi.yaml.replaceAll('Stuck', 'Ready');
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review & Apply…'));
    await tester.pumpAndSettle();
    expect(find.text('Apply status changes to Widget w?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Apply'));
    await tester.pumpAndSettle();
    expect(api.calls, ['status dry', 'status']);
  });

  testWidgets('create: pick a template, validate, then create sends the YAML', (tester) async {
    final api = _CreateApi();
    final app = AppState(api)
      ..currentContext = 'kind-dev'
      ..types = testTypes
      ..namespaces = const ['default', 'demo'];
    tester.view.physicalSize = const Size(1300, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: const ResourceEditorScreen(namespace: 'demo')),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.text('ConfigMap'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Validate'));
    await tester.pumpAndSettle();
    expect(api.calls.single.dryRun, isTrue);
    expect(api.calls.single.yaml, contains('kind: ConfigMap'));
    expect(api.calls.single.yaml, contains('namespace: demo'));
    expect(find.text('would be created'), findsOneWidget);

    await tester.tap(find.text('Create…'));
    await tester.pumpAndSettle();
    expect(find.text('Create ConfigMap demo/my-config?'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(api.calls.last.dryRun, isFalse);
    expect(api.calls.last.yaml, contains('name: my-config'));
    expect(api.calls.last.namespace, 'demo');
    expect(find.text('Open my-config'), findsOneWidget);
  });

  testWidgets('create: a plugin template fills the namespace and selects the first placeholder', (tester) async {
    final api = _TemplatesApi();
    const type = ResourceType(group: 'cert-manager.io', version: 'v1', resource: 'clusterissuers', kind: 'ClusterIssuer', namespaced: false, verbs: ['create']);
    final app = AppState(api)
      ..currentContext = 'kind-dev'
      ..types = const [type]
      ..namespaces = const ['default', 'demo'];
    tester.view.physicalSize = const Size(1300, 850);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: const ResourceEditorScreen(kind: type, namespace: 'demo')),
    ));
    await tester.pumpAndSettle();
    expect(api.kind, 'cert-manager.io/ClusterIssuer');
    expect(find.text('cert-manager'), findsOneWidget); // the plugin's group

    await tester.tap(find.text('ACME issuer'));
    await tester.pumpAndSettle();
    final c = tester.widget<CodeEditor>(find.byType(CodeEditor)).controller!;
    expect(c.text, contains('namespace: demo'));
    expect(c.text, contains(r'email: ${email}'));
    expect(c.selection, const CodeLineSelection(baseIndex: 3, baseOffset: 8, extentIndex: 3, extentOffset: 27)); // ${name:letsencrypt}
    expect(find.text('2 placeholders left'), findsOneWidget);
  });
}
