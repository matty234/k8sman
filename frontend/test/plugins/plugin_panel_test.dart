import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/registry.dart';
import 'package:k8sman/plugins/plugin_host.dart';
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

/// A plugin whose Widget sections replace the generic panel's
/// (`panel.generic: replace`), with a settings block and a titled message.
class _ReplaceApi extends FakeApiClient {
  @override
  Future<Json> plugins() async => {
        'generation': 1,
        'plugins': [
          {
            'id': 'demo',
            'name': 'Demo',
            'source': 'bundled',
            'active': true,
            'loaded': true,
            'kinds': [
              {'key': 'example.k8sman.dev/Widget', 'served': true, 'sections': 1, 'generic': 'replace'},
            ],
          },
        ],
      };

  @override
  Future<Json> pluginPanel(ResourceRef r, {String? namespace, required String name}) async => {
        'panels': [
          {
            'plugin': 'demo',
            'name': 'Demo',
            'sections': [
              {
                'title': 'Widget details',
                'blocks': [
                  {'type': 'message', 'severity': 'error', 'title': 'SyncFailed', 'text': 'backend returned 403'},
                  {
                    'type': 'settings',
                    'rows': [
                      {'label': 'auth.tokenSecretRef', 'value': 'Secret/widget-token · token', 'link': {'group': '', 'kind': 'Secret', 'namespace': 'demo', 'name': 'widget-token'}},
                      {'label': 'region', 'value': 'eu-west-1'},
                    ],
                    'total': 3,
                  },
                ],
              },
            ],
          },
        ],
        'actions': [],
      };
}

void main() {
  testWidgets('panel.generic replace: the plugin sections are the panel, without the generic ones', (tester) async {
    final api = _ReplaceApi();
    final type = testType('example.k8sman.dev', 'Widget');
    final object = {
      'apiVersion': 'example.k8sman.dev/v1alpha1',
      'kind': 'Widget',
      'metadata': {'name': 'sprocket', 'namespace': 'demo', 'uid': 'u-2', 'resourceVersion': '3'},
      'spec': {'size': 3},
      'status': {'conditions': [{'type': 'Ready', 'status': 'False'}]},
    };
    final app = AppState(api)..types = testTypes;
    pluginHost.attach(api);
    await pluginHost.refresh();
    final ctx = PanelContext(object: object, type: type, api: api, app: app);
    final panel = panelFor(type, app);
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
    expect(find.text('Spec'), findsNothing, reason: 'replace leaves out the generic sections');
    expect(find.text('Conditions'), findsNothing);
    expect(find.text('SyncFailed'), findsOneWidget, reason: 'a titled error is a callout titled with it');
    expect(find.text('backend returned 403'), findsOneWidget);
    expect(find.text('Secret/widget-token · token'), findsOneWidget, reason: 'a reference row is a link with its name and key');
    expect(find.text('eu-west-1'), findsOneWidget);
    expect(find.textContaining('and 1 more'), findsOneWidget);
  });


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
