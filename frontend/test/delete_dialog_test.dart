import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/actions/actions.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/panel.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/harness.dart';

class _Api extends FakeApiClient {
  final calls = <(String, Json)>[];
  @override
  Future<ActionResult> runAction(ResourceRef r, {String? namespace, required String name, required String action, Json body = const {}}) async {
    calls.add((action, body));
    return const ActionResult(message: 'ok');
  }
}

void main() {
  testWidgets('delete dialog: Advanced is collapsed, force and finalizers turn the button into a force action', (tester) async {
    final api = _Api();
    final app = AppState(api)..types = testTypes;
    const type = ResourceType(group: '', version: 'v1', resource: 'pods', kind: 'Pod', verbs: ['get', 'patch', 'delete']);
    final pod = <String, dynamic>{
      'metadata': {
        'name': 'stuck',
        'namespace': 'demo',
        'deletionTimestamp': '2026-01-01T00:00:00Z',
        'finalizers': ['example.com/volume-cleanup'],
      },
    };
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showDeleteDialog(context, PanelContext(object: pod, type: type, api: api, app: app)),
            child: const Text('open'),
          ),
        )),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // Already terminating: explained, and Advanced is closed with nothing ticked.
    expect(find.textContaining('already being deleted'), findsOneWidget);
    expect(find.byKey(const Key('delete-force')), findsNothing);
    expect(find.widgetWithText(FilledButton, 'Delete'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-advanced')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('delete-force')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(FilledButton, 'Force delete'), findsOneWidget);

    await tester.tap(find.byKey(const Key('delete-finalizers')));
    await tester.pumpAndSettle();
    expect(find.textContaining('example.com/volume-cleanup without letting'), findsOneWidget);
    expect(find.textContaining('may be left behind'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Remove finalizers'));
    await tester.pumpAndSettle();
    expect(api.calls.map((c) => c.$1), ['finalize']);
  });
}
