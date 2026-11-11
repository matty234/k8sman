import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/plugins/plugin_host.dart' show pluginsModuleId;
import 'package:k8sman/plugins/plugin_notices.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/palette/palette_commands.dart';
import 'package:k8sman/ui/settings/settings_page.dart';

import 'support/fixture_api.dart';

void main() {
  testWidgets('⌘, opens Settings; :settings integrations deep-links; a module toggle saves; Review lands on the right Integrations sub-page', (tester) async {
    final api = FixtureApi();
    final (app, _) = await pumpShell(tester, api, size: const Size(1300, 850));

    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.comma);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(app.view, MainView.settings);
    for (final s in SettingsSection.values) {
      await tester.tap(find.byKey(ValueKey('settings-nav-${s.name}')));
      await tester.pump();
      expect(find.byKey(ValueKey('settings-section-${s.name}')), findsOneWidget, reason: s.title);
    }
    expect(tester.takeException(), isNull);

    // Esc goes back to the page Settings was opened from.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(app.view, MainView.resources);

    rankCommand('settings integrations', app).sections.first.items.first.run();
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-section-integrations')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('integration-expand-hubble')));
    await tester.tap(find.byKey(const ValueKey('integration-expand-hubble')));
    await tester.pump();
    expect(find.byKey(const ValueKey('integration-form-hubble')), findsOneWidget);

    await tester.ensureVisible(find.byKey(const ValueKey('integration-argocd')));
    await tester.tap(find.byKey(const ValueKey('integration-argocd')));
    await tester.pump();
    expect(app.disabledModules, {'argocd'});
    expect(api.disabledModules, {'argocd'});

    // Integrations' sub-pages: the suggestions notice's Review lands on
    // Marketplace (its count on the tab), the tabs switch, and the
    // updates notice's Review (the Plugins row) goes back to Installed.
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    pluginNotices.take({
      'status': 'ok',
      'context': app.currentContext,
      'suggested': [
        {'id': 'cert-manager', 'name': 'cert-manager', 'state': 'install'},
      ],
      'unseenSuggestions': true,
    });
    await tester.pump();
    await tester.tap(find.descendant(of: find.byKey(const ValueKey('plugin-notice-suggestions')), matching: find.text('Review')));
    await tester.pump();
    expect(find.byKey(const ValueKey('integrations-marketplace')), findsOneWidget);
    expect(find.byKey(const ValueKey('integrations-badge-marketplace')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('integrations-page-installed')));
    await tester.pump();
    expect(find.byKey(const ValueKey('settings-module-plugins')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('integrations-page-marketplace')));
    await tester.pump();
    showSettings(app, module: pluginsModuleId);
    await tester.pump();
    expect(find.byKey(const ValueKey('integrations-installed')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
