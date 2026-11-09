import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/overview/overview_api.dart';
import 'package:k8sman/ui/overview/overview_summary.dart';
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
    expect(find.byKey(const ValueKey('nav-kind-coordination.k8s.io/Lease')), findsNothing, reason: 'Other starts collapsed');

    await tester.tap(find.text('Other'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-kind-coordination.k8s.io/Lease')));
    await tester.pump();
    expect(app.selectedType, lease);

    // The user's bug: clicking the header must close it again.
    await tester.tap(find.text('Other'));
    await tester.pump();
    expect(find.byKey(const ValueKey('nav-kind-coordination.k8s.io/Lease')), findsNothing);
    await tester.tap(find.text('Other'));
    await tester.pump();
    expect(find.byKey(const ValueKey('nav-kind-coordination.k8s.io/Lease')), findsOneWidget);
    await tester.tap(find.text('Other')); // leave it closed for other tests
    await tester.pump();
  });

  testWidgets('expanded-by-default sections collapse even with a selection inside', (tester) async {
    final app = await _pump(tester);
    app.selectType(testType('', 'Pod'));
    await tester.pump();
    expect(find.byKey(const ValueKey('nav-kind-apps/Deployment')), findsOneWidget);
    await tester.tap(find.text('Workloads'));
    await tester.pump();
    expect(find.byKey(const ValueKey('nav-kind-apps/Deployment')), findsNothing);
    await tester.tap(find.text('Workloads'));
    await tester.pump();
    expect(find.byKey(const ValueKey('nav-kind-apps/Deployment')), findsOneWidget);
  });

  testWidgets('an untouched collapsed section auto-opens for a selection made elsewhere', (tester) async {
    final app = await _pump(tester);
    expect(find.byKey(const ValueKey('nav-kind-/PersistentVolume')), findsNothing);
    app.selectType(testType('', 'PersistentVolume')); // e.g. from a ResourceLink
    await tester.pump();
    expect(find.byKey(const ValueKey('nav-kind-/PersistentVolume')), findsOneWidget);
  });

  testWidgets('kind rows: icon, plural label, problem badge; a collapsed section shows a dot', (tester) async {
    final app = await _pump(tester);
    final pods = find.byKey(const ValueKey('nav-kind-/Pod'));
    expect(find.descendant(of: pods, matching: find.text('Pods')), findsOneWidget);
    expect(find.descendant(of: pods, matching: find.byIcon(Icons.view_in_ar_outlined)), findsOneWidget);

    OverviewSummary.of(app.api).feed(
        OverviewData.fromJson({
          'categories': [
            {'id': 'crashLoop', 'label': 'CrashLoopBackOff', 'severity': 'critical', 'count': 1},
          ],
          'issues': [
            {'severity': 'critical', 'category': 'crashLoop', 'kind': 'Pod', 'namespace': 'demo', 'name': 'crashy'},
          ],
        }),
        app.api.context);
    await tester.pump();
    expect(find.descendant(of: pods, matching: find.text('1')), findsOneWidget);

    await tester.tap(find.text('Workloads'));
    await tester.pump();
    expect(find.byKey(const ValueKey('nav-group-problem-Workloads')), findsOneWidget);
    await tester.tap(find.text('Workloads')); // leave it open for other tests
    await tester.pump();
  });
}
