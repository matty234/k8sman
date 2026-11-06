import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/main.dart';
import 'package:k8sman/modules/helm_module.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:k8sman/ui/helm/helm_api.dart';
import 'package:k8sman/ui/helm/helm_view.dart';
import 'package:provider/provider.dart';

import '../support/fixture_api.dart';
import '../support/screenshot.dart';
import 'fake_helm_api.dart';

/// The Helm page inside the real app shell, across window widths, with the
/// inspector open and closed.
void main() {
  testWidgets('no overflow from 700 to 1800 wide, inspector open or closed', (tester) async {
    await loadRealFonts();
    final api = FixtureApi();
    final app = AppState(api);
    await app.init();
    app.namespace = null;
    final dock = LogDock(api);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.view.physicalSize = const Size(1300, 860);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        Provider<HelmApi>.value(value: FakeHelmApi()),
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<LogDock>.value(value: dock),
      ],
      child: const K8sManApp(themeMode: ThemeMode.dark),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    // Helm is under the nav's "More" disclosure.
    if (find.text('More').evaluate().isNotEmpty) {
      await tester.tap(find.text('More'));
      await tester.pump();
    }
    await tester.tap(find.text('Helm').first); // the nav item
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(milliseconds: 60));
    }
    expect(app.view, HelmModule.page);
    expect(find.byType(HelmView), findsOneWidget);

    final pod = DetailTarget(type: app.typeFor('', 'Pod')!, name: 'web-6fd47b8fcb-4v4m9', namespace: 'demo');
    for (var w = 700.0; w <= 1800; w += 50) {
      for (final inspector in [false, true]) {
        tester.view.physicalSize = Size(w, 860);
        inspector ? app.openDetail(pod) : app.closeDetail();
        for (var i = 0; i < 3; i++) {
          await tester.pump(const Duration(milliseconds: 60));
        }
        expect(tester.takeException(), isNull, reason: 'overflow at $w, inspector ${inspector ? 'open' : 'closed'}');
        if (w == 1600 && inspector) await saveScreenshot(tester, 'helm-shell-1600-inspector');
        if (w == 1300 && !inspector) await saveScreenshot(tester, 'helm-shell-1300');
      }
    }
    await tester.pumpWidget(const SizedBox());
  });
}
