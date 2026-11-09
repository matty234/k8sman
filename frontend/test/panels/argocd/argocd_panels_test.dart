import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/argocd/app_diff.dart';
import 'package:k8sman/panels/argocd/app_resources.dart';
import 'package:k8sman/panels/argocd/application_panel.dart';
import 'package:k8sman/panels/argocd/live_health.dart';
import 'package:k8sman/panels/registry.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../../support/harness.dart';
import 'fake_argo_diff.dart';
import '../../support/screenshot.dart';

dynamic _raw(String name) => jsonDecode(File('test/panels/argocd/fixtures/$name').readAsStringSync());
Json fx(String name) => _raw(name) as Json;
List<Json> fxList(String name) => [for (final o in _raw(name) as List) o as Json];

const appType = ResourceType(group: 'argoproj.io', version: 'v1alpha1', resource: 'applications', kind: 'Application', custom: true);
const appSetType = ResourceType(group: 'argoproj.io', version: 'v1alpha1', resource: 'applicationsets', kind: 'ApplicationSet', custom: true);
const projectType = ResourceType(group: 'argoproj.io', version: 'v1alpha1', resource: 'appprojects', kind: 'AppProject', custom: true);
const argoTypes = [...testTypes, appType, appSetType, projectType];

ResourceType typeOf(Json o) => switch ('${o['kind']}') { 'Application' => appType, 'ApplicationSet' => appSetType, _ => projectType };

List<Json> get allApps => [
      for (final n in [
        'guestbook',
        'helm-guestbook',
        'kustomize-guestbook',
        'guestbook-degraded',
        'guestbook-no-namespace',
        'bad-path',
        'multi-source',
        'guestbook-dev',
        'guestbook-staging',
      ])
        fx('app-$n.json'),
    ];

/// Serves the captured apps and live objects; records actions.
class ArgoFakeApi extends FakeApiClient {
  final List<(String, Json)> actions = [];
  ArgoFakeApi({super.objects})
      : super(itemsByResource: {
          'applications.argoproj.io': allApps,
          'deployments.apps': [...fxList('live-guestbook-deployments.json'), ...fxList('live-guestbook-degraded-deployments.json')],
          'replicasets.apps': [...fxList('live-guestbook-replicasets.json'), ...fxList('live-guestbook-degraded-replicasets.json')],
          'pods': [...fxList('live-guestbook-pods.json'), ...fxList('live-guestbook-degraded-pods.json')],
          'services': [...fxList('live-guestbook-services.json'), ...fxList('live-guestbook-degraded-services.json')],
        });

  @override
  Future<ActionResult> runAction(ResourceRef r, {String? namespace, required String name, required String action, Json body = const {}}) async {
    actions.add((action, body));
    return ActionResult(message: '$action ok');
  }
}

Future<AppState> pumpArgo(WidgetTester tester, Json object,
    {ApiClient? api, Size size = const Size(560, 2400), bool readOnly = false, ArgoDiffApi Function(ApiClient)? diffApi}) async {
  final t = typeOf(object);
  final client = api ?? ArgoFakeApi();
  // No argocd-server unless the test provides one (never real HTTP).
  ArgoDiffApi.debugOverride = diffApi ?? FakeArgoDiffApi.notFound;
  ArgoDiffCache.reset();
  addTearDown(() => ArgoDiffApi.debugOverride = null);
  final app = AppState(client)
    ..types = argoTypes
    ..readOnly = readOnly
    ..currentContext = 'kind-k8sman-dev';
  final panel = panelFor(t);
  app.openDetail(DetailTarget(type: t, name: '${object['metadata']?['name']}', namespace: object['metadata']?['namespace']));
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          backgroundColor: AppColors.of(context).inspector,
          body: Builder(builder: (context) {
            final ctx = PanelContext(object: object, type: t, api: client, app: app);
            return ListView(padding: const EdgeInsets.fromLTRB(16, 12, 16, 24), children: panel.buildSections(context, ctx));
          }),
        ),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return app;
}

void main() {
  group('helpers', () {

    test('live health follows Argo rules', () {
      final degraded = fxList('live-guestbook-degraded-deployments.json').first;
      expect(liveHealth('apps', 'Deployment', degraded)!.status, 'Degraded');
      expect(liveHealth('apps', 'Deployment', fxList('live-guestbook-deployments.json').first)!.status, 'Healthy');
      final badPod = fxList('live-guestbook-degraded-pods.json').firstWhere((p) => '${p['metadata']['name']}'.contains('755cbff6db'), orElse: () => {});
      if (badPod.isNotEmpty) expect(liveHealth('', 'Pod', badPod)!.status, 'Degraded');
      expect(liveHealth('', 'Service', {'spec': {'type': 'ClusterIP'}})!.status, 'Healthy');
      expect(liveHealth('', 'Service', {'spec': {'type': 'LoadBalancer'}})!.status, 'Progressing');
      expect(liveHealth('', 'ConfigMap', {}), isNull);
      expect(liveHealth('apps', 'Deployment', {'spec': {'paused': true}})!.status, 'Suspended');
    });

    test('managed resources: derived health, missing, worst first', () {
      final entries = [
        {'kind': 'Service', 'name': 'ok', 'namespace': 'ns', 'status': 'Synced', 'version': 'v1'},
        {'group': 'apps', 'kind': 'Deployment', 'name': 'gone', 'namespace': 'ns', 'status': 'OutOfSync'},
        {'group': 'apps', 'kind': 'Deployment', 'name': 'web', 'namespace': 'ns', 'status': 'Synced', 'health': {'status': 'Degraded', 'message': 'boom'}},
      ];
      final live = LiveIndex({
        resourceKey('', 'Service', 'ns', 'ok'): {'spec': {'type': 'ClusterIP'}},
      }, const {}, {'/Service/ns', 'apps/Deployment/ns'});
      final rs = managedResources(entries, live);
      expect(rs[0].health!.status, 'Healthy');
      expect(rs[1].health!.status, 'Missing');
      expect(rs[2].health!.message, 'boom');
      final groups = groupByKind(rs);
      expect(groups.first.key, 'Deployment');
      expect(applyFilter(rs, ResourceFilter.outOfSync).single.name, 'gone');
      expect(applyFilter(rs, ResourceFilter.unhealthy).length, 2);
    });

  });

  group('Application panel', () {
    testWidgets('synced app: status, source, resources, history', (tester) async {
      await loadRealFonts();
      await pumpArgo(tester, fx('app-guestbook.json'));
      expect(tester.takeException(), isNull);
      expect(find.text('Synced'), findsWidgets);
      expect(find.text('Healthy'), findsWidgets);
      expect(find.text('8088f4c'), findsWidgets);
      expect(find.text('https://github.com/argoproj/argocd-example-apps'), findsOneWidget);
      expect(find.text('guestbook-ui'), findsWidgets);
      expect(find.text('#0'), findsOneWidget);
      expect(find.text('Sync'), findsOneWidget);
    });

    testWidgets('degraded app derives health from live objects', (tester) async {
      await loadRealFonts();
      await pumpArgo(tester, fx('app-guestbook-degraded.json'));
      expect(tester.takeException(), isNull);
      expect(find.text('Degraded'), findsWidgets);
      expect(find.textContaining('timed out progressing'), findsWidgets);
    });

    testWidgets('sync dialog runs argocd-sync with options', (tester) async {
      final api = ArgoFakeApi();
      await pumpArgo(tester, fx('app-helm-guestbook.json'), api: api);
      await tester.tap(find.text('Sync'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prune'));
      await tester.enterText(find.byType(TextField), 'master');
      await tester.pumpAndSettle();
      await loadRealFonts();
      await tester.tap(find.text('Next'));
      await tester.pumpAndSettle();
      expect(find.textContaining('deleted (prune)'), findsOneWidget);
      await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.widgetWithText(FilledButton, 'Sync')));
      await tester.pumpAndSettle();
      expect(api.actions.single.$1, 'argocd-sync');
      expect(api.actions.single.$2, {'prune': true, 'targetRevision': 'master'});
    });

    testWidgets('running operation offers terminate', (tester) async {
      final api = ArgoFakeApi();
      final obj = fx('app-helm-guestbook.json')
        ..['operation'] = {'sync': {}}
        ..['status'] = {
          ...fx('app-helm-guestbook.json')['status'] as Json,
          'operationState': {'phase': 'Running', 'startedAt': DateTime.now().toUtc().toIso8601String(), 'message': 'waiting for healthy state'},
        };
      await pumpArgo(tester, obj, api: api);
      expect(find.text('Terminate'), findsOneWidget);
      await tester.tap(find.text('Terminate'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Terminate'));
      await tester.pumpAndSettle();
      expect(api.actions.single.$1, 'argocd-terminate');
      final ctx = PanelContext(object: obj, type: appType, api: api, app: AppState(api));
      expect(const ApplicationPanel().actions(ctx).map((a) => a.id), contains('argocd-terminate'));
    });

    testWidgets('read-only hides actions', (tester) async {
      final api = ArgoFakeApi();
      final app = await pumpArgo(tester, fx('app-helm-guestbook.json'), api: api, readOnly: true);
      expect(find.text('Sync'), findsNothing);
      expect(find.text('Refresh'), findsNothing);
      final ctx = PanelContext(object: fx('app-helm-guestbook.json'), type: appType, api: api, app: app);
      expect(const ApplicationPanel().actions(ctx), isEmpty);
    });
  });

  group('ApplicationSet panel', () {
    testWidgets('generators, template and generated apps', (tester) async {
      await loadRealFonts();
      await pumpArgo(tester, fx('appset-guestbook-envs.json'));
      expect(tester.takeException(), isNull);
      expect(find.text('guestbook-dev'), findsOneWidget);
      expect(find.text('guestbook-staging'), findsOneWidget);
      expect(find.text('staging'), findsOneWidget);
      expect(find.textContaining('Preserve'), findsOneWidget);
    });
  });

  group('AppProject panel', () {
    testWidgets('restricted project', (tester) async {
      await loadRealFonts();
      await pumpArgo(tester, fx('project-demo-team.json'));
      expect(tester.takeException(), isNull);
      expect(find.text('Restricted'), findsOneWidget);
      expect(find.textContaining('CI pipeline', findRichText: true), findsOneWidget);
      expect(find.text('ResourceQuota'), findsOneWidget);
      expect(find.text('guestbook'), findsOneWidget); // an app in this project
    });

  });

  testWidgets('narrow (320px) layout', (tester) async {
    await loadRealFonts();
    await pumpArgo(tester, fx('app-guestbook-degraded.json'), size: const Size(320, 2400));
    expect(tester.takeException(), isNull);
  });

}

Json asMapOf(Json o, List<String> path) {
  dynamic cur = o;
  for (final p in path) {
    cur = (cur as Map)[p];
  }
  return Map<String, dynamic>.from(cur as Map);
}

List<Json> asListOf(Json o, List<String> path) {
  dynamic cur = o;
  for (final p in path) {
    cur = (cur as Map)[p];
  }
  return [for (final e in cur as List) Map<String, dynamic>.from(e as Map)];
}
