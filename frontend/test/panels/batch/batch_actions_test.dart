import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/batch/batch_common.dart';
import 'package:k8sman/panels/registry.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/util/k8s.dart';
import 'package:provider/provider.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';

Json _load(String path) => jsonDecode(File(path).readAsStringSync()) as Json;
Json get cronReport => _load('../dev/fixtures/cronjob-report.json');
Json get migrateDb => _load('../dev/fixtures/job-migrate-db.json');
List<Json> get liveJobs => asMapList(_load('test/panels/batch/fixtures/jobs-demo.json')['items']);

/// Records actions and, for `trigger`, adds a new owned Job to the list.
class _ActionApi extends FakeApiClient {
  final List<String> calls = [];
  final List<Json> jobs;
  _ActionApi(this.jobs) : super(itemsByResource: {'jobs.batch': jobs});

  @override
  Future<ActionResult> runAction(ResourceRef r, {String? namespace, required String name, required String action, Json body = const {}}) async {
    calls.add('$action $name');
    if (action == 'trigger') {
      jobs.add({
        'apiVersion': 'batch/v1',
        'kind': 'Job',
        'metadata': {
          'name': 'report-manual-x7k2p',
          'namespace': 'demo',
          'uid': 'manual-uid',
          'creationTimestamp': '2026-11-03T11:45:00Z',
          'ownerReferences': [
            {'apiVersion': 'batch/v1', 'kind': 'CronJob', 'name': 'report', 'uid': 'd6808d5e-3d94-49da-8fda-130f33970e25'}
          ],
        },
        'spec': {'completions': 1},
        'status': {'active': 1, 'startTime': '2026-11-03T11:45:00Z'},
      });
      return ActionResult(message: 'Created job report-manual-x7k2p', created: ObjectRef(group: 'batch', kind: 'Job', name: 'report-manual-x7k2p', namespace: namespace));
    }
    return ActionResult(message: '$action ok');
  }
}

/// Like [pumpPanel] but lets the test set `readOnly`.
Future<AppState> _pump(WidgetTester tester, Json object, ApiClient api, {bool readOnly = false}) async {
  final t = testType('batch', '${object['kind']}');
  final app = AppState(api)
    ..types = testTypes
    ..readOnly = readOnly
    ..currentContext = 'kind-k8sman-dev';
  app.openDetail(DetailTarget(type: t, name: '${object['metadata']['name']}', namespace: object['metadata']['namespace']));
  tester.view.physicalSize = const Size(560, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: Builder(builder: (context) {
          final ctx = PanelContext(object: object, type: t, api: api, app: app);
          return ListView(padding: const EdgeInsets.all(12), children: panelFor(t).buildSections(context, ctx));
        }),
      ),
    ),
  ));
  await tester.pumpAndSettle();
  return app;
}

Json suspendedCron() {
  final cj = cronReport;
  cj['spec']['suspend'] = true;
  return cj;
}

/// The action button shows a spinner while its dialog is open, so the tree
/// never settles; pump enough frames for the dialog animation.
Future<void> _openDialog(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  setUp(() => batchNow = () => DateTime.utc(2026, 11, 3, 11, 33));
  tearDown(() => batchNow = DateTime.now);

  group('CronJob controls', () {
    testWidgets('suspended: Resume in the callout and Run now beside next runs', (tester) async {
      await loadRealFonts();
      final api = _ActionApi([...liveJobs]);
      await _pump(tester, suspendedCron(), api);
      expect(find.widgetWithText(OutlinedButton, 'Resume'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Run now'), findsOneWidget);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Resume'));
      await _openDialog(tester);
      expect(find.text('Resume CronJob report?'), findsOneWidget);
      expect(find.text('kind-k8sman-dev'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Resume CronJob report?'), findsNothing);
      expect(api.calls, isEmpty);
    });

    testWidgets('Run now confirmed: triggers, offers to open the Job, refreshes history', (tester) async {
      final api = _ActionApi([...liveJobs]);
      final app = await _pump(tester, cronReport, api);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Run now'));
      await _openDialog(tester);
      await tester.tap(find.widgetWithText(FilledButton, 'Run now'));
      await tester.pumpAndSettle();
      expect(api.calls, ['trigger report']);
      expect(find.text('Created job report-manual-x7k2p'), findsOneWidget);
      // History refetched and shows the new job (newest first).
      expect(find.text('report-manual-x7k2p'), findsOneWidget);
      expect(tester.getTopLeft(find.text('report-manual-x7k2p')).dy, lessThan(tester.getTopLeft(find.text('report-29895100')).dy));
      await tester.tap(find.text('Open'));
      await tester.pump();
      expect(app.detail?.name, 'report-manual-x7k2p');
      expect(app.detail?.type.kind, 'Job');
    });

    testWidgets('read-only hides controls', (tester) async {
      await _pump(tester, suspendedCron(), _ActionApi([...liveJobs]), readOnly: true);
      expect(find.text('Suspended: no new jobs will be scheduled'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Resume'), findsNothing);
      expect(find.widgetWithText(OutlinedButton, 'Run now'), findsNothing);
    });
  });

  group('Job controls', () {
    Json suspendedJob() {
      final j = migrateDb;
      j['spec']['suspend'] = true;
      j['status'] = {
        'conditions': [
          {'type': 'Suspended', 'status': 'True', 'reason': 'JobSuspended', 'message': 'Job suspended', 'lastTransitionTime': '2026-11-03T11:30:00Z'}
        ],
      };
      return j;
    }

    testWidgets('no controls on complete or read-only jobs', (tester) async {
      await _pump(tester, migrateDb, _ActionApi([]));
      expect(find.byType(OutlinedButton), findsNothing);
      await _pump(tester, suspendedJob(), _ActionApi([]), readOnly: true);
      expect(find.widgetWithText(OutlinedButton, 'Resume'), findsNothing);
    });
  });
}
