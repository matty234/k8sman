import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/addons/addons_view.dart';
import 'package:k8sman/ui/helm/helm_view.dart';
import 'package:k8sman/ui/alerts/alerts_view.dart';
import 'package:k8sman/ui/nodes/nodes_view.dart';
import 'package:k8sman/ui/portforward/portforward_view.dart';
import 'package:k8sman/ui/resource_table.dart';
import 'package:k8sman/ui/security/security_api.dart';
import 'package:k8sman/ui/security/security_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/ui/widgets/common.dart';
import 'package:provider/provider.dart';

import 'addons/addons_fakes.dart';
import 'helm/fake_helm_api.dart';
import 'prometheus/prom_fixtures.dart';
import 'support/harness.dart';

/// Every main-area page must use the same header height as the titlebar,
/// so switching pages doesn't make the top bar jump.
class _Api extends FakeApiClient {
  _Api() : super(itemsByResource: {'nodes': [jsonDecode(File('../dev/fixtures/node-k8sman-dev-control-plane.json').readAsStringSync())], 'pods': []});
  @override
  Future<List<PortForward>> portForwards() async => [];
  @override
  Future<Json> metrics(String path, [Map<String, String?> query = const {}]) async => throw ApiException(404, 'metrics.k8s.io is not installed');
  @override
  Stream<WatchMessage> watch(ResourceRef r, {String? namespace, NamespaceScope? scope, String? labelSelector, String? fieldSelector, bool includeObject = false, List<ColumnDef>? columns}) =>
      Stream.value(WatchMessage(type: 'SNAPSHOT', table: TableData.fromJson(jsonDecode(File('../dev/fixtures/api-table-pods.json').readAsStringSync()))));
}

void main() {
  final pages = <String, Widget Function(ResourceType pods)>{
    'table': (t) => ResourceTableView(type: t),
    'nodes': (_) => const NodesView(),
    'port forwards': (_) => const PortForwardView(),
    'helm': (_) => HelmView(api: FakeHelmApi()),
    'add-ons': (_) => AddonsView(api: FakeAddonHelmApi()),
    'security': (_) => SecurityView(source: _SecurityApi()),
    'alerts': (_) => AlertsView(source: FixturePromApi()),
  };
  for (final e in pages.entries) {
    testWidgets('${e.key} header is titlebar height', (tester) async {
      final api = _Api();
      final app = AppState(api)..types = testTypes;
      tester.view.physicalSize = const Size(1200, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
        child: MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(body: e.value(testType('', 'Pod')))),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 20));
      // The first Divider separates header from content; it must sit at titlebarHeight.
      final dividerTop = tester.getTopLeft(find.byType(Divider).first).dy;
      expect(dividerTop, closeTo(titlebarHeight, 1), reason: '${e.key} header height');
      if (e.key != 'table') expect(find.byType(PageHeader), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    });
  }
}

class _SecurityApi extends SecurityApi {
  _SecurityApi() : super(_Api());
  @override
  Future<SecurityData> fetch({NamespaceScope scope = NamespaceScope.all, bool includeSystem = false}) async =>
      SecurityData.fromJson(jsonDecode(File('test/security/fixtures/security-demo.json').readAsStringSync()));
  @override
  Future<ScannerStatus> scanner() async => const ScannerStatus();
}
