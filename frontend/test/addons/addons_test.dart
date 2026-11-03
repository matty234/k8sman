import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/addons/addon_status.dart';
import 'package:k8sman/addons/addons.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/addons/addons_view.dart';
import 'package:k8sman/ui/helm/helm_api.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/screenshot.dart';
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
    ..view = MainView.addons;
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

    test('latestStable skips pre-releases', () {
      final v = [
        for (final s in ['1.11.0-rc.0', '1.10.0-rc.1', '1.9.3']) HelmChartVersion(version: s),
      ];
      expect(latestStable(v), '1.9.3');
    });

    test('manifestKinds counts the real cert-manager dry run', () {
      final r = HelmResult.fromJson(Map<String, dynamic>.from(readFixture('install-dryrun-cert-manager.json')));
      final kinds = Map.fromEntries([for (final (k, n) in manifestKinds(r.manifest)) MapEntry(k, n)]);
      expect(kinds['CustomResourceDefinition'], 6);
      expect(kinds['Deployment'], 3);
      expect(kinds['ValidatingWebhookConfiguration'], 1);
      expect(r.notes, contains('cert-manager'));
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

    test('after a real cert-manager install it is Installed with 3 healthy deployments', () {
      final s = detectAll(dir: 'with-cert-manager/')[AddonIds.certManager]!;
      expect(s.state, AddonState.installed);
      expect(s.release!.chartVersion, 'v1.21.3');
      expect(s.crdServed, isTrue);
      expect(s.deployments.map((d) => d.name), ['cert-manager', 'cert-manager-cainjector', 'cert-manager-webhook']);
    });

    test('after uninstall, CRDs left behind are not "installed"', () {
      final s = detectAll(types: fixtureTypes('after-uninstall/'))[AddonIds.certManager]!;
      expect(s.state, AddonState.notInstalled);
      expect(s.leftoverCrds, isTrue);
    });

    test('unhealthy: failed release or a key deployment with nothing available', () {
      final deps = fixtureDeployments();
      final trivy = deps.firstWhere((d) => d['metadata']['name'] == 'trivy-operator');
      trivy['status'] = {'replicas': 1, 'unavailableReplicas': 1};
      final s = detectAll(deployments: deps)[AddonIds.trivyOperator]!;
      expect(s.state, AddonState.unhealthy);
      expect(s.problem, 'trivy-operator has no available replicas');

      final rs = [for (final r in fixtureReleases()) r.name == 'eg' ? copyRelease(r, status: 'failed') : r];
      final eg = detectAll(releases: rs)[AddonIds.envoyGateway]!;
      expect(eg.state, AddonState.unhealthy);
      expect(eg.problem, 'Helm release eg failed');
    });

    test('upgrade available: pinned version newer, or latest for unpinned', () {
      final rs = [for (final r in fixtureReleases()) r.name == 'kube-prometheus-stack' ? copyRelease(r, chartVersion: '92.0.0') : r];
      final s = detectAll(releases: rs);
      expect(s[AddonIds.prometheus]!.upgradeAvailable, isTrue);
      expect(s[AddonIds.prometheus]!.targetVersion, '92.17.1');
      final ms = s[AddonIds.metricsServer]!;
      expect(ms.upgradeAvailable, isFalse, reason: 'no target until chart versions load');
      expect(ms.withTarget('3.15.0').upgradeAvailable, isTrue);
      expect(ms.withTarget('3.14.0').upgradeAvailable, isFalse);
    });

    test('a release under another name still counts', () {
      final rs = [for (final r in fixtureReleases()) if (r.name != 'trivy-operator') r, const HelmRelease(name: 'scanner', namespace: 'security', revision: 1, status: 'deployed', chart: 'trivy-operator', chartVersion: '0.38.1')];
      final s = detectAll(releases: rs)[AddonIds.trivyOperator]!;
      expect(s.release!.name, 'scanner');
      expect(s.customRelease, isTrue);
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

    testWidgets('View release opens the Helm page focused on it', (tester) async {
      final (app, _) = await pumpAddons(tester);
      await tester.tap(inCard(AddonIds.trivyOperator, find.text('View release')));
      expect(app.view, MainView.helm);
      expect(app.helmFocus, 'trivy-system/trivy-operator');
    });

    testWidgets('Security link navigates', (tester) async {
      final (app, _) = await pumpAddons(tester);
      await tester.tap(inCard(AddonIds.trivyOperator, find.text('Security')));
      expect(app.view, MainView.security);
    });

    testWidgets('install flow: dry run, then confirm naming the context', (tester) async {
      final (_, helm) = await pumpAddons(tester);
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

    testWidgets('install failure shows the error and a Kubernetes version hint', (tester) async {
      final helm = FakeAddonHelmApi(releases: [for (final r in fixtureReleases()) if (r.name != 'eg') r])
        ..installError = 'chart requires kubeVersion: >= 1.30.0-0 which is incompatible with Kubernetes v1.25.2';
      await pumpAddons(tester, helm: helm, api: AddonsApiClient(deployments: [for (final d in fixtureDeployments()) if (d['metadata']['namespace'] != 'envoy-gateway-system') d]));
      await tester.tap(inCard(AddonIds.envoyGateway, find.text('Install…')));
      await settle(tester);
      await tester.tap(find.text('Install…').last);
      await settle(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Install'));
      await settle(tester);
      expect(find.textContaining('incompatible with Kubernetes'), findsOneWidget);
      expect(find.textContaining('This cluster runs Kubernetes v1.25.2.'), findsOneWidget);
      expect(find.textContaining('k8sman pins v1.2.8'), findsOneWidget);
      expect(find.text('Try again'), findsOneWidget);
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

    testWidgets('upgrade fetches the newer chart with wait', (tester) async {
      final (_, helm) = await pumpAddons(tester);
      await tester.tap(inCard(AddonIds.metricsServer, find.text('Upgrade…')));
      await settle(tester);
      expect(find.text('Upgrade metrics-server'), findsOneWidget);
      await tester.tap(find.text('Upgrade…').last);
      await settle(tester);
      expect(find.text('Upgrade metrics-server to metrics-server 3.15.0?'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Upgrade'));
      await settle(tester);
      expect(helm.calls.last, 'upgrade kube-system/metrics-server metrics-server@3.15.0 dryRun=false wait=true');
    });

    testWidgets('read-only: status only, no mutations', (tester) async {
      await pumpAddons(tester, readOnly: true);
      expect(find.textContaining('Read-only mode'), findsOneWidget);
      expect(find.text('Install…'), findsNothing);
      expect(find.text('Uninstall…'), findsNothing);
      expect(find.text('View release'), findsWidgets);
    });

    testWidgets('requestAddon opens the install dialog', (tester) async {
      await pumpAddons(tester,
          body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => requestAddon(c, AddonIds.certManager), child: const Text('Install cert-manager…')))));
      await tester.tap(find.text('Install cert-manager…'));
      await settle(tester);
      expect(find.text('Install cert-manager'), findsOneWidget);
      expect(find.text('Dry run'), findsOneWidget);
    });

    testWidgets('requestAddon in read-only mode explains why', (tester) async {
      await pumpAddons(tester,
          readOnly: true, body: Builder(builder: (c) => Center(child: TextButton(onPressed: () => requestAddon(c, AddonIds.trivyOperator), child: const Text('go')))));
      await tester.tap(find.text('go'));
      await settle(tester);
      expect(find.textContaining('read-only mode'), findsOneWidget);
      expect(find.text('Dry run'), findsNothing);
    });

    testWidgets('no overflow from 360 to 1800px', (tester) async {
      for (final w in <double>[360, 480, 640, 800, 1000, 1200, 1500, 1800]) {
        await pumpAddons(tester, size: Size(w, 900));
        expect(tester.takeException(), isNull, reason: 'page at $w');
        await tester.scrollUntilVisible(inCard(AddonIds.certManager, find.text('Install…')), 300, scrollable: find.byType(Scrollable).first);
        await tester.ensureVisible(inCard(AddonIds.certManager, find.text('Install…')));
        await settle(tester);
        await tester.tap(inCard(AddonIds.certManager, find.text('Install…')));
        await settle(tester);
        await tester.tap(find.text('Dry run'));
        await settle(tester);
        expect(tester.takeException(), isNull, reason: 'dialog at $w');
        await tester.pumpWidget(const SizedBox());
      }
    });
  });

  testWidgets('screenshots', (tester) async {
    await loadRealFonts();
    await pumpAddons(tester, size: const Size(1200, 860));
    await saveScreenshot(tester, 'addons_page');
    await tester.tap(inCard(AddonIds.certManager, find.text('Install…')));
    await settle(tester);
    await tester.tap(find.text('Dry run'));
    await settle(tester);
    await saveScreenshot(tester, 'addons_install_dialog');
    await tester.tap(find.text('Install…').last);
    await settle(tester);
    await saveScreenshot(tester, 'addons_install_confirm');
    await tester.pumpWidget(const SizedBox());
    await pumpAddons(tester, size: const Size(420, 900));
    await saveScreenshot(tester, 'addons_page_narrow');
    await tester.pumpWidget(const SizedBox());
    final deps = fixtureDeployments();
    deps.firstWhere((d) => d['metadata']['name'] == 'trivy-operator')['status'] = {'replicas': 1, 'unavailableReplicas': 1};
    await pumpAddons(tester, size: const Size(1200, 860), api: AddonsApiClient(deployments: deps));
    await saveScreenshot(tester, 'addons_page_unhealthy');
  });
}
