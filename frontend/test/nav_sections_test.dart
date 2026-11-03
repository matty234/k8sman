import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/resource_nav.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/harness.dart';

const lease = ResourceType(group: 'coordination.k8s.io', version: 'v1', resource: 'leases', kind: 'Lease');
const pc = ResourceType(group: 'scheduling.k8s.io', version: 'v1', resource: 'priorityclasses', kind: 'PriorityClass', namespaced: false);

Future<AppState> _pump(WidgetTester tester) async {
  final api = FakeApiClient();
  final app = AppState(api)..types = [...testTypes, lease, pc];
  tester.view.physicalSize = const Size(260, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: ResourceNav())),
  ));
  await tester.pump();
  return app;
}

void main() {
  testWidgets('a section holding the selection can still be collapsed', (tester) async {
    final app = await _pump(tester);
    expect(find.text('Lease'), findsNothing, reason: 'Other starts collapsed');

    await tester.tap(find.text('Other'));
    await tester.pump();
    await tester.tap(find.text('Lease'));
    await tester.pump();
    expect(app.selectedType, lease);

    // The user's bug: clicking the header must close it again.
    await tester.tap(find.text('Other'));
    await tester.pump();
    expect(find.text('Lease'), findsNothing);
    await tester.tap(find.text('Other'));
    await tester.pump();
    expect(find.text('Lease'), findsOneWidget);
    await tester.tap(find.text('Other')); // leave it closed for other tests
    await tester.pump();
  });

  testWidgets('expanded-by-default sections collapse even with a selection inside', (tester) async {
    final app = await _pump(tester);
    app.selectType(testType('', 'Pod'));
    await tester.pump();
    expect(find.text('Deployment'), findsOneWidget);
    await tester.tap(find.text('Workloads'));
    await tester.pump();
    expect(find.text('Deployment'), findsNothing);
    await tester.tap(find.text('Workloads'));
    await tester.pump();
    expect(find.text('Deployment'), findsOneWidget);
  });

  testWidgets('an untouched collapsed section auto-opens for a selection made elsewhere', (tester) async {
    final app = await _pump(tester);
    expect(find.text('PersistentVolume'), findsNothing);
    app.selectType(testType('', 'PersistentVolume')); // e.g. from a ResourceLink
    await tester.pump();
    expect(find.text('PersistentVolume'), findsOneWidget);
  });
}
