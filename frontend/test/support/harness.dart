import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/registry.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:k8sman/ui/logs/log_dock_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

/// Canned API for panel tests. Register responses keyed by resource key
/// (`pods`, `replicasets.apps`, ...) — label/field selectors are ignored
/// unless you supply [itemsFilter].
class FakeApiClient extends ApiClient {
  final Map<String, List<Json>> itemsByResource;
  final List<Json> eventItems;
  final Map<String, Json> objects; // key: '<resourceKey>/<ns>/<name>'
  final Map<String, List<LogMessage>> logLines; // key: '<ns>/<pod>/<container>'
  final bool Function(ResourceRef r, Json item, String? labelSelector, String? fieldSelector)? itemsFilter;

  FakeApiClient({
    this.itemsByResource = const {},
    this.eventItems = const [],
    this.objects = const {},
    this.logLines = const {},
    this.itemsFilter,
  }) : super(base: Uri.parse('http://fake'));

  @override
  Future<List<Json>> items(ResourceRef r, {String? namespace, NamespaceScope? scope, String? labelSelector, String? fieldSelector}) async {
    final all = itemsByResource[r.key] ?? const [];
    return [
      for (final i in all)
        if ((namespace == null || i['metadata']?['namespace'] == namespace) &&
            (itemsFilter == null || itemsFilter!(r, i, labelSelector, fieldSelector)))
          i,
    ];
  }

  @override
  Future<({List<Json> items, Object? partialErrors})> itemsWithPartial(ResourceRef r,
          {String? namespace, NamespaceScope? scope, String? labelSelector, String? fieldSelector}) async =>
      (items: await items(r, namespace: namespace, scope: scope, labelSelector: labelSelector, fieldSelector: fieldSelector), partialErrors: partialErrors);

  /// What the fake reports as a response's `partialErrors`.
  Object? partialErrors;

  @override
  Future<List<Json>> events({String? namespace, String? uid, String? kind, String? name}) async => eventItems;

  /// The saved sidebar layout (settings.json stand-in).
  Json? sidebarLayout;

  @override
  Future<Json?> getSidebar() async => sidebarLayout;

  @override
  Future<void> putSidebar(Json? layout) async => sidebarLayout = layout;

  @override
  Future<Json> object(ResourceRef r, {String? namespace, required String name}) async {
    final o = objects['${r.key}/${namespace ?? ''}/$name'];
    if (o == null) throw ApiException(404, 'not found');
    return o;
  }

  @override
  Stream<LogMessage> logs({
    required String namespace,
    required String pod,
    String? container,
    int tailLines = 500,
    bool previous = false,
    bool follow = true,
    bool timestamps = false,
    int? sinceSeconds,
  }) =>
      Stream.fromIterable([...?logLines['$namespace/$pod/${container ?? ''}'], const LogMessage(eof: true)]);
}

/// Standard discovered types so ResourceLinks resolve in tests.
const testTypes = <ResourceType>[
  ResourceType(group: '', version: 'v1', resource: 'pods', kind: 'Pod'),
  ResourceType(group: '', version: 'v1', resource: 'nodes', kind: 'Node', namespaced: false),
  ResourceType(group: '', version: 'v1', resource: 'services', kind: 'Service'),
  ResourceType(group: '', version: 'v1', resource: 'configmaps', kind: 'ConfigMap'),
  ResourceType(group: '', version: 'v1', resource: 'secrets', kind: 'Secret'),
  ResourceType(group: '', version: 'v1', resource: 'serviceaccounts', kind: 'ServiceAccount'),
  ResourceType(group: '', version: 'v1', resource: 'persistentvolumeclaims', kind: 'PersistentVolumeClaim'),
  ResourceType(group: '', version: 'v1', resource: 'persistentvolumes', kind: 'PersistentVolume', namespaced: false),
  ResourceType(group: '', version: 'v1', resource: 'namespaces', kind: 'Namespace', namespaced: false),
  ResourceType(group: '', version: 'v1', resource: 'events', kind: 'Event'),
  ResourceType(group: '', version: 'v1', resource: 'endpoints', kind: 'Endpoints'),
  ResourceType(group: 'apps', version: 'v1', resource: 'deployments', kind: 'Deployment'),
  ResourceType(group: 'apps', version: 'v1', resource: 'replicasets', kind: 'ReplicaSet'),
  ResourceType(group: 'apps', version: 'v1', resource: 'statefulsets', kind: 'StatefulSet'),
  ResourceType(group: 'apps', version: 'v1', resource: 'daemonsets', kind: 'DaemonSet'),
  ResourceType(group: 'batch', version: 'v1', resource: 'jobs', kind: 'Job'),
  ResourceType(group: 'batch', version: 'v1', resource: 'cronjobs', kind: 'CronJob'),
  ResourceType(group: 'autoscaling', version: 'v2', resource: 'horizontalpodautoscalers', kind: 'HorizontalPodAutoscaler'),
  ResourceType(group: 'networking.k8s.io', version: 'v1', resource: 'ingresses', kind: 'Ingress'),
  ResourceType(group: 'networking.k8s.io', version: 'v1', resource: 'ingressclasses', kind: 'IngressClass', namespaced: false),
  ResourceType(group: 'networking.k8s.io', version: 'v1', resource: 'networkpolicies', kind: 'NetworkPolicy'),
  ResourceType(group: 'discovery.k8s.io', version: 'v1', resource: 'endpointslices', kind: 'EndpointSlice'),
  ResourceType(group: 'storage.k8s.io', version: 'v1', resource: 'storageclasses', kind: 'StorageClass', namespaced: false),
  ResourceType(group: 'rbac.authorization.k8s.io', version: 'v1', resource: 'roles', kind: 'Role'),
  ResourceType(group: 'rbac.authorization.k8s.io', version: 'v1', resource: 'clusterroles', kind: 'ClusterRole', namespaced: false),
  ResourceType(group: 'rbac.authorization.k8s.io', version: 'v1', resource: 'rolebindings', kind: 'RoleBinding'),
  ResourceType(group: 'rbac.authorization.k8s.io', version: 'v1', resource: 'clusterrolebindings', kind: 'ClusterRoleBinding', namespaced: false),
  ResourceType(group: 'apiextensions.k8s.io', version: 'v1', resource: 'customresourcedefinitions', kind: 'CustomResourceDefinition', namespaced: false),
  ResourceType(group: 'external-secrets.io', version: 'v1', resource: 'externalsecrets', kind: 'ExternalSecret', custom: true),
  ResourceType(group: 'external-secrets.io', version: 'v1', resource: 'secretstores', kind: 'SecretStore', custom: true),
  ResourceType(group: 'external-secrets.io', version: 'v1', resource: 'clustersecretstores', kind: 'ClusterSecretStore', namespaced: false, custom: true),
  ResourceType(group: 'example.k8sman.dev', version: 'v1alpha1', resource: 'widgets', kind: 'Widget', custom: true),
];

ResourceType testType(String group, String kind) => testTypes.firstWhere((t) => t.group == group && t.kind == kind);

/// Renders [object] through the registered panel for its kind (exactly as
/// the sidebar Overview tab does) and returns the AppState for assertions
/// on navigation (e.g. `app.detail` after tapping a ResourceLink).
Future<AppState> pumpPanel(
  WidgetTester tester,
  Json object, {
  ApiClient? api,
  ResourceType? type,
  Size size = const Size(560, 2400),
  bool readOnly = false,
}) async {
  final apiVersion = '${object['apiVersion']}';
  final group = apiVersion.contains('/') ? apiVersion.split('/').first : '';
  final t = type ?? testType(group, '${object['kind']}');
  final client = api ?? FakeApiClient();
  final app = AppState(client)
    ..types = testTypes
    ..readOnly = readOnly;
  final panel = panelFor(t);
  // Seed a detail so openRef pushes (canGoBack becomes true on navigation).
  app.openDetail(DetailTarget(type: t, name: '${object['metadata']?['name']}', namespace: object['metadata']?['namespace']));

  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: client),
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<LogDock>(create: (_) => LogDock(client)),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Builder(
        // Same background and padding as the sidebar's Overview tab.
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

/// Renders one of the panel's extra tabs (by label).
Future<void> pumpPanelTab(
  WidgetTester tester,
  Json object,
  String tabLabel, {
  ApiClient? api,
  ResourceType? type,
  Size size = const Size(900, 1400),
}) async {
  final apiVersion = '${object['apiVersion']}';
  final group = apiVersion.contains('/') ? apiVersion.split('/').first : '';
  final t = type ?? testType(group, '${object['kind']}');
  final client = api ?? FakeApiClient();
  final app = AppState(client)..types = testTypes;
  final ctx = PanelContext(object: object, type: t, api: client, app: app);
  final tab = panelFor(t).tabs(ctx).firstWhere((x) => x.label == tabLabel);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: Builder(builder: (c) => tab.builder(c, ctx))),
    ),
  ));
  await tester.pump(const Duration(milliseconds: 100));
}

/// Opens [pod]'s logs in a fresh [LogDock] and renders the dock alone
/// (as the bottom panel, filling [size]). Returns the dock; call
/// `dock.closeAll()` before the test ends to stop any polling timers.
Future<LogDock> pumpLogDock(
  WidgetTester tester,
  Json pod, {
  ApiClient? api,
  String? container,
  bool previous = false,
  Size size = const Size(900, 500),
}) async {
  final client = api ?? FakeApiClient();
  final dock = LogDock(client)..open(pod, container: container, previous: previous);
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<LogDock>.value(value: dock)],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: Column(children: [const Spacer(), LogDockView(maxHeight: size.height)])),
    ),
  ));
  dock.setHeight(size.height);
  for (var i = 0; i < 3; i++) {
    await tester.pump(const Duration(milliseconds: 60));
  }
  return dock;
}

/// Equality-only label selector matching (`a=b,c=d`), enough for the fixtures.
bool matchesLabelSelector(Json item, String? selector) {
  if (selector == null || selector.isEmpty) return true;
  final labels = (item['metadata']?['labels'] as Map?) ?? const {};
  for (final part in selector.split(',')) {
    final kv = part.split('=');
    if (kv.length != 2 || labels[kv[0]]?.toString() != kv[1]) return false;
  }
  return true;
}

/// A [FakeApiClient.itemsFilter] that honours label selectors.
bool labelSelectorFilter(ResourceRef r, Json item, String? labelSelector, String? fieldSelector) => matchesLabelSelector(item, labelSelector);
