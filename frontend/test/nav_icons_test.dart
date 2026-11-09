import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/main.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:k8sman/ui/resource_nav.dart';
import 'package:k8sman/ui/widgets/group_icon.dart';
import 'package:provider/provider.dart';

import 'group_icon_test.dart' show solidPng;
import 'support/fixture_api.dart';

ResourceType crd(String group, String kind, {bool namespaced = true}) => ResourceType(
      group: group,
      version: 'v1',
      resource: '${kind.toLowerCase()}s',
      kind: kind,
      namespaced: namespaced,
      verbs: const ['get', 'list', 'watch'],
      custom: true,
    );

/// The fixture cluster plus CRDs from several projects; one unbundled group
/// (traefik.io) gets its icon from the backend.
class CrdFixtureApi extends FixtureApi {
  final Uint8List traefikIcon;
  CrdFixtureApi(this.traefikIcon);

  static final extra = [
    crd('argoproj.io', 'Application'),
    crd('argoproj.io', 'ApplicationSet'),
    crd('argoproj.io', 'AppProject'),
    crd('cert-manager.io', 'Certificate'),
    crd('cert-manager.io', 'ClusterIssuer', namespaced: false),
    crd('monitoring.coreos.com', 'Prometheus'),
    crd('monitoring.coreos.com', 'ServiceMonitor'),
    crd('keda.sh', 'ScaledObject'),
    crd('gateway.networking.k8s.io', 'Gateway'),
    crd('gateway.networking.k8s.io', 'HTTPRoute'),
    crd('aquasecurity.github.io', 'VulnerabilityReport'),
    crd('traefik.io', 'IngressRoute'),
  ];

  @override
  Future<List<ResourceType>> resources({bool refresh = false}) async => [...FixtureApi.types, ...extra];

  @override
  Future<Uint8List?> groupIcon(String group) async => group == 'traefik.io' ? traefikIcon : null;

  static ResourceType? _extra(ResourceRef r) => extra.where((t) => t.group == r.group && t.resource == r.resource).firstOrNull;

  static Json _object(ResourceType t) => {
        'apiVersion': '${t.group}/${t.version}',
        'kind': t.kind,
        'metadata': {'name': 'guestbook', 'namespace': 'argocd', 'uid': 'u-guestbook', 'creationTimestamp': '2026-11-01T10:00:00Z'},
        'spec': {'project': 'default'},
        'status': {
          'sync': {'status': 'Synced'},
          'health': {'status': 'Healthy'},
        },
      };

  @override
  Stream<WatchMessage> watch(ResourceRef r, {String? namespace, NamespaceScope? scope, String? labelSelector, String? fieldSelector, bool includeObject = false, List<ColumnDef>? columns}) {
    final t = _extra(r);
    if (t == null) {
      return super.watch(r, namespace: namespace, scope: scope, labelSelector: labelSelector, fieldSelector: fieldSelector, includeObject: includeObject, columns: columns);
    }
    final o = _object(t);
    return Stream.value(WatchMessage(
      type: 'SNAPSHOT',
      table: TableData(resource: t, columns: const [], isDefaultColumns: true, resourceVersion: '1', rows: [
        TableRowData(uid: 'u-guestbook', name: 'guestbook', namespace: 'argocd', resourceVersion: '1', cells: const [], object: o),
      ]),
    ));
  }

  @override
  Future<Json> object(ResourceRef r, {String? namespace, required String name}) async {
    final t = _extra(r);
    return t == null ? super.object(r, namespace: namespace, name: name) : _object(t);
  }
}

Future<AppState> pumpApp(WidgetTester tester, ApiClient api, ThemeMode mode) async {
  tester.view.physicalSize = const Size(1200, 1400); // the custom groups fit above the sidebar's footer
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(api);
  await app.init();
  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<LogDock>.value(value: LogDock(api)),
    ],
    child: K8sManApp(themeMode: mode),
  ));
  await tester.pump(const Duration(milliseconds: 50));
  return app;
}

/// Lets asset loads and image decodes (real async) finish.
Future<void> settleImages(WidgetTester tester) async {
  for (var i = 0; i < 3; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump();
  }
}

void main() {
  setUp(GroupIconCache.clear);

  {
    const mode = ThemeMode.light;
    testWidgets('nav with custom resource groups', (tester) async {
      final png = (await tester.runAsync(() => solidPng(const Color(0xFF24A1C1), size: 64)))!;
      final app = await pumpApp(tester, CrdFixtureApi(png), mode);
      // CRD groups live under a collapsed "Custom Resources" header.
      // (Expanded state is session-wide, so only tap when still collapsed.)
      if (find.text('traefik.io').evaluate().isEmpty) {
        await tester.ensureVisible(find.text('Custom Resources'));
        await tester.tap(find.text('Custom Resources'));
        await tester.pump();
      }
      // Scroll the source list down to the custom resource groups.
      for (final s in tester.stateList<ScrollableState>(find.descendant(of: find.byType(ResourceNav), matching: find.byType(Scrollable)))) {
        if (s.position.axis == Axis.vertical) s.position.jumpTo(s.position.maxScrollExtent);
      }
      await tester.pump();
      await settleImages(tester);

      // Group headers and items show their group's icon; built-ins keep glyphs.
      // Logos only on uncurated CRD group headers (one each), not on items
      // and not on curated sections such as Argo CD.
      expect(find.byKey(const ValueKey('group-icon-image/traefik.io')), findsOneWidget);
      expect(find.byKey(const ValueKey('group-icon-monogram/example.k8sman.dev')), findsOneWidget);
      expect(find.descendant(of: find.byType(ResourceNav), matching: find.byKey(const ValueKey('group-icon-image/argoproj.io'))), findsNothing);

      // Select a custom kind and open one: toolbar + inspector header icons.
      app.selectType(app.typeFor('argoproj.io', 'Application')!);
      app.openDetail(DetailTarget(type: app.typeFor('argoproj.io', 'Application')!, name: 'guestbook', namespace: 'argocd'));
      await tester.pump(const Duration(milliseconds: 50));
      await settleImages(tester);
      expect(tester.takeException(), isNull);
    });
  }
}
