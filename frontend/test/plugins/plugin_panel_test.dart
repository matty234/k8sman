import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/registry.dart';
import 'package:k8sman/plugins/plugin_panel.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';

/// Answers /api/plugins/panel with what the backend renders for a plugin.
class _PluginApi extends FakeApiClient {
  int calls = 0;

  @override
  Future<Json> pluginPanel(ResourceRef r, {String? namespace, required String name}) async {
    calls++;
    return {
      'panels': [
        {
          'plugin': 'demo',
          'name': 'Demo',
          'sections': [
            {
              'title': 'Widget details',
              'icon': 'verified',
              'blocks': [
                {
                  'type': 'fields',
                  'items': [
                    {'label': 'Owner', 'value': 'team-a', 'type': 'text'},
                    {'label': 'Service', 'value': 'web', 'type': 'text', 'link': {'group': '', 'kind': 'Service', 'namespace': 'demo', 'name': 'web'}},
                    {'label': 'Broken', 'error': 'plugin.yaml:20:16: no such key: owner'},
                  ],
                },
                {'type': 'badges', 'items': [{'text': 'Ready'}]},
                {'type': 'message', 'severity': 'warning', 'text': 'Expires in 12d'},
                {
                  'type': 'table',
                  'columns': [{'name': 'Request', 'type': 'text'}],
                  'rows': [
                    [{'value': 'req-1'}],
                    [{'value': 'req-2'}],
                  ],
                  'total': 2,
                  'limit': 1,
                },
              ],
            },
          ],
        },
      ],
      'actions': [
        {'plugin': 'demo', 'id': 'poke', 'label': 'Poke', 'argv': ['widgetctl', 'poke', 'sprocket'], 'dangerous': true, 'consented': false},
      ],
    };
  }
}

void main() {
  testWidgets('plugin sections draw with the app widgets; their actions are hidden on read-only contexts', (tester) async {
    final api = _PluginApi();
    final type = testType('example.k8sman.dev', 'Widget');
    final object = {
      'apiVersion': 'example.k8sman.dev/v1alpha1',
      'kind': 'Widget',
      'metadata': {'name': 'sprocket', 'namespace': 'demo', 'uid': 'u-1', 'resourceVersion': '7'},
      'spec': {'size': 3},
    };
    final app = AppState(api)..types = testTypes;
    final ctx = PanelContext(object: object, type: type, api: api, app: app);
    final panel = PluginComposedPanel(panelFor(type));
    tester.view.physicalSize = const Size(600, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: Builder(builder: (context) => ListView(children: panel.buildSections(context, ctx)))),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Widget details'), findsOneWidget);
    expect(find.text('team-a'), findsOneWidget);
    expect(find.text('web'), findsOneWidget, reason: 'a linked field shows its value');
    expect(find.textContaining('plugin.yaml:20:16'), findsOneWidget, reason: 'an evaluation error shows in its field, with its place');
    expect(find.text('Ready'), findsOneWidget);
    expect(find.text('Expires in 12d'), findsOneWidget);
    expect(find.text('req-1'), findsOneWidget);
    expect(find.text('req-2'), findsNothing, reason: 'beyond the limit until Show all');
    await tester.tap(find.text('Show all (2)'));
    await tester.pump();
    expect(find.text('req-2'), findsOneWidget);
    expect(find.text('Spec'), findsOneWidget, reason: 'the kind’s own sections stay');

    // The shell action the backend offered for this object.
    expect([for (final a in panel.actions(ctx)) a.label], contains('Poke'));
    app.readOnly = true;
    expect([for (final a in panel.actions(ctx)) a.label], isNot(contains('Poke')));
    expect(api.calls, 1, reason: 'one fetch per object version');
  });
}
