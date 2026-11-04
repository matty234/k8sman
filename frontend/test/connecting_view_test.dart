import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/main.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:provider/provider.dart';

import 'support/fixture_api.dart';
import 'support/screenshot.dart';

/// Contexts: `prod` works; `dead` never answers the reachability probe;
/// `sso` reaches the server, then waits on its exec plugin (kubelogin) and
/// then on discovery, both released by the test; `refused` fails fast.
class _ConnectApi extends FixtureApi {
  String current;
  final switches = <String>[];
  final auth = Completer<void>();
  final ssoTypes = Completer<List<ResourceType>>();
  _ConnectApi(this.current);

  @override
  Future<({String current, List<ContextInfo> contexts})> contexts() async => (
        current: current,
        contexts: const [
          ContextInfo(name: 'dead', cluster: 'dead', user: 'u', server: 'https://10.255.255.1:6443'),
          ContextInfo(name: 'prod', cluster: 'prod', user: 'u', server: 'https://prod.example:6443'),
          ContextInfo(name: 'refused', cluster: 'refused', user: 'u', server: 'https://127.0.0.1:1'),
          ContextInfo(name: 'sso', cluster: 'sso', user: 'oidc', server: 'https://sso.example:6443', auth: 'kubelogin'),
        ],
      );

  @override
  Future<void> switchContext(String name) async {
    switches.add(name);
    current = name;
  }

  @override
  Future<void> probe(String step, {Future<void>? abortTrigger}) async {
    switch ((current, step)) {
      case ('dead', 'reach'):
        // Hangs until the UI aborts it (Cancel).
        await abortTrigger;
        throw Exception('aborted');
      case ('refused', 'reach'):
        throw ApiException(502, "can't reach the API server at https://127.0.0.1:1: dial tcp 127.0.0.1:1: connect: connection refused",
            reason: 'Unreachable');
      case ('sso', 'auth'):
        // Deliberately ignores the abort: a late answer must be dropped.
        await auth.future;
    }
  }

  @override
  Future<List<ResourceType>> resources({bool refresh = false}) =>
      current == 'sso' ? ssoTypes.future : Future.value(FixtureApi.types);
}

Future<AppState> _pump(WidgetTester tester, _ConnectApi api, {bool awaitInit = true}) async {
  tester.view.physicalSize = const Size(1200, 760);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final app = AppState(api);
  if (awaitInit) {
    await app.init();
  } else {
    unawaited(app.init());
  }
  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<LogDock>.value(value: LogDock(api)),
    ],
    child: const K8sManApp(themeMode: ThemeMode.light),
  ));
  await tester.pump(const Duration(milliseconds: 50));
  return app;
}

/// Unmount the app so its periodic timers stop before the test ends.
Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump(const Duration(seconds: 1));
}

void main() {
  testWidgets('unreachable cluster: connecting screen explains, Cancel restores the previous context', (tester) async {
    await loadRealFonts();
    final api = _ConnectApi('prod');
    final app = await _pump(tester, api);
    app.setNamespace('demo');
    final types = app.types;
    final selected = app.selectedType;
    expect(find.byKey(const ValueKey('connecting-view')), findsNothing);

    unawaited(app.switchContext('dead'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.byKey(const ValueKey('connecting-view')), findsOneWidget);
    expect(find.text('https://10.255.255.1:6443'), findsOneWidget);
    expect(find.text('Reaching the API server'), findsOneWidget);
    expect(find.text('Cancel goes back to prod.'), findsOneWidget);
    expect(find.byKey(const ValueKey('connecting-explanation-reaching')), findsNothing);
    await tester.pump(const Duration(seconds: 1));
    await saveScreenshot(tester, 'connecting-early');

    await tester.pump(const Duration(seconds: 4));
    expect(find.byKey(const ValueKey('connecting-explanation-reaching')), findsOneWidget);
    expect(find.textContaining('VPN'), findsOneWidget);
    expect(find.text('5s'), findsOneWidget);
    await saveScreenshot(tester, 'connecting-explained');

    await tester.tap(find.byKey(const ValueKey('connecting-cancel')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('connecting-view')), findsNothing);
    expect(api.switches, ['dead', 'prod']);
    expect(app.currentContext, 'prod');
    expect(app.types, same(types));
    expect(app.selectedType, selected);
    expect(app.namespace, 'demo');
    expect(app.loading, isFalse);
    expect(app.error, isNull);
    await _unmount(tester);
  });

  testWidgets('exec plugin login: says to check the browser; results after Cancel are ignored', (tester) async {
    await loadRealFonts();
    final api = _ConnectApi('prod');
    final app = await _pump(tester, api);
    final types = app.types;

    unawaited(app.switchContext('sso'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(app.connecting?.step, ConnectStep.signingIn);
    expect(find.text('Signing in via kubelogin'), findsOneWidget);
    expect(find.text('· via kubelogin'), findsOneWidget);
    expect(find.byKey(const ValueKey('connecting-explanation-signingIn')), findsOneWidget);
    expect(find.textContaining('Check your browser'), findsOneWidget);
    await saveScreenshot(tester, 'connecting-sso');

    await tester.tap(find.byKey(const ValueKey('connecting-cancel')));
    await tester.pump();
    expect(app.currentContext, 'prod');

    // The login finishes and discovery answers after the user gave up.
    api.auth.complete();
    api.ssoTypes.complete(const [ResourceType(group: '', version: 'v1', resource: 'pods', kind: 'Pod', namespaced: true)]);
    await tester.pump(const Duration(milliseconds: 50));
    expect(app.currentContext, 'prod');
    expect(app.types, same(types));
    expect(app.loading, isFalse);
    expect(app.connecting, isNull);
    expect(find.byKey(const ValueKey('connecting-view')), findsNothing);
    await _unmount(tester);
  });

  testWidgets('refused: error screen says why and offers Back to the previous context', (tester) async {
    await loadRealFonts();
    final api = _ConnectApi('prod');
    final app = await _pump(tester, api);

    await app.switchContext('refused');
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('cluster-error-unreachable')), findsOneWidget);
    expect(find.text("Can't reach the cluster API at https://127.0.0.1:1"), findsOneWidget);
    expect(find.text('Back to prod'), findsOneWidget);
    await saveScreenshot(tester, 'connecting-unreachable');

    await tester.tap(find.byKey(const ValueKey('cluster-error-back')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(app.currentContext, 'prod');
    expect(app.error, isNull);
    expect(find.byKey(const ValueKey('cluster-error-unreachable')), findsNothing);
    await _unmount(tester);
  });

  testWidgets('first launch on a dead context: Cancel shows the pickers', (tester) async {
    final api = _ConnectApi('dead');
    final app = await _pump(tester, api, awaitInit: false);
    expect(find.byKey(const ValueKey('connecting-view')), findsOneWidget);
    expect(find.textContaining('Cancel goes back'), findsNothing);

    await tester.tap(find.byKey(const ValueKey('connecting-cancel')));
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const ValueKey('cluster-error-cancelled')), findsOneWidget);
    expect(find.text('Stopped connecting to dead'), findsOneWidget);
    expect(find.byKey(const ValueKey('switch-context')), findsOneWidget);
    expect(app.loading, isFalse);
    await _unmount(tester);
  });
}
