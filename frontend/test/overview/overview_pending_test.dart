import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/overview/overview_api.dart';
import 'package:k8sman/ui/overview/overview_view.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/ui/widgets/namespace_picker.dart';
import 'package:provider/provider.dart';

import '../support/fixture_api.dart';
import '../support/harness.dart';

class _PendingThenFullApi extends OverviewApi {
  int calls = 0;
  _PendingThenFullApi(super.api);

  @override
  Future<OverviewData> fetch({NamespaceScope scope = NamespaceScope.all}) async {
    calls++;
    final pending = calls == 1;
    return OverviewData.fromJson({
      'counts': {
        'pods': {'total': 4, 'ready': 4, 'running': 4},
        if (!pending) 'deployments': {'total': 2, 'healthy': 2},
      },
      'categories': [],
      'issues': [],
      if (pending) 'pending': ['deployments', 'nodes'],
    });
  }
}

void main() {
  testWidgets('launch opens the Overview; a pending section shows a placeholder, then fills in after the quick re-fetch', (tester) async {
    final launched = AppState(FixtureApi());
    await launched.backendConnected();
    expect(launched.view, MainView.overview);

    PageScope.reset();
    final client = FakeApiClient();
    final app = AppState(client)..types = testTypes;
    final source = _PendingThenFullApi(client);
    tester.view.physicalSize = const Size(900, 650);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(body: OverviewView(source: source))),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    // Unknown is not "all healthy": placeholders stand in.
    expect(find.byKey(const ValueKey('pending-tile-workloads')), findsOneWidget);
    expect(find.byKey(const ValueKey('pending-tile-nodes')), findsOneWidget);
    expect(find.text('All healthy'), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.pump(const Duration(milliseconds: 800)); // the 700ms re-fetch
    await tester.pump(const Duration(milliseconds: 50));
    expect(source.calls, 2);
    expect(find.byKey(const ValueKey('pending-tile-workloads')), findsNothing);
    expect(find.text('All healthy'), findsOneWidget);
    await tester.pumpWidget(const SizedBox()); // stop the poll timers
  });
}
