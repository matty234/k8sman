import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/ui/upgrade/upgrade_api.dart';
import 'package:k8sman/ui/upgrade/upgrade_view.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';
import '../support/screenshot.dart';

class FakeUpgradeApi extends UpgradeApi {
  final List<String?> calls = [];
  FakeUpgradeApi(super.api);

  @override
  Future<UpgradeData> fetch({String? target}) async {
    calls.add(target);
    return UpgradeData.fromJson(fixture(target ?? '1.32'));
  }
}

Json finding(String id, String check, String severity, String title,
        {String detail = '', List<Json> objects = const [], String? ns, String why = 'It gets in the way of the upgrade.', String action = 'Fix it first.'}) =>
    {
      'id': id,
      'check': check,
      'severity': severity,
      'title': title,
      'detail': detail,
      'why': why,
      'action': action,
      'namespace': ?ns,
      'objects': objects,
      'docs': 'https://kubernetes.io/docs/reference/using-api/deprecation-guide/',
    };

Json obj(String group, String kind, String name, [String? ns]) => {'group': group, 'kind': kind, 'name': name, 'namespace': ?ns};

/// A cluster on 1.31 checked against [target]: two blockers, warnings,
/// notes, and checks that came back clear.
Json fixture(String target) {
  final j = _fixture(target);
  final counts = {'blocker': 0, 'warning': 0, 'info': 0};
  for (final f in j['findings'] as List) {
    counts[(f as Json)['severity'] as String] = counts[f['severity']]! + 1;
  }
  return {...j, 'counts': counts};
}

Json _fixture(String target) => {
      'serverVersion': 'v1.31.4',
      'current': '1.31',
      'target': target,
      'targets': ['1.32', '1.33', '1.34'],
      'steps': [for (var m = 32; m <= int.parse(target.split('.').last); m++) '1.$m'],
      'nodes': 6,
      'checks': [
        {'id': 'apis', 'title': 'Removed APIs', 'state': 'findings', 'counts': {'blocker': 1}, 'clear': 'No removed APIs in use',
          'notes': ["Couldn't check the API server's deprecated-API metric: not allowed"]},
        {'id': 'skew', 'title': 'Version skew', 'state': 'findings', 'counts': {'warning': 1}, 'clear': ''},
        {'id': 'drain', 'title': 'Drain blockers', 'state': 'findings', 'counts': {'blocker': 1, 'warning': 2, 'info': 1}, 'clear': ''},
        {'id': 'webhooks', 'title': 'Admission webhooks', 'state': 'clear', 'counts': {}, 'clear': 'No webhooks that can block the rollout'},
        {'id': 'crds', 'title': 'CRD storage versions', 'state': 'clear', 'counts': {}, 'clear': 'CRD storage versions are served'},
        {'id': 'nodes', 'title': 'Node health', 'state': 'clear', 'counts': {}, 'clear': 'All nodes ready'},
        {'id': 'addons', 'title': 'Add-ons', 'state': 'findings', 'counts': {'info': 1}, 'clear': ''},
      ],
      'findings': [
        finding('apis/helm/demo/example', 'apis', 'blocker', 'Helm release example uses removed APIs',
            detail: 'example-2.1.0, revision 7: FlowSchema example (flowcontrol.apiserver.k8s.io/v1beta3)', ns: 'demo',
            why: "The release's stored manifest uses flowcontrol.apiserver.k8s.io/v1beta3, removed in 1.32. Helm compares against it, so `helm upgrade` of this release fails after the upgrade even with a fixed chart.",
            action: 'Upgrade the release to a chart version without them before upgrading the cluster. If it can no longer upgrade, rewrite the stored manifest with the helm-mapkubeapis plugin.', objects: [obj('', 'Secret', 'sh.helm.release.v1.example.v7', 'demo')]),
        if (target != '1.32')
          finding('skew/steps', 'skew', 'warning', 'The control plane upgrades one minor at a time', detail: '1.31 → 1.32 → $target'),
        finding('skew/edge/1.29', 'skew', 'warning', '2 nodes on kubelet 1.29, at the skew limit for 1.32', detail: 'demo-worker-1, demo-worker-2',
            objects: [obj('', 'Node', 'demo-worker-1'), obj('', 'Node', 'demo-worker-2')]),
        finding('drain/pdb/demo/web', 'drain', 'blocker', 'PDB web allows no evictions', detail: 'minAvailable: 2 of 2 pods', ns: 'demo',
            why: 'Node drains evict through this budget, which never allows one: draining any node running its pods hangs until the upgrade times out.',
            action: 'Add replicas, or loosen the budget (maxUnavailable: 1) for the upgrade.',
            objects: [obj('policy', 'PodDisruptionBudget', 'web', 'demo')]),
        finding('drain/single/demo', 'drain', 'warning', '3 single-replica workloads in demo', detail: 'api, cache, worker', ns: 'demo',
            objects: [obj('apps', 'Deployment', 'api', 'demo'), obj('apps', 'Deployment', 'cache', 'demo'), obj('apps', 'StatefulSet', 'worker', 'demo')]),
        finding('drain/bare/example', 'drain', 'warning', '1 pod without a controller in example', detail: 'debug-shell', ns: 'example',
            objects: [obj('', 'Pod', 'debug-shell', 'example')]),
        finding('drain/emptydir/demo', 'drain', 'info', '2 workloads with emptyDir data in demo', detail: 'api, cache', ns: 'demo',
            objects: [obj('apps', 'Deployment', 'api', 'demo'), obj('apps', 'Deployment', 'cache', 'demo')]),
        finding('addons/ingress-nginx/ingress-nginx/ingress-nginx-controller', 'addons', 'info', 'ingress-nginx v1.11.2', detail: 'Deployment ingress-nginx/ingress-nginx-controller',
            ns: 'ingress-nginx', objects: [obj('apps', 'Deployment', 'ingress-nginx-controller', 'ingress-nginx')]),
      ],
      'ignored': [],
    };

Future<(AppState, FakeUpgradeApi)> pumpUpgrade(WidgetTester tester, {Brightness brightness = Brightness.dark}) async {
  final client = FakeApiClient();
  final app = AppState(client)
    ..types = [...testTypes, const ResourceType(group: 'policy', version: 'v1', resource: 'poddisruptionbudgets', kind: 'PodDisruptionBudget')]
    ..currentContext = 'demo';
  final source = FakeUpgradeApi(client);
  tester.view.physicalSize = const Size(1200, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      key: ValueKey(brightness),
      debugShowCheckedModeBanner: false,
      theme: buildTheme(brightness),
      home: Scaffold(body: UpgradeView(source: source)),
    ),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  return (app, source);
}

void main() {
  testWidgets('blockers per check, the target picker, and a finding opening its object (screenshots)', (tester) async {
    await loadRealFonts();
    final (app, source) = await pumpUpgrade(tester);
    expect(source.calls, [null]);
    expect(find.text('Not ready for 1.32'), findsOneWidget);
    expect(find.text('v1.31.4'), findsOneWidget);
    expect(find.byKey(const ValueKey('check-drain')), findsOneWidget);
    expect(find.textContaining('No webhooks that can block the rollout'), findsOneWidget);
    expect(find.textContaining("deprecated-API metric: not allowed"), findsOneWidget);

    // Open the PDB blocker: why, what to do, and its object, which opens
    // in the inspector.
    await tester.tap(find.byKey(const ValueKey('finding-drain/pdb/demo/web')));
    await tester.pump();
    expect(find.byKey(const ValueKey('finding-detail-drain/pdb/demo/web')), findsOneWidget);
    await tester.tap(find.text('demo/web'));
    await tester.pump();
    expect(app.detail?.type.kind, 'PodDisruptionBudget');
    expect(app.detail?.name, 'web');
    await saveScreenshot(tester, 'upgrade-dark');

    // Another target: fetched for it, and the two-step path shows.
    await tester.tap(find.byKey(const ValueKey('target-1.33')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(source.calls.last, '1.33');
    expect(find.text('Not ready for 1.33'), findsOneWidget);
    expect(find.textContaining('1.31 → 1.32 → 1.33'), findsWidgets);

    // The light screenshot, with the Helm blocker open.
    await pumpUpgrade(tester, brightness: Brightness.light);
    await tester.tap(find.byKey(const ValueKey('finding-apis/helm/demo/example')));
    await tester.pump();
    await saveScreenshot(tester, 'upgrade-light');
  });
}
