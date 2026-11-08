import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/palette/palette_commands.dart';
import 'package:k8sman/ui/settings/settings_page.dart';

import 'support/fixture_api.dart';

void main() {
  testWidgets('⌘, opens Settings; :settings integrations deep-links; a module toggle saves', (tester) async {
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
  });
}
