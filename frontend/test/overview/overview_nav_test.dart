import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/overview/overview_api.dart';
import 'package:k8sman/ui/overview/overview_nav.dart';

import '../support/harness.dart';
import 'overview_test.dart' show pumpOverview, scenarioFixture;

void main() {
  testWidgets('area cards: title, single row, multi row and count', (tester) async {
    final (app, _) = await pumpOverview(tester, scenarioFixture(), size: const Size(1500, 1400));
    app.showView(MainView.overview);

    // The title opens the kind's table, and Back returns to the Overview.
    await tester.tap(find.byKey(const ValueKey('area-title-pods')));
    expect(app.view, MainView.resources);
    expect(app.selectedType?.kind, 'Pod');
    app.navBack();
    expect(app.view, MainView.overview);

    // A row naming one object opens it in the inspector.
    await tester.tap(find.byKey(const ValueKey('area-row-imagePull')));
    expect(app.detail?.type.kind, 'Pod');
    expect(app.detail?.name, 'img-1');

    // A row covering several opens the table, filtered like typed text.
    await tester.tap(find.byKey(const ValueKey('area-row-crashLoop')));
    expect(app.selectedType?.kind, 'Pod');
    expect(app.tablePrefs.of(testType('', 'Pod').gk).filter, 'status=CrashLoopBackOff');

    // The count filters the Issues list instead.
    await tester.tap(find.byKey(const ValueKey('area-count-stuckTerminating')));
    await tester.pump();
    expect(find.text('legacy-abc'), findsOneWidget);
    expect(find.text('img-1'), findsNothing);

    // The mapping.
    final data = OverviewData.fromJson(scenarioFixture());
    OverviewTarget? row(String id) => rowTarget(data, data.categories.firstWhere((c) => c.id == id));
    expect(row('jobFailed')?.filter, 'status=Failed'); // two jobs: the Jobs table
    expect(row('jobFailed')?.kind, 'Job');
    expect(row('deploymentUnavailable')?.object?.kind, 'Deployment'); // one: the object
    expect(titleTarget(data, 'nodes')?.page, MainView.nodes);
    expect(titleTarget(data, 'storage')?.kind, 'PersistentVolumeClaim');
    expect(titleTarget(data, 'hubble'), isNull);
  });
}
