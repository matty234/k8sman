import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/batch/batch_common.dart';
import 'package:k8sman/panels/batch/cron.dart';
import 'package:k8sman/panels/batch/cronjob_panel.dart';
import 'package:k8sman/util/k8s.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';

Json _load(String path) => jsonDecode(File(path).readAsStringSync()) as Json;
List<Json> _items(String path) => asMapList(_load(path)['items']);

Json get migrateDb => _load('../dev/fixtures/job-migrate-db.json');
Json get cronReport => _load('../dev/fixtures/cronjob-report.json');
List<Json> get liveJobs => _items('test/panels/batch/fixtures/jobs-demo.json');
List<Json> get reportPods => _items('test/panels/batch/fixtures/pods-report.json');
List<Json> get migratePods => _items('test/panels/batch/fixtures/pods-migrate-db.json');

/// Honours simple `k=v[,k=v]` label selectors like the real backend.
bool _labelFilter(ResourceRef r, Json item, String? labelSelector, String? fieldSelector) {
  if (labelSelector == null || labelSelector.isEmpty) return true;
  final labels = asMap(dig(item, ['metadata', 'labels']));
  return labelSelector.split(',').every((t) {
    final kv = t.split('=');
    return labels[kv[0]] == kv[1];
  });
}

FakeApiClient _api({List<Json> pods = const [], List<Json> jobs = const []}) =>
    FakeApiClient(itemsByResource: {'pods': pods, 'jobs.batch': jobs}, itemsFilter: _labelFilter);

const _failedUid = '9f0c1a2b-0000-4000-8000-00000000f00d';

/// A Job that exhausted backoffLimit=2 after three failed attempts.
Json failedJob() => {
      'apiVersion': 'batch/v1',
      'kind': 'Job',
      'metadata': {
        'name': 'import-data',
        'namespace': 'demo',
        'uid': _failedUid,
        'creationTimestamp': '2026-11-03T10:00:00Z',
        'labels': {'batch.kubernetes.io/controller-uid': _failedUid, 'batch.kubernetes.io/job-name': 'import-data'},
      },
      'spec': {
        'backoffLimit': 2,
        'completions': 1,
        'parallelism': 1,
        'completionMode': 'NonIndexed',
        'activeDeadlineSeconds': 1800,
        'ttlSecondsAfterFinished': 7200,
        'podFailurePolicy': {
          'rules': [
            {
              'action': 'FailJob',
              'onExitCodes': {'containerName': 'import', 'operator': 'In', 'values': [42]},
            },
            {
              'action': 'Ignore',
              'onPodConditions': [
                {'type': 'DisruptionTarget'}
              ],
            },
          ],
        },
        'template': {
          'spec': {
            'restartPolicy': 'Never',
            'serviceAccountName': 'importer',
            'containers': [
              {
                'name': 'import',
                'image': 'ghcr.io/acme/importer:2.4.1',
                'command': ['python', '-m', 'importer'],
                'args': ['--source', 's3://bucket/data set.csv', '--dry-run=false', "--note=it's"],
                'resources': {
                  'requests': {'cpu': '250m', 'memory': '256Mi'},
                  'limits': {'memory': '512Mi'},
                },
                'envFrom': [
                  {
                    'secretRef': {'name': 'importer-creds'},
                  },
                ],
              },
            ],
          },
        },
      },
      'status': {
        'startTime': '2026-11-03T10:00:00Z',
        'failed': 3,
        'ready': 0,
        'terminating': 0,
        'conditions': [
          {
            'type': 'FailureTarget',
            'status': 'True',
            'reason': 'BackoffLimitExceeded',
            'message': 'Job has reached the specified backoff limit',
            'lastTransitionTime': '2026-11-03T10:01:10Z',
          },
          {
            'type': 'Failed',
            'status': 'True',
            'reason': 'BackoffLimitExceeded',
            'message': 'Job has reached the specified backoff limit',
            'lastTransitionTime': '2026-11-03T10:01:10Z',
          },
        ],
      },
    };

Json failedPod(int n, String created, int exitCode, String reason, {String? message}) => {
      'apiVersion': 'v1',
      'kind': 'Pod',
      'metadata': {
        'name': 'import-data-$n${'abcde'[n]}x9',
        'namespace': 'demo',
        'creationTimestamp': created,
        'labels': {'batch.kubernetes.io/controller-uid': _failedUid, 'job-name': 'import-data'},
      },
      'spec': {'nodeName': 'k8sman-dev-control-plane'},
      'status': {
        'phase': 'Failed',
        'startTime': created,
        'containerStatuses': [
          {
            'name': 'import',
            'restartCount': 0,
            'state': {
              'terminated': {
                'exitCode': exitCode,
                'reason': reason,
                'startedAt': created,
                'finishedAt': DateTime.parse(created).add(const Duration(seconds: 7)).toIso8601String(),
                'message': ?message,
              },
            },
          },
        ],
      },
    };

List<Json> failedPods() => [
      failedPod(1, '2026-11-03T10:00:00Z', 1, 'Error', message: 'psycopg2.OperationalError: connection refused'),
      failedPod(2, '2026-11-03T10:00:20Z', 1, 'Error'),
      failedPod(3, '2026-11-03T10:00:50Z', 137, 'OOMKilled'),
    ];

void main() {
  setUp(() => batchNow = () => DateTime.utc(2026, 11, 3, 11, 33));
  tearDown(() => batchNow = DateTime.now);

  group('pure helpers', () {
    test('deriveJobState', () {
      expect(deriveJobState(migrateDb).label, 'Complete');
      final f = deriveJobState(failedJob());
      expect((f.label, f.reason, f.severity), ('Failed', 'BackoffLimitExceeded', Severity.error));
      expect(f.finishedAt, DateTime.utc(2026, 11, 3, 10, 1, 10));
      expect(deriveJobState({'spec': {'suspend': true}}).label, 'Suspended');
      expect(deriveJobState({'status': {'active': 2}}).label, 'Running');
      expect(deriveJobState({'status': {}}).label, 'Pending');
      expect(
          deriveJobState({
            'status': {
              'active': 1,
              'conditions': [
                {'type': 'FailureTarget', 'status': 'True', 'reason': 'DeadlineExceeded'}
              ]
            }
          }).label,
          'Failing');
    });

    test('jobDuration and completions', () {
      expect(jobDuration(migrateDb), const Duration(seconds: 11));
      expect(jobDuration(failedJob()), const Duration(seconds: 70));
      expect(jobDuration({'status': {'startTime': '2026-11-03T11:30:00Z', 'active': 1}}), const Duration(minutes: 3));
      expect(jobCompletions(migrateDb), '1/1');
      expect(jobCompletions({'status': {'succeeded': 4}}), '4');
    });

    test('shellJoin quotes only when needed', () {
      expect(shellJoin(['sh', '-c', 'echo hi; sleep 3']), "sh -c 'echo hi; sleep 3'");
      expect(shellJoin(['--note=it\'s', '', 'a/b.c']), "'--note=it'\\''s' '' a/b.c");
    });

    test('podFailurePolicySummary', () {
      expect(podFailurePolicySummary(failedJob()['spec']['podFailurePolicy']),
          ['FailJob when exit code in [42] (container import)', 'Ignore on pod condition DisruptionTarget']);
      expect(podFailurePolicySummary(null), isEmpty);
    });

    test('formatRelative', () {
      final now = DateTime.utc(2026, 11, 3, 11, 33);
      expect(formatRelative(DateTime.utc(2026, 11, 3, 11, 35), now: now), 'in 2m');
      expect(formatRelative(DateTime.utc(2026, 11, 3, 11, 32, 30), now: now), '30s ago');
      expect(formatRelative(DateTime.utc(2026, 11, 3, 13, 3), now: now), 'in 1h30m');
      expect(formatRelative(DateTime.utc(2026, 11, 5, 11, 33), now: now), 'in 2d');
    });

    test('overdueRun', () {
      final s = CronSchedule.tryParse('*/5 * * * *')!;
      final last = DateTime.utc(2026, 11, 3, 11, 30);
      expect(overdueRun(s, ZoneRules.utc, lastSchedule: last, now: DateTime.utc(2026, 11, 3, 11, 36)), isNull);
      expect(overdueRun(s, ZoneRules.utc, lastSchedule: last, now: DateTime.utc(2026, 11, 3, 11, 38)), DateTime.utc(2026, 11, 3, 11, 35));
      final daily = CronSchedule.tryParse('0 2 * * *')!;
      // Daily: grace is 6h.
      expect(overdueRun(daily, ZoneRules.utc, lastSchedule: DateTime.utc(2026, 11, 2, 2), now: DateTime.utc(2026, 11, 3, 7)), isNull);
      expect(overdueRun(daily, ZoneRules.utc, lastSchedule: DateTime.utc(2026, 11, 2, 2), now: DateTime.utc(2026, 11, 3, 9)), DateTime.utc(2026, 11, 3, 2));
      expect(overdueRun(daily, ZoneRules.utc, now: DateTime.utc(2026, 11, 3, 9)), isNull);
    });
  });

  group('Job panel', () {
    testWidgets('complete job: summary, pods via legacy controller-uid label', (tester) async {
      await loadRealFonts();
      final app = await pumpPanel(tester, migrateDb, api: _api(pods: migratePods));
      await saveScreenshot(tester, 'batch-job-complete');
      expect(find.text('Complete'), findsWidgets);
      expect(find.text('1 succeeded'), findsOneWidget);
      expect(find.text('took 11s'), findsOneWidget);
      expect(find.textContaining('exit 0', findRichText: true), findsOneWidget);
      expect(find.text("sh -c 'echo running migrations; sleep 3; echo done'"), findsOneWidget);
      expect(find.text('Never'), findsOneWidget);
      await tester.tap(find.text('migrate-db-xgbx9'));
      await tester.pump();
      expect(app.detail?.name, 'migrate-db-xgbx9');
      expect(app.detail?.type.kind, 'Pod');
    });

    testWidgets('failed job: reason, attempts and exit codes', (tester) async {
      await loadRealFonts();
      final app = await pumpPanel(tester, failedJob(), api: _api(pods: failedPods()));
      await saveScreenshot(tester, 'batch-job-failed');
      expect(find.text('Failed'), findsWidgets);
      expect(find.textContaining('BackoffLimitExceeded'), findsWidgets);
      expect(find.text('Job has reached the specified backoff limit'), findsWidgets);
      expect(find.text('3 failed'), findsOneWidget);
      expect(find.text('2 · 3 failures so far'), findsOneWidget);
      expect(find.text('#1'), findsOneWidget);
      expect(find.text('#3'), findsOneWidget);
      expect(find.textContaining('exit 137', findRichText: true), findsOneWidget);
      expect(find.textContaining('OOMKilled', findRichText: true), findsOneWidget);
      expect(find.text('psycopg2.OperationalError: connection refused'), findsOneWidget);
      expect(find.textContaining('will be deleted in 28m'), findsOneWidget);
      expect(find.text('FailJob when exit code in [42] (container import)'), findsOneWidget);
      expect(find.textContaining("'s3://bucket/data set.csv'"), findsOneWidget);
      await tester.tap(find.text('importer'));
      await tester.pump();
      expect(app.detail?.type.kind, 'ServiceAccount');
    });

    testWidgets('cronjob-owned job links to its CronJob', (tester) async {
      final job = liveJobs.firstWhere((j) => j['metadata']['name'] == 'report-29895100');
      final app = await pumpPanel(tester, job, api: _api(pods: reportPods));
      expect(find.text('report-29895100-ddwbj'), findsOneWidget);
      expect(find.text('report-29895095-74j44'), findsNothing);
      await tester.tap(find.text('CronJob/report'));
      await tester.pump();
      expect(app.detail?.type.kind, 'CronJob');
      expect(app.detail?.name, 'report');
    });

    testWidgets('prefers batch.kubernetes.io/controller-uid when present', (tester) async {
      await pumpPanel(tester, failedJob(), api: _api(pods: [...failedPods(), ...migratePods]));
      expect(find.text('migrate-db-xgbx9'), findsNothing);
      expect(find.text('#3'), findsOneWidget);
    });

    testWidgets('no pods shows an explanation', (tester) async {
      await pumpPanel(tester, migrateDb, api: _api());
      expect(find.textContaining('No pods found'), findsOneWidget);
    });
  });

  group('CronJob panel', () {
    testWidgets('schedule, next runs, status and history', (tester) async {
      await loadRealFonts();
      final app = await pumpPanel(tester, cronReport, api: _api(jobs: liveJobs));
      await saveScreenshot(tester, 'batch-cronjob');
      expect(find.text('*/5 * * * *'), findsOneWidget);
      expect(find.text('Every 5 minutes'), findsOneWidget);
      expect(find.textContaining('UTC (no spec.timeZone'), findsOneWidget);
      expect(find.text('Tue 03 Nov 11:35 UTC'), findsOneWidget);
      expect(find.text('in 2m'), findsOneWidget);
      expect(find.text('Tue 03 Nov 11:55 UTC'), findsOneWidget);
      expect(find.textContaining('Missed schedule'), findsNothing);
      expect(find.text('2 successful · 1 failed'), findsOneWidget);
      // History: owned jobs only, newest first.
      final newer = tester.getTopLeft(find.text('report-29895100')).dy;
      final older = tester.getTopLeft(find.text('report-29895095')).dy;
      expect(newer, lessThan(older));
      expect(find.text('migrate-db'), findsNothing);
      await tester.tap(find.text('report-29895100'));
      await tester.pump();
      expect(app.detail?.type.kind, 'Job');
    });

    testWidgets('suspended, time zone and overdue', (tester) async {
      await loadRealFonts();
      final cj = cronReport;
      cj['spec']['schedule'] = '0 */6 * * 1-5';
      cj['spec']['timeZone'] = 'Asia/Tokyo';
      cj['status'] = {
        'lastScheduleTime': '2026-11-01T15:00:00Z',
        'active': [
          {'kind': 'Job', 'name': 'report-1', 'namespace': 'demo', 'uid': 'x', 'apiVersion': 'batch/v1'}
        ],
      };
      await pumpPanel(tester, cj, api: _api(jobs: liveJobs));
      expect(find.text('At minute 0 past every 6th hour on Mon–Fri'), findsOneWidget);
      expect(find.textContaining('Asia/Tokyo (JST, UTC+09:00)'), findsOneWidget);
      // 11:33Z = 20:33 JST Tuesday → next is 00:00 JST Wednesday.
      expect(find.text('Wed 04 Nov 00:00 JST'), findsOneWidget);
      expect(find.textContaining('Missed schedule'), findsOneWidget);
      expect(find.text('report-1'), findsOneWidget);

      cj['spec']['suspend'] = true;
      await pumpPanel(tester, cj, api: _api(jobs: liveJobs));
      await saveScreenshot(tester, 'batch-cronjob-suspended');
      expect(find.text('Suspended: no new jobs will be scheduled'), findsOneWidget);
      expect(find.text('Next runs (if resumed)'), findsOneWidget);
      expect(find.textContaining('Missed schedule'), findsNothing);
    });

    testWidgets('unparseable schedule falls back to the raw expression', (tester) async {
      final cj = cronReport;
      cj['spec']['schedule'] = '@every 5m';
      await pumpPanel(tester, cj, api: _api());
      expect(find.text('Unrecognised schedule'), findsOneWidget);
      expect(find.text('Cannot compute run times for this expression.'), findsOneWidget);
    });
  });
}
