import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/addons/addon_install_dialog.dart';
import 'package:k8sman/ui/editor/yaml_code_editor.dart';
import 'package:k8sman/ui/helm/helm_api.dart';
import 'package:k8sman/ui/helm/helm_page.dart';
import 'package:k8sman/ui/helm/helm_view.dart';
import 'package:k8sman/ui/helm/market/charts_view.dart';
import 'package:k8sman/ui/helm/market/market_api.dart';
import 'package:k8sman/ui/helm/yaml_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import '../support/screenshot.dart';
import 'fake_helm_api.dart';

const _defaults = 'replicaCount: 1\nimage:\n  repository: example/demo\n  tag: ""\nservice:\n  type: ClusterIP\n  port: 80\n';
const _repoURL = 'https://charts.example.com/stable';

class _Helm extends FakeHelmApi {
  @override
  Future<List<HelmChartVersion>> chartVersions(String repo, String chart) async =>
      const [HelmChartVersion(version: '0.4.0', appVersion: '1.2.0'), HelmChartVersion(version: '0.3.1', appVersion: '1.1.0')];
}

class _Market extends HelmMarketApi {
  _Market() : super(FakeApiClient());

  @override
  Future<RepoChartList> repoCharts({String? repo}) async => const RepoChartList([
        ChartSummary(source: ChartSource.repo, repo: 'example', repoURL: _repoURL, name: 'k8sman-demo', version: '0.4.0', appVersion: '1.2.0', description: 'Demo web app with an optional cache'),
        ChartSummary(source: ChartSource.repo, repo: 'example', repoURL: _repoURL, name: 'queue', version: '2.1.0', appVersion: '5.0', description: 'A message queue'),
        ChartSummary(source: ChartSource.repo, repo: 'tools', repoURL: 'https://tools.example.com', name: 'metrics-server', version: '3.15.0', description: 'Resource metrics API'),
      ]);

  @override
  Future<bool> artifactHubEnabled() async => false;

  @override
  Future<ChartDetail> repoChart(String repo, String chart, {String? version}) async => const ChartDetail(
        source: ChartSource.repo,
        repo: 'example',
        repoURL: _repoURL,
        name: 'k8sman-demo',
        version: '0.4.0',
        appVersion: '1.2.0',
        description: 'Demo web app with an optional cache',
        maintainers: [ChartMaintainer('Example maintainers', email: 'charts@example.com')],
        links: [('Home', 'https://example.com')],
        versions: [HelmChartVersion(version: '0.4.0', appVersion: '1.2.0'), HelmChartVersion(version: '0.3.1', appVersion: '1.1.0')],
      );

  @override
  Future<ChartFiles> repoChartFiles(String repo, String chart, {String? version}) async =>
      ChartFiles(version: version ?? '0.4.0', readme: '# k8sman-demo\n', values: _defaults);

  @override
  Future<Map<String, ChartUpdate>> updates(Iterable<HelmRelease> releases) async =>
      const {'k8sman-demo@0.3.1': ChartUpdate(chart: 'k8sman-demo', installed: '0.3.1', latest: '0.4.0', repo: 'example', repoURL: _repoURL)};
}

void main() {
  testWidgets('charts: browse, detail with default values, Install opens the prefilled flow; releases flag updates', (tester) async {
    await loadRealFonts();
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final client = FakeApiClient();
    final app = AppState(client)
      ..namespaces = const ['default', 'helm-demo', 'helm-tools', 'kube-system']
      ..currentContext = 'kind-k8sman-dev';
    final helm = _Helm();
    final market = _Market();
    Future<void> pump(Widget body) async {
      await tester.pumpWidget(MultiProvider(
        providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
        child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.dark), home: Scaffold(body: body)),
      ));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 60));
      }
    }

    Widget Function(bool) mode(HelmMode m) => (compact) => HelmModeSwitch(mode: m, compact: compact, onChanged: (_) {});
    await pump(HelmChartsView(api: market, helm: helm, modeSwitch: mode(HelmMode.charts)));
    expect(find.text('3 charts in your repositories'), findsOneWidget);
    await saveScreenshot(tester, 'helm-market-charts');

    await tester.tap(find.byKey(const ValueKey('chart-example-k8sman-demo')));
    await tester.pumpAndSettle();
    final editor = tester.widget<YamlCodeEditor>(find.byType(YamlCodeEditor));
    expect(editor.controller.text, _defaults);
    // web, api, cache-only and worker run 0.3.1 of this chart.
    expect(find.byKey(const ValueKey('upgrade-web')), findsOneWidget);
    await saveScreenshot(tester, 'helm-market-chart-detail');

    await tester.tap(find.byKey(const ValueKey('chart-install')));
    await tester.pumpAndSettle();
    final dialog = tester.widget<AddonInstallDialog>(find.byType(AddonInstallDialog));
    expect((dialog.addon.repo, dialog.addon.chart, dialog.addon.version), (_repoURL, 'k8sman-demo', '0.4.0'));
    expect(dialog.upgrade, isNull);
    final values = tester.widget<HelmYamlView>(find.descendant(of: find.byType(AddonInstallDialog), matching: find.byType(HelmYamlView)));
    expect(values.controller!.text, _defaults);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('addon-release'))).controller!.text, 'k8sman-demo');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    await pump(HelmView(api: helm, market: market, modeSwitch: mode(HelmMode.releases)));
    expect(find.text('0.4.0 available'), findsOneWidget); // the detail; rows say "0.4.0"
    await saveScreenshot(tester, 'helm-market-releases');
    await tester.pumpWidget(const SizedBox()); // cancels the poll timer
  });
}
