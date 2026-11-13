import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/pod/pod_logic.dart';
import 'package:k8sman/ui/inspector/inspector.dart';

import '../../support/harness.dart';
import 'package:k8sman/util/k8s.dart' show Severity;
import 'package:k8sman/util/pod.dart';

Json fixture(String name) => jsonDecode(File('../dev/fixtures/$name.json').readAsStringSync()) as Json;

void main() {
  setUp(SectionMemory.reset);

  group('logic', () {
    test('effective status matches table semantics', () {
      expect(podStatus(fixture('pod-web')), 'Running');
      expect(podStatus(fixture('pod-crashy')), 'CrashLoopBackOff');
      expect(podStatus(fixture('pod-bad-image')), 'ImagePullBackOff');
      final term = fixture('pod-web');
      (term['metadata'] as Map)['deletionTimestamp'] = '2026-11-03T12:00:00Z';
      expect(podStatus(term), 'Terminating');
      final init = fixture('pod-web');
      ((init['status'] as Map)['initContainerStatuses'] as List)[0]['state'] = {
        'waiting': {'reason': 'CrashLoopBackOff'}
      };
      expect(podStatus(init), 'Init:CrashLoopBackOff');
    });

    test('containers are paired and labelled', () {
      final cs = podContainers(fixture('pod-web'));
      expect([for (final c in cs) '${c.kind.label}:${c.name}'], ['Init:init-wait', 'Container:nginx', 'Container:log-sidecar']);
      expect(cs[1].status['imageID'], contains('nginx@sha256'));
    });

    test('restarts are explained by their pattern; env fields resolve from the pod', () {
      final now = DateTime.utc(2026, 11, 10, 12);
      final start = now.subtract(const Duration(days: 4));
      PodContainer web(Json lastTerminated, {int restarts = 130, Json? state, Json limits = const {}}) => PodContainer(
            ContainerKind.regular,
            {'name': 'web', 'resources': {'limits': limits}},
            {
              'name': 'web',
              'ready': state == null,
              'restartCount': restarts,
              'state': state ?? {'running': {}},
              'lastState': {'terminated': lastTerminated},
            },
          );
      final ran = {'startedAt': '2026-11-10T11:00:00Z', 'finishedAt': '2026-11-10T11:43:00Z'};

      final clean = restartInsight(web({'exitCode': 0, 'reason': 'Completed', ...ran}), podStart: start, ownerKind: 'ReplicaSet', now: now)!;
      expect(clean.severity, Severity.info);
      expect(clean.text, 'Exits cleanly (code 0) about every 44m · 130× in 4d');
      expect(clean.detail, contains('last ran 43m'));
      expect(clean.detail, contains('Job or CronJob'));
      expect(web({'exitCode': 0}).severity, Severity.info); // the dot agrees

      final err = restartInsight(web({'exitCode': 1, 'reason': 'Error', ...ran}, restarts: 2), podStart: start, named: true, now: now)!;
      expect((err.severity, err.text), (Severity.warn, 'web: exits with code 1 (Error) about every 2d · 2× in 4d'));
      expect(err.detail, startsWith('general application error · last ran 43m'));

      final oom = restartInsight(web({'exitCode': 137, 'reason': 'OOMKilled', ...ran}, limits: {'memory': '128Mi'}), podStart: start, now: now)!;
      expect((oom.severity, oom.detail?.split(' · ').first), (Severity.error, 'exceeds its memory limit (128Mi)'));

      final loop = web({'exitCode': 3, 'reason': 'Error'}, restarts: 6, state: {'waiting': {'reason': 'CrashLoopBackOff'}});
      expect(restartKind(loop), RestartKind.crashLoop);
      expect(restartInsight(loop, podStart: now.subtract(const Duration(minutes: 6)), now: now)!.text, startsWith('CrashLoopBackOff: exits with code 3 (Error) about every 1m'));
      expect(restartInsight(web({}, restarts: 0), now: now), isNull);

      final pod = {
        'metadata': {'name': 'web-0', 'namespace': 'default', 'labels': {'tier': 'front'}},
        'spec': {'nodeName': 'node-1'},
        'status': {'podIPs': [{'ip': '10.0.0.5'}, {'ip': 'fd00::5'}]},
      };
      final c = {'name': 'web', 'resources': {'limits': {'memory': '256Mi', 'cpu': '1500m'}}};
      String? field(String path) => resolveEnvSource(pod, c, {'fieldRef': {'fieldPath': path}});
      expect(field('metadata.namespace'), 'default');
      expect(field("metadata.labels['tier']"), 'front');
      expect(field('spec.nodeName'), 'node-1');
      expect(field('status.podIPs'), '10.0.0.5,fd00::5');
      expect(field('status.hostIP'), isNull); // unknown: the source only
      expect(resolveEnvSource(pod, c, {'resourceFieldRef': {'resource': 'limits.memory', 'divisor': '1Mi'}}), '256');
      expect(resolveEnvSource(pod, c, {'resourceFieldRef': {'resource': 'limits.cpu'}}), '2'); // rounded up
      expect(resolveEnvSource(pod, c, {'resourceFieldRef': {'resource': 'requests.cpu'}}), isNull);
    });

  });

  testWidgets('pod-web overview renders all sections', (tester) async {
    await pumpPanel(tester, fixture('pod-web'), size: const Size(560, 3000));
    expect(tester.takeException(), isNull);
    for (final t in ['Containers', 'Volumes', 'Scheduling', 'Configuration', 'Conditions']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('Init'), findsOneWidget);
    expect(find.textContaining('Healthy: all 2 containers'), findsOneWidget);
    expect(find.text('nginx:1.27-alpine'), findsOneWidget); // the row's short image
    // Details open on demand.
    await tester.tap(find.byKey(const ValueKey('container-row-nginx')));
    await tester.tap(find.byKey(const ValueKey('container-row-log-sidecar')));
    await tester.tap(find.byKey(const ValueKey('pod-section-configuration')));
    await tester.pump();
    expect(find.text('HTTP :http/ · 5s · fails after 3'), findsOneWidget); // readiness, one line
    expect(find.text('Burstable'), findsOneWidget);
    // Requests and limits per container (also with Prometheus), and the pod's totals.
    String res(String c, String k) => tester.widget<Text>(find.byKey(ValueKey('container-resource-$c-$k'))).textSpan!.toPlainText();
    expect(res('nginx', 'cpu'), '50m request  ·  200m limit');
    expect(res('log-sidecar', 'memory'), '8Mi request  ·  no limit');
    expect(find.textContaining('55m CPU'), findsNWidgets(2)); // the summary and the Requests row
    expect(find.text('unbounded'), findsOneWidget); // the sidecar sets no limits
    expect(find.text('metadata.name'), findsOneWidget); // POD_NAME, resolved
    expect(find.textContaining('heartbeat'), findsNothing); // the long command is collapsed to three lines
    await tester.tap(find.textContaining('Show all'));
    await tester.pump();
    expect(find.textContaining('heartbeat'), findsOneWidget);
  });

  testWidgets('healthy containers start collapsed, troubled ones open; reference sections summarise when collapsed', (tester) async {
    await pumpPanel(tester, fixture('pod-web'), size: const Size(560, 3000));
    expect(find.text('Image'), findsNothing); // nginx and log-sidecar collapsed
    expect(find.text('2 · 1 ConfigMap, 1 emptyDir'), findsOneWidget); // Volumes, collapsed
    expect(find.text('web-config'), findsNothing);

    await pumpPanel(tester, fixture('pod-crashy'), size: const Size(560, 3000));
    expect(find.text('Image'), findsOneWidget); // app is open
    expect(find.text('Waiting: CrashLoopBackOff'), findsOneWidget);
    expect(find.text('Ready, ContainersReady false'), findsOneWidget);
  });

}
