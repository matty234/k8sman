import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/settings/settings_page.dart';

import 'support/fixture_api.dart';
import 'support/screenshot.dart';

/// The fixture context's kubeconfig namespace is `demo`; settings.json
/// stand-ins for the allowlist and the default namespace.
class _Api extends FixtureApi {
  List<String> allowed = [];

  @override
  Future<List<String>> getAllowedNamespaces({String? context}) async => allowed;

  @override
  Future<void> putAllowedNamespaces(List<String> namespaces, {String? context}) async => allowed = [...namespaces];

  @override
  Future<({String mode, List<String> namespaces})> getDefaultNamespace({String? context}) async => (mode: 'all', namespaces: const <String>[]);

  @override
  Future<({List<String> namespaces, String? defaultNamespace, bool listed})> namespaces() async =>
      allowed.isEmpty ? super.namespaces() : (namespaces: [...allowed]..sort(), defaultNamespace: 'demo', listed: true);
}

void main() {
  testWidgets('a fresh launch opens in all namespaces; an allowlist limits the picker and labels All', (tester) async {
    await loadRealFonts();
    final api = _Api();
    final (app, _) = await pumpShell(tester, api, size: const Size(1300, 850));
    // Not the kubeconfig's `demo`: all namespaces is the default now.
    expect(app.namespaceScope.isAll, isTrue);
    expect(find.text('All namespaces'), findsWidgets);

    await app.setAllowedNamespaces(['team-a', 'demo']);
    await tester.pump();
    expect(app.namespaces, ['demo', 'team-a']);
    expect(app.namespaceScope.isAll, isTrue);
    await tester.tap(find.text('All allowed namespaces (2)').first);
    await tester.pump();
    // All, then just the two allowed namespaces.
    expect(find.byKey(const ValueKey('picker-option-2')), findsOneWidget);
    expect(find.byKey(const ValueKey('picker-option-3')), findsNothing);
    await tester.tapAt(const Offset(5, 845));
    await tester.pump();

    showSettings(app, section: SettingsSection.clusters);
    await tester.pump();
    await tester.ensureVisible(find.byKey(const ValueKey('settings-allowed-namespaces')));
    await tester.pump();
    expect(find.byKey(const ValueKey('allowed-namespace-team-a')), findsOneWidget);
    await saveScreenshot(tester, 'namespace-settings');
  });
}
