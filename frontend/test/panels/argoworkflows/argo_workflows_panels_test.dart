import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/argoworkflows/cron_panel.dart';
import 'package:k8sman/panels/argoworkflows/wf_actions.dart';
import 'package:k8sman/panels/argoworkflows/wf_common.dart';
import 'package:k8sman/panels/batch/batch_common.dart' show batchNow;
import 'package:k8sman/panels/registry.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';
import 'wf_support.dart';

// Fixtures: the dev kind cluster running dev/argo-workflows/samples.yaml on
// Argo Workflows v4.0.1. wf-build-failed: the build-and-test DAG whose
// unit-tests step failed all 3 attempts (retryStrategy), so deploy/notify
// were omitted. wf-approval-suspended: a steps workflow waiting at a suspend
// step, also suspended via spec.suspend.

/// The failed run's pods (the retry's last attempt is the one with logs).
Json pod(String name, String nodeId) => {
      'apiVersion': 'v1',
      'kind': 'Pod',
      'metadata': {
        'name': name,
        'namespace': 'argo-demo',
        'labels': {labelWorkflow: 'build-and-test-v9vnz'},
        'annotations': {annotationNodeId: nodeId},
      },
      'spec': {
        'containers': [
          {'name': 'wait'},
          {'name': 'main'},
        ],
      },
      'status': {'phase': 'Failed'},
    };

void main() {
  testWidgets('failed workflow: summary, failed step, graph, node details and logs', (tester) async {
    await loadRealFonts();
    final wf = wfFixture('wf-build-failed.json');
    final api = FakeApiClient(
      itemsByResource: {
        'pods': [pod('build-and-test-v9vnz-tests-1351651175', 'build-and-test-v9vnz-1351651175')],
      },
      itemsFilter: (r, item, ls, fs) => r.resource != 'pods' || ls == '$labelWorkflow=build-and-test-v9vnz',
    );
    await pumpWf(tester, wf, api: api, size: const Size(560, 2600));
    await saveScreenshot(tester, 'argowf-workflow-failed');

    expect(find.text('Failed'), findsWidgets);
    expect(find.text('1 failed step'), findsOneWidget);
    expect(find.textContaining('main: Error (exit code 3)'), findsWidgets);
    expect(find.text('WorkflowTemplate build-and-test'), findsOneWidget);
    // Retry attempts are folded into one graph node with a count.
    expect(find.text('×3'), findsOneWidget);
    expect(find.text('unit-tests(0)'), findsNothing);

    // Clicking the failed step in the summary selects it in the graph.
    await tester.tap(find.text('unit-tests').first);
    await tester.pumpAndSettle();
    expect(find.text('Attempts'), findsOneWidget);
    expect(find.text('Exit code'), findsOneWidget);
    expect(find.text('Input parameters'), findsOneWidget);
    await saveScreenshot(tester, 'argowf-workflow-node');

    // Logs: finds the last attempt's pod by its node-id annotation and opens
    // the main container in the dock.
    final logs = find.widgetWithText(OutlinedButton, 'Logs');
    await tester.ensureVisible(logs);
    await tester.tap(logs);
    await tester.pumpAndSettle();
    final dock = Provider.of<LogDock>(tester.element(find.byType(ListView).first), listen: false);
    expect(dock.tabs.whereType<LogStream>().map((t) => '${t.pod}/${t.container}'), ['build-and-test-v9vnz-tests-1351651175/main']);
    dock.closeAll();
    await tester.pumpAndSettle();
  });

  testWidgets('suspended workflow: waiting step callout with Resume, hidden when read-only', (tester) async {
    final wf = wfFixture('wf-approval-suspended.json');
    await pumpWf(tester, wf);
    expect(find.text('Suspended'), findsWidgets);
    expect(find.text('Waiting at approve'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Resume'), findsOneWidget);

    await pumpWf(tester, wf, readOnly: true);
    expect(find.text('Waiting at approve'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, 'Resume'), findsNothing);
  });

  test('workflow actions follow the phase and argo-server availability', () {
    final app = AppState(FakeApiClient())..currentContext = 'kind-k8sman-dev';
    PanelContext ctx(Json o) => PanelContext(object: o, type: workflowType, api: app.api, app: app);
    ArgoWFApi.debugOverride = null;
    final running = workflowActions(ctx(wfFixture('wf-approval-suspended.json'))).map((a) => a.id).toList();
    expect(running, containsAll(['logs', 'argowf-resume', 'argowf-stop', 'argowf-terminate']));
    expect(running, isNot(contains('argowf-retry')));
    final failed = workflowActions(ctx(wfFixture('wf-build-failed.json'))).map((a) => a.id).toList();
    expect(failed, containsAll(['argowf-retry', 'argowf-resubmit']));
    expect(failed, isNot(contains('argowf-stop')));
  });

  testWidgets('cron workflow: schedules, next runs in its time zone, history', (tester) async {
    await loadRealFonts();
    batchNow = () => DateTime.utc(2026, 7, 1, 10, 7);
    addTearDown(() => batchNow = DateTime.now);
    final cron = wfFixture('cron-nightly-report.json');
    final history = [for (final w in wfFixture('cron-history.json')['items'] as List) Map<String, dynamic>.from(w as Map)];
    final api = FakeApiClient(
      itemsByResource: {'workflows.argoproj.io': history},
      itemsFilter: (r, item, ls, fs) => ls == '$labelCronWorkflow=nightly-report',
    );
    await pumpWf(tester, cron, api: api, size: const Size(560, 1800));
    await saveScreenshot(tester, 'argowf-cron');
    expect(find.text('Every 15 minutes'), findsOneWidget);
    expect(find.textContaining('Europe/London (BST'), findsOneWidget);
    // 10:07 UTC = 11:07 BST; next */15 is 11:15 BST.
    expect(find.text('Wed 01 Jul 11:15 BST'), findsOneWidget);
    expect(find.text('Thu 02 Jul 02:30 BST'), findsOneWidget);
    expect(find.textContaining('Forbid', findRichText: true), findsOneWidget);
    expect(find.byType(WorkflowRow), findsNWidgets(history.length));
  });

  testWidgets('template: parameters, templates, submit dialog prefilled from defaults and enums', (tester) async {
    await loadRealFonts();
    final tmpl = wfFixture('wftmpl-build-and-test.json');
    await pumpWf(tester, tmpl, size: const Size(560, 1800));
    await saveScreenshot(tester, 'argowf-template');
    expect(find.text('fail-tests'), findsOneWidget);
    expect(find.text('Where to deploy'), findsOneWidget);
    expect(find.text('pipeline'), findsWidgets);
    expect(find.text('entrypoint'), findsOneWidget);

    SubmitRequest? got;
    tester.view.physicalSize = const Size(900, 900);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () async => got = await showDialog<SubmitRequest>(
                context: context,
                builder: (_) => SubmitTemplateDialog(template: tmpl, cluster: false, defaultNamespace: 'argo-demo'),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await saveScreenshot(tester, 'argowf-submit-dialog');
    // Enum params are menus showing their default; free text is prefilled.
    expect(find.text('staging'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'hello'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'hello'), 'hi there');
    await tester.tap(find.text('Next'));
    await tester.pumpAndSettle();
    expect(got?.body(), {
      'parameters': [
        {'name': 'target', 'value': 'staging'},
        {'name': 'fail-tests', 'value': 'false'},
        {'name': 'message', 'value': 'hi there'},
      ],
    });
  });

  test('panels are registered for all four kinds', () {
    for (final t in [workflowType, cronWorkflowType, workflowTemplateType, clusterWorkflowTemplateType]) {
      expect(panelFor(t).kinds, contains(t.gk));
    }
    expect(panelFor(cronWorkflowType), isA<CronWorkflowPanel>());
  });
}
