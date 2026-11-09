import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/addons/addon_status.dart';
import 'package:k8sman/addons/addons.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/modules/addons_module.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/addons/addons_view.dart';
import 'package:k8sman/ui/helm/helm_api.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'addons_fakes.dart';

Map<String, AddonStatus> detectAll({String dir = '', List<HelmRelease>? releases, List<Json>? deployments, List<ResourceType>? types}) {
  final rs = releases ?? fixtureReleases(dir);
  final crds = servedCrdKeys(types ?? fixtureTypes(dir));
  final deps = deployments ?? fixtureDeployments(dir);
  return {for (final a in addonCatalog) a.id: detectAddon(a, servedCrds: crds, releases: rs, deployments: deps)};
}

HelmRelease copyRelease(HelmRelease r, {String? status, String? chartVersion}) => HelmRelease(
      name: r.name,
      namespace: r.namespace,
      revision: r.revision,
      status: status ?? r.status,
      chart: r.chart,
      chartVersion: chartVersion ?? r.chartVersion,
      appVersion: r.appVersion,
    );

Future<(AppState, FakeAddonHelmApi)> pumpAddons(
  WidgetTester tester, {
  Size size = const Size(1200, 820),
  bool readOnly = false,
  String context = 'kind-k8sman-dev',
  FakeAddonHelmApi? helm,
  AddonsApiClient? api,
  Widget? body,
}) async {
  final client = api ?? AddonsApiClient();
  final h = helm ?? FakeAddonHelmApi();
  final app = AppState(client)
    ..types = client.types
    ..readOnly = readOnly
    ..currentContext = context
    ..view = AddonsModule.page;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: client),
      Provider<HelmApi>.value(value: h),
      ChangeNotifierProvider<AppState>.value(value: app),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: body ?? const AddonsView()),
    ),
  ));
  await settle(tester);
  return (app, h);
}

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 50));
  }
}

Finder inCard(String id, Finder f) => find.descendant(of: find.byKey(ValueKey('addon-$id')), matching: f);

void main() {
  group('versions and manifests', () {
    test('compareChartVersions ignores v and orders pre-releases first', () {
      expect(compareChartVersions('v1.2.8', '1.2.8'), 0);
      expect(compareChartVersions('92.17.1', '92.9.0'), greaterThan(0));
      expect(compareChartVersions('1.11.0-rc.0', '1.11.0'), lessThan(0));
      expect(compareChartVersions('v1.21.3', 'v1.21.10'), lessThan(0));
    });

  });

  group('detection (captured from the dev cluster)', () {
    test('installed via Helm, not via Helm, not installed', () {
      final s = detectAll();
      expect(s[AddonIds.metricsServer]!.state, AddonState.installed);
      expect(s[AddonIds.metricsServer]!.release!.chartVersion, '3.14.0');
      expect(s[AddonIds.prometheus]!.state, AddonState.installed);
      expect(s[AddonIds.prometheus]!.deployments.map((d) => d.name), containsAll(['kube-prometheus-stack-operator', 'kube-prometheus-stack-grafana']));
      // prometheus-adapter shares the namespace but isn't part of the release.
      expect(s[AddonIds.prometheus]!.deployments.map((d) => d.name), isNot(contains('prometheus-adapter')));
      expect(s[AddonIds.trivyOperator]!.state, AddonState.installed);
      expect(s[AddonIds.argoCd]!.state, AddonState.external, reason: 'applied from the upstream manifest');
      expect(s[AddonIds.argoCd]!.release, isNull);
      expect(s[AddonIds.argoCd]!.deployments, hasLength(6));
      expect(s[AddonIds.envoyGateway]!.state, AddonState.installed);
      expect(s[AddonIds.envoyGateway]!.deployments.map((d) => d.name), ['envoy-gateway'], reason: 'proxies are not part of the release');
      expect(s[AddonIds.envoyGateway]!.upgradeAvailable, isFalse, reason: 'pinned v1.2.8 is installed');
      expect(s[AddonIds.certManager]!.state, AddonState.notInstalled);
    });

  });

  group('page', () {
    testWidgets('cards show state, versions and actions', (tester) async {
      final (_, helm) = await pumpAddons(tester);
      expect(find.text('5 installed · 1 available'), findsOneWidget);
      expect(inCard(AddonIds.certManager, find.text('Not installed')), findsOneWidget);
      expect(inCard(AddonIds.certManager, find.text('Install…')), findsOneWidget);
      expect(inCard(AddonIds.argoCd, find.text('Installed · not via Helm')), findsOneWidget);
      expect(inCard(AddonIds.argoCd, find.text('Uninstall…')), findsNothing);
      expect(inCard(AddonIds.argoCd, find.text('View release')), findsNothing);
      expect(inCard(AddonIds.trivyOperator, find.text('Installed')), findsOneWidget);
      expect(inCard(AddonIds.trivyOperator, find.text('1/1 deployment available')), findsOneWidget);
      expect(inCard(AddonIds.trivyOperator, find.text('Security')), findsOneWidget);
      // metrics-server is unpinned: its latest version loads in the background.
      expect(helm.calls, contains('chart-versions metrics-server'));
      expect(inCard(AddonIds.metricsServer, find.text('Upgrade available: 3.15.0')), findsOneWidget);
      expect(inCard(AddonIds.metricsServer, find.text('Upgrade…')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('install flow: dry run, then confirm naming the context', (tester) async {
      final (_, helm) = await pumpAddons(tester);
      await tester.ensureVisible(inCard(AddonIds.certManager, find.text('Install…')));
      await tester.pump();
      await tester.tap(inCard(AddonIds.certManager, find.text('Install…')));
      await settle(tester);
      expect(find.text('Install cert-manager'), findsOneWidget);
      expect(find.text('Release name'), findsOneWidget);
      // Default version is the latest stable (cert-manager isn't pinned).
      expect(find.textContaining('v1.21.3'), findsWidgets);

      await tester.tap(find.text('Dry run'));
      await settle(tester);
      expect(helm.calls, contains('install cert-manager/cert-manager cert-manager@v1.21.3 dryRun=true wait=false timeout=null'));
      expect(find.textContaining('Dry run OK: renders 46 objects'), findsOneWidget);
      expect(find.text('6 CustomResourceDefinition'), findsOneWidget);

      await tester.tap(find.text('Install…').last);
      await settle(tester);
      expect(find.text('Install cert-manager?'), findsOneWidget);
      expect(find.text('kind-k8sman-dev'), findsOneWidget);
      expect(find.textContaining('Creates cluster-wide resources: the cert-manager.io CRDs'), findsOneWidget);
      expect(helm.calls.where((c) => c.contains('dryRun=false')), isEmpty);

      await tester.tap(find.widgetWithText(FilledButton, 'Install'));
      await settle(tester);
      expect(helm.calls.last, 'install cert-manager/cert-manager cert-manager@v1.21.3 dryRun=false wait=true timeout=300');
      expect(find.text('Installed cert-manager'), findsOneWidget);
      expect(find.text('What\'s next'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('uninstall warns about CRDs and data, then uninstalls', (tester) async {
      final (_, helm) = await pumpAddons(tester);
      await tester.tap(inCard(AddonIds.prometheus, find.text('Uninstall…')));
      await settle(tester);
      expect(find.text('Uninstall Prometheus stack?'), findsOneWidget);
      expect(find.textContaining('CRDs, and with them every custom resource'), findsOneWidget);
      expect(find.textContaining('All stored metrics'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Uninstall'));
      await settle(tester);
      expect(helm.calls, contains('uninstall monitoring/kube-prometheus-stack'));
    });

    testWidgets('read-only: status only, no mutations', (tester) async {
      await pumpAddons(tester, readOnly: true);
      expect(find.textContaining('Read-only mode'), findsOneWidget);
      expect(find.text('Install…'), findsNothing);
      expect(find.text('Uninstall…'), findsNothing);
      expect(find.text('View release'), findsWidgets);
    });

  });

}
