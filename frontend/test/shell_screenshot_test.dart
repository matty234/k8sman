import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/state/app_state.dart';

import 'support/fixture_api.dart';
import 'support/screenshot.dart';

void main() {
  testWidgets('shell screenshot', (tester) async {
    await loadRealFonts();
    final api = FixtureApi();
    final (app, dock) = await pumpShell(tester, api);
    await tester.tap(find.textContaining('web-').first);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    final path = await saveScreenshot(tester, 'shell');
    // ignore: avoid_print
    print('screenshot: $path');

    // Dock open (from the inspector's Logs action) + inspector open.
    await tester.tap(find.byKey(const ValueKey('action-logs')));
    await settleLogs(tester);
    await saveScreenshot(tester, 'shell-dock');

    // Three tabs: a second web replica and the crashy pod's previous instance.
    dock.open(FixtureApi.objectFor('pods', 'web-6fd47b8fcb-z7wpf'), container: 'log-sidecar', focus: false);
    dock.open(FixtureApi.objectFor('pods', 'crashy'), focus: false);
    await settleLogs(tester);
    await tester.enterText(find.widgetWithText(TextField, 'Search'), 'upstream');
    await settleLogs(tester);
    await saveScreenshot(tester, 'shell-dock-3-tabs');

    // Narrowest window: the main column is ~350px beside the inspector.
    tester.view.physicalSize = const Size(900, 760);
    await tester.pump();
    await saveScreenshot(tester, 'shell-dock-narrow');
    tester.view.physicalSize = const Size(1600, 1000);
    await tester.pump();

    // Switch kind: the inspector collapses to a tab, the dock stays.
    await tester.tap(find.byKey(const ValueKey('nav-kind-apps/Deployment')));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    expect(app.inspectorCollapsed, isTrue);
    await saveScreenshot(tester, 'shell-inspector-collapsed');

    // Header actions for a kind whose only action is Delete.
    app.openDetail(DetailTarget(type: app.typeFor('', 'Secret')!, name: 'web-secret', namespace: 'demo'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await saveScreenshot(tester, 'shell-secret-header');
    dock.closeAll();
    expect(tester.takeException(), isNull);
  });
}
