import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/plugins/plugins_settings.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';

/// A plugin directory with one plugin to install and one built in.
class _DirectoryApi extends FakeApiClient {
  final installs = <String?>[];

  @override
  Future<Json> plugins() async => {'generation': 1, 'plugins': []};

  @override
  Future<Json> pluginDirectory({bool refresh = false}) async => {
        'status': 'ok',
        'plugins': [
          {
            'id': 'cert-manager',
            'name': 'cert-manager',
            'version': '1.2.0',
            'description': 'Certificates at a glance',
            'authors': ['k8sman'],
            'kinds': ['cert-manager.io/Certificate'],
            'permissions': {
              'read': ['cert-manager.io/Certificate', '/Secret'],
              'commands': ['cmctl'],
            },
            'permissionsHash': 'abc',
            'state': 'install',
          },
          {'id': 'external-secrets', 'name': 'External Secrets', 'version': '1.0.0', 'state': 'builtin'},
        ],
      };

  @override
  Future<Json> installPlugin(String id, {String? permissionsHash}) async {
    installs.add(permissionsHash);
    if (permissionsHash == null) {
      return {
        'consent': {
          'id': id,
          'name': 'cert-manager',
          'version': '1.2.0',
          'permissions': {
            'read': ['cert-manager.io/Certificate', '/Secret'],
            'commands': ['cmctl'],
          },
          'permissionsHash': 'abc',
        },
      };
    }
    return {'generation': 2, 'plugins': []};
  }
}

void main() {
  testWidgets('Browse lists the directory and Install asks for consent first', (tester) async {
    final api = _DirectoryApi();
    tester.view.physicalSize = const Size(900, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient?>.value(value: api), ChangeNotifierProvider<AppState>.value(value: AppState(api))],
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: SingleChildScrollView(child: PluginsSettings()))),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Browse'), findsOneWidget);
    expect(find.text('Certificates at a glance'), findsOneWidget);
    expect(find.text('Built in'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('plugin-install-cert-manager')));
    // The card's progress spins behind the dialog: no pumpAndSettle.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Install cert-manager?'), findsOneWidget);
    expect(find.textContaining('Secrets (names and keys only)', findRichText: true), findsOneWidget);
    expect(find.textContaining('cmctl', findRichText: true), findsOneWidget);

    await tester.tap(find.widgetWithText(FilledButton, 'Install').last);
    await tester.pumpAndSettle();
    expect(api.installs, [null, 'abc'], reason: 'asked first, then installed with the hash agreed to');
  });
}
