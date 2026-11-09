import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:k8sman/ui/logs/log_dock_view.dart';
import 'package:k8sman/ui/portforward/portforward_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

class _PfApi extends ApiClient {
  _PfApi() : super(base: Uri.parse('http://fake'));
  @override
  Future<List<PortForward>> portForwards() async => [
        PortForward.fromJson({
          'id': 'a', 'context': 'kind-k8sman-dev', 'namespace': 'demo', 'kind': 'service', 'name': 'web', 'port': '80',
          'localPort': 18080, 'state': 'active', 'pod': 'web-6fd47b8fcb-4v4m9', 'remotePort': 8080, 'url': 'http://localhost:18080',
          'autoStart': true, 'label': 'web UI', 'connections': 3, 'reconnects': 1, 'since': '2026-11-03T11:00:00Z',
        }),
        PortForward.fromJson({
          'id': 'b', 'context': 'other', 'namespace': 'demo', 'kind': 'deployment', 'name': 'a-really-long-deployment-name-here', 'port': 'http',
          'localPort': 60725, 'state': 'reconnecting', 'error': 'pod web-xyz went away', 'reconnects': 4,
        }),
      ];
}

void main() {
  testWidgets('port-forward view has no overflow when narrow, normal and wide', (tester) async {
    final api = _PfApi();
    final app = AppState(api)..currentContext = 'kind-k8sman-dev';
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    for (final w in [360.0, 900.0, 1600.0]) {
      tester.view.physicalSize = Size(w, 600);
      await tester.pumpWidget(MultiProvider(
        providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
        child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: PortForwardView())),
      ));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 10));
      expect(tester.takeException(), isNull, reason: 'overflow at width $w');
    }
    await tester.pumpWidget(const SizedBox()); // stop the poll timer
  });

  testWidgets('Forwards lives in the dock: tab with badge, docked list, pulse refreshes', (tester) async {
    final api = _PfApi();
    final app = AppState(api)..currentContext = 'kind-k8sman-dev';
    final dock = LogDock(api);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1000, 420);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [
        Provider<ApiClient>.value(value: api),
        ChangeNotifierProvider<AppState>.value(value: app),
        ChangeNotifierProvider<LogDock>.value(value: dock),
      ],
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: Column(children: [Spacer(), LogDockView(maxHeight: 380)]))),
    ));
    // The badge's first poll waits for the startup gate; a pulse polls now.
    dock.notifyForwardStarted();
    await tester.pump();
    await tester.pump();
    expect(find.descendant(of: find.byKey(const ValueKey('dock-forwards-tab')), matching: find.text('2')), findsOneWidget, reason: '2 running');

    await tester.tap(find.byKey(const ValueKey('dock-forwards-tab')));
    await tester.pump();
    await tester.pump();
    expect(dock.pane, DockPane.forwards);
    expect(find.byWidgetPredicate((w) => w is PortForwardView && w.docked), findsOneWidget);
    expect(find.text('localhost:18080'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // A pulse doesn't take the panel from a log or terminal (nor collapse it).
    dock.setCollapsed(true);
    await tester.pump();
    dock.notifyForwardStarted();
    await tester.pump(const Duration(milliseconds: 300));
    expect(dock.collapsed, isTrue);
    await tester.pump(const Duration(seconds: 2)); // the flash finishes
    await tester.pumpWidget(const SizedBox());
  });
}
