import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/editor/resource_editor_screen.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

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

void main() {
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
}
