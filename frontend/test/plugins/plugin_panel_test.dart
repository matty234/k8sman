import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/registry.dart';
import 'package:k8sman/plugins/plugin_api.dart';
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

/// A plugin with a tab on any kind ("*") that goes into the Security tab
/// where there is one (`into: security`).
class _TabApi extends FakeApiClient {
  int calls = 0;

  @override
  Future<Json> plugins() async => {
        'generation': 1,
        'plugins': [
          {
            'id': 'policies',
            'name': 'Policies',
            'source': 'bundled',
            'active': true,
            'loaded': true,
            'kinds': [
              {'key': '*', 'served': true, 'tabs': 1},
            ],
          },
        ],
      };

  @override
  Future<Json> pluginPanel(ResourceRef r, {String? namespace, required String name}) async {
    calls++;
    return {
      'panels': [
        {
          'plugin': 'policies',
          'name': 'Policies',
          'sections': [],
          'notes': ['Reports aren’t served by this cluster.'],
          'tabs': [
            {
              'title': 'Policy results',
              'icon': 'policy',
              'into': 'security',
              'sections': [
                {
                  'title': 'Results',
                  'summary': '1 fail',
                  'blocks': [
                    {
                      'type': 'table',
                      'columns': [
                        {'name': 'Result', 'type': 'status'},
                        {'name': 'Policy', 'type': 'text'},
                        {'name': 'Message', 'type': 'text', 'detail': true},
                      ],
                      'rows': [
                        [{'value': 'fail'}, {'value': 'require-labels'}, {'value': 'label app is required'}],
                      ],
                      'total': 1,
                      'limit': 20,
                    },
                  ],
                },
              ],
            },
          ],
        },
      ],
      'actions': [],
    };
  }
}

/// A kind's own panel with a Security tab (its slot).
class _SecurityPanel extends ResourcePanel {
  const _SecurityPanel();

  @override
  Set<String> get kinds => const {'/Pod'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) => const [];

  @override
  List<PanelTab> tabs(PanelContext ctx) => [
        PanelTab(label: 'Security', slot: 'security', builder: (context, ctx) => PluginSlotSections(ctx: ctx, slot: 'security')),
      ];
}

void main() {
  testWidgets('a plugin tab on any kind is a tab of its own, or sections of the Security tab where the kind has one', (tester) async {
    final api = _TabApi();
    final app = AppState(api)..types = testTypes;
    pluginHost.attach(api);
    await pluginHost.refresh();
    pluginPanels.debugClear();
    final widgetType = testType('example.k8sman.dev', 'Widget');
    final widget = PanelContext(
      object: {'apiVersion': 'example.k8sman.dev/v1alpha1', 'kind': 'Widget', 'metadata': {'name': 'sprocket', 'namespace': 'demo', 'uid': 'u-3', 'resourceVersion': '1'}},
      type: widgetType,
      api: api,
      app: app,
    );
    final generic = panelFor(widgetType, app);
    expect(generic, isA<PluginComposedPanel>(), reason: 'a "*" tab composes every kind');
    expect([for (final t in generic.tabs(widget)) t.label], isEmpty, reason: 'not before the panel is fetched');
    await tester.pumpAndSettle();
    final tabs = generic.tabs(widget);
    expect([for (final t in tabs) t.label], ['Policy results']);

    // Drawn as its own tab: the summary in the header, the detail column
    // on a line of its own; the not-served note stays out of the Overview.
    tester.view.physicalSize = const Size(600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Future<void> show(Widget Function(BuildContext) child) async {
      await tester.pumpWidget(MultiProvider(
        providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
        child: MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(body: Builder(builder: child))),
      ));
      await tester.pumpAndSettle();
    }

    await show((context) => tabs.single.builder(context, widget));
    expect(find.text('1 fail'), findsOneWidget);
    expect(find.text('require-labels'), findsOneWidget);
    expect(find.text('label app is required'), findsOneWidget);
    await show((context) => ListView(children: generic.buildSections(context, widget)));
    expect(find.textContaining('aren’t served'), findsNothing, reason: 'notes show only beside sections');

    // A kind whose panel has the Security slot: no tab of its own; the
    // sections are in the Security tab.
    final pod = PanelContext(
      object: {'apiVersion': 'v1', 'kind': 'Pod', 'metadata': {'name': 'web', 'namespace': 'demo', 'uid': 'u-4', 'resourceVersion': '1'}},
      type: testType('', 'Pod'),
      api: api,
      app: app,
    );
    const podPanel = PluginComposedPanel(_SecurityPanel());
    podPanel.tabs(pod);
    await tester.pumpAndSettle();
    final podTabs = podPanel.tabs(pod);
    expect([for (final t in podTabs) t.label], ['Security']);
    await show((context) => podTabs.single.builder(context, pod));
    expect(find.text('Results'), findsOneWidget);
    expect(find.text('label app is required'), findsOneWidget);
    expect(api.calls, 2, reason: 'one fetch per object, shared by the tab bar and the views');
  });

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

  test('a "*" entry skips excepted kinds and the other scope', () {
    const star = PluginKind(key: '*', scope: 'namespaced', exceptKinds: ['/Event']);
    expect(star.appliesTo('/Pod', true), isTrue);
    expect(star.appliesTo('/Event', true), isFalse);
    expect(star.appliesTo('/Node', false), isFalse);
  });
}
