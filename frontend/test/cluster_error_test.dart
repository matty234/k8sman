import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/cluster_error.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:k8sman/ui/shell.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'support/fixture_api.dart' show FixtureApi;
import 'support/table_fakes.dart';

WatchMessage errorFrame(String message, {String? reason, int? code, String? host}) =>
    WatchMessage(type: 'ERROR', error: message, reason: reason, code: code, host: host);

const debounce = Duration(milliseconds: 1100);

void main() {
  group('ClusterError.classify', () {
    test('uses the backend reason', () {
      expect(ClusterError.classify(reason: 'Unreachable', message: 'x').kind, ClusterErrorKind.unreachable);
      expect(ClusterError.classify(reason: 'Timeout', message: 'x').kind, ClusterErrorKind.timeout);
      expect(ClusterError.classify(reason: 'Unauthorized', message: 'x').kind, ClusterErrorKind.unauthorized);
      expect(ClusterError.classify(reason: 'Forbidden', message: 'x').kind, ClusterErrorKind.forbidden);
      expect(ClusterError.classify(reason: 'NotFound', message: 'x').kind, ClusterErrorKind.notFound);
    });

    test('anonymous 403 is a credentials problem', () {
      expect(
        ClusterError.classify(reason: 'Forbidden', message: 'pods is forbidden: User "system:anonymous" cannot list').kind,
        ClusterErrorKind.unauthorized,
      );
    });

    test('transport failures mean the backend is down', () {
      expect(ClusterError.fromException(WebSocketChannelException('Connection refused')).kind, ClusterErrorKind.backendDown);
      expect(ClusterError.fromException(ApiException(502, 'dial tcp: connection refused', reason: 'Unreachable')).kind,
          ClusterErrorKind.unreachable);
    });

  });

  group('table error states', () {
    Future<TableFakeApi> pumpWithError(WidgetTester tester, WatchMessage frame, {ResourceType type = deployType}) async {
      final api = TableFakeApi()..onWatch = () => [frame];
      await pumpTable(tester, api, type);
      return api;
    }

    testWidgets('unreachable: debounced, then explained with suggestions', (tester) async {
      await pumpWithError(
        tester,
        errorFrame('Get "https://127.0.0.1:1/api": dial tcp 127.0.0.1:1: connect: connection refused', reason: 'Unreachable', code: 502, host: 'https://127.0.0.1:1'),
      );
      // No flash of an error (or "No deployments") during the first second.
      expect(find.byKey(const ValueKey('cluster-error-unreachable')), findsNothing);
      expect(find.text('No deployments'), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.pump(debounce);
      expect(find.byKey(const ValueKey('cluster-error-unreachable')), findsOneWidget);
      expect(find.text("Can't reach the cluster API at https://127.0.0.1:1"), findsOneWidget);
      expect(find.text('kubectl cluster-info'), findsOneWidget);
      expect(find.text('No deployments'), findsNothing);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Switch context…'), findsOneWidget);
      // Underlying message is collapsed until asked for.
      expect(find.textContaining('connection refused'), findsNothing);
      await tester.tap(find.byKey(const ValueKey('cluster-error-details')));
      await tester.pump();
      expect(find.textContaining('connection refused'), findsOneWidget);
    });

    testWidgets('forbidden names the resource and namespace and offers the namespace picker', (tester) async {
      await pumpWithError(tester, errorFrame('deployments.apps is forbidden: User "bob" cannot list', reason: 'Forbidden', code: 403));
      await tester.pump(debounce);
      expect(find.byKey(const ValueKey('cluster-error-forbidden')), findsOneWidget);
      expect(find.text("You don't have permission to list deployments in any namespace"), findsOneWidget);
      // Toolbar picker + one in the panel.
      expect(find.byKey(const ValueKey('namespace-picker')), findsNWidgets(2));
    });

    testWidgets('backend down: transport failure, Retry reconnects', (tester) async {
      final api = TableFakeApi()..watchError = WebSocketChannelException('SocketException: Connection refused (127.0.0.1:7443)');
      await pumpTable(tester, api, deployType);
      await tester.pump(debounce);
      expect(find.byKey(const ValueKey('cluster-error-backendDown')), findsOneWidget);
      expect(find.text("The k8sman backend isn't responding"), findsOneWidget);
      expect(find.text('Switch context…'), findsNothing, reason: 'not a cluster problem');
      final before = api.watches;
      api
        ..watchError = null
        ..onWatch = () => [WatchMessage(type: 'SNAPSHOT', table: fakeTable(deployType, [fakeRow('web')]))];
      await tester.tap(find.byKey(const ValueKey('cluster-error-retry')));
      await tester.pump();
      await tester.pump();
      expect(api.watches, greaterThan(before));
      expect(find.byKey(const ValueKey('cluster-error-backendDown')), findsNothing);
      expect(find.text('web'), findsOneWidget);
      // Let the backoff timer from the earlier failure fire harmlessly.
      await tester.pump(const Duration(seconds: 2));
    });

    testWidgets('a failed refresh after data loaded keeps rows with a banner', (tester) async {
      final api = TableFakeApi()..onWatch = () => [WatchMessage(type: 'SNAPSHOT', table: fakeTable(deployType, [fakeRow('web'), fakeRow('db')]))];
      await pumpTable(tester, api, deployType);
      expect(find.text('web'), findsOneWidget);
      api.onWatch = () => [errorFrame('dial tcp: connection refused', reason: 'Unreachable', code: 502)];
      api.watchController!.add(errorFrame('dial tcp: connection refused', reason: 'Unreachable', code: 502));
      await tester.pump();
      expect(find.byKey(const ValueKey('stale-banner')), findsNothing, reason: 'debounced');
      await tester.pump(debounce);
      expect(find.byKey(const ValueKey('stale-banner')), findsOneWidget);
      expect(find.textContaining("Can't reach the cluster. Showing the last loaded data."), findsOneWidget);
      expect(find.text('web'), findsOneWidget);
      expect(find.byKey(const ValueKey('cluster-error-unreachable')), findsNothing);
      // A fresh snapshot clears it.
      api.watchController!.add(WatchMessage(type: 'SNAPSHOT', table: fakeTable(deployType, [fakeRow('web')])));
      await tester.pump();
      expect(find.byKey(const ValueKey('stale-banner')), findsNothing);
    });
  });

  group('startup', () {
    Future<AppState> pumpFailingShell(WidgetTester tester, ApiException error) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final api = _FailingApi(error);
      final app = AppState(api);
      await app.init();
      await tester.pumpWidget(MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: api),
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<LogDock>(create: (_) => LogDock(api)),
        ],
        child: MaterialApp(theme: buildTheme(Brightness.light), home: const Shell()),
      ));
      await tester.pump();
      return app;
    }

    testWidgets('unreachable cluster at startup', (tester) async {
      await pumpFailingShell(
          tester, ApiException(502, 'Get "https://127.0.0.1:1/api?timeout=32s": dial tcp 127.0.0.1:1: connect: connection refused', reason: 'Unreachable'));
      expect(find.byKey(const ValueKey('cluster-error-unreachable')), findsOneWidget);
      expect(find.text("Can't reach the cluster API at https://127.0.0.1:1"), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      expect(find.text('Switch context…'), findsOneWidget);
      expect(find.textContaining('Kubeconfig'), findsOneWidget);
    });

  });
}

class _FailingApi extends FixtureApi {
  final ApiException error;
  _FailingApi(this.error);

  @override
  Future<List<ResourceType>> resources({bool refresh = false}) async => throw error;

  @override
  Future<({String current, List<ContextInfo> contexts, Map<String, String> readOnly})> contexts() async => (
        readOnly: const <String, String>{},
        current: 'kind-k8sman-dev',
        contexts: const [
          ContextInfo(name: 'kind-k8sman-dev', cluster: 'kind', user: 'kind'),
          ContextInfo(name: 'prod-eu', cluster: 'prod', user: 'me'),
        ],
      );
}
