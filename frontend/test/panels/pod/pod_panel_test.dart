import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/panel.dart';
import 'package:k8sman/panels/pod/pod_logic.dart';
import 'package:k8sman/panels/pod/pod_panel.dart';
import 'package:k8sman/ui/inspector/inspector.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:provider/provider.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';
import 'package:k8sman/util/pod.dart';
import 'package:k8sman/util/text.dart';

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

    test('crashloop insight explains the restart', () {
      final text = podInsights(fixture('pod-crashy')).map((i) => i.toString()).join('\n');
      expect(text, contains('Container app is in CrashLoopBackOff: restarted 6 times, last exit code 3 (Error)'));
      expect(text, contains('previous'));
      expect(podInsights(fixture('pod-web')), isEmpty);
    });

    test('probe sentences and shell quoting', () {
      expect(probeSentence({'httpGet': {'path': '/', 'port': 'http'}, 'periodSeconds': 5, 'timeoutSeconds': 1, 'failureThreshold': 3}),
          'HTTP GET :http/ every 5s · timeout 1s · fail after 3');
      expect(probeSentence({'tcpSocket': {'port': 8080}, 'initialDelaySeconds': 5}), 'TCP :8080 every 10s · delay 5s · timeout 1s · fail after 3');
      expect(shellJoin(['sh', '-c', "echo 'hi' >&2; exit 3"]), "sh -c 'echo '\\''hi'\\'' >&2; exit 3'");
    });
  });

  testWidgets('pod-web overview renders all sections', (tester) async {
    await loadRealFonts();
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
    expect(find.text('field metadata.name'), findsOneWidget);
    expect(find.textContaining('heartbeat'), findsOneWidget); // command CodeBlock
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

  testWidgets('a slim inspector (320px) lays the pod out without overflow', (tester) async {
    for (final f in ['pod-web', 'pod-crashy']) {
      await pumpPanel(tester, fixture(f), size: const Size(320, 3000));
      expect(tester.takeException(), isNull, reason: f);
    }
  });

  testWidgets('container details trim long env lists and sum up security on one line', (tester) async {
    final pod = fixture('pod-web');
    final nginx = (pod['spec']['containers'] as List)[0] as Map;
    (nginx['env'] as List).addAll([for (var i = 0; i < 5; i++) {'name': 'EXTRA_$i', 'value': 'v$i'}]);
    nginx['securityContext'] = {'runAsNonRoot': true, 'allowPrivilegeEscalation': true, 'capabilities': {'drop': ['ALL']}};
    await pumpPanel(tester, pod, size: const Size(560, 3000));
    await tester.tap(find.byKey(const ValueKey('container-row-nginx')));
    await tester.pump();
    expect(find.text('LOG_LEVEL'), findsOneWidget); // the 4th of 9
    expect(find.text('EXTRA_0'), findsNothing);
    await tester.tap(find.text('Show 5 more'));
    await tester.pump();
    expect(find.text('EXTRA_4'), findsOneWidget);
    expect(find.text('non-root  ·  privilege escalation allowed  ·  drops ALL', findRichText: true), findsOneWidget);
  });

  testWidgets('pod-crashy shows CrashLoop insight and last state', (tester) async {
    await loadRealFonts();
    await pumpPanel(tester, fixture('pod-crashy'));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('is in CrashLoopBackOff: restarted 6 times, last exit code 3'), findsOneWidget);
    expect(find.text('Last state'), findsOneWidget);
    expect(find.textContaining('Error · exit 3'), findsOneWidget);
    expect(find.byTooltip('6 restarts'), findsOneWidget); // the row
    expect(find.text('restarts'), findsOneWidget); // the status figure
  });

  testWidgets('pod-bad-image explains the image pull failure', (tester) async {
    await loadRealFonts();
    await pumpPanel(tester, fixture('pod-bad-image'));
    expect(tester.takeException(), isNull);
    expect(find.textContaining("can't pull image registry.invalid/nope:latest"), findsOneWidget);
    expect(find.text('ImagePullBackOff'), findsWidgets);
  });

  testWidgets('links navigate to ConfigMap, Secret, Node and ServiceAccount', (tester) async {
    Future<void> tapAndExpect(String label, String kind, String name) async {
      final app = await pumpPanel(tester, fixture('pod-web'), size: const Size(560, 3000));
      // Env links sit in nginx's details, the volume in Volumes.
      if (find.text(label).evaluate().isEmpty) {
        await tester.tap(find.byKey(const ValueKey('container-row-nginx')));
        await tester.tap(find.byKey(const ValueKey('pod-section-volumes')));
        await tester.pump();
      }
      await tester.tap(find.text(label).first);
      await tester.pump();
      expect(app.detail?.type.kind, kind, reason: label);
      expect(app.detail?.name, name);
      expect(app.canGoBack, isTrue);
    }

    await tapAndExpect('cm/web-config', 'ConfigMap', 'web-config');
    await tapAndExpect('secret/web-secret', 'Secret', 'web-secret');
    await tapAndExpect('k8sman-dev-control-plane', 'Node', 'k8sman-dev-control-plane');
    await tapAndExpect('web', 'ServiceAccount', 'web');
    await tapAndExpect('web-config', 'ConfigMap', 'web-config'); // volume
  });

  testWidgets('log stream view streams lines, searches and filters', (tester) async {
    await loadRealFonts();
    final pod = fixture('pod-web');
    final lines = [
      for (var i = 0; i < 300; i++)
        LogMessage(line: i % 50 == 7 ? '2026/11/03 11:23:$i [error] upstream timed out ($i)' : '10.244.0.1 - - "GET /healthz HTTP/1.1" 200 $i'),
    ];
    final api = FakeApiClient(logLines: {'demo/web-6fd47b8fcb-4v4m9/nginx': lines});
    final dock = await pumpLogDock(tester, pod, api: api);
    final s = dock.active!;
    expect(s.container, 'nginx');
    expect(find.textContaining('300 lines'), findsOneWidget);
    expect(find.textContaining('ended'), findsOneWidget);
    // Pinned to the bottom: the last line is visible.
    expect(find.textContaining('200 299'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'upstream');
    await tester.pump();
    expect(s.matching.length, 6);
    await tester.tap(find.byTooltip('Show only matching lines (6 matches)'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('upstream timed out (7)'), findsOneWidget);
    expect(find.textContaining('GET /healthz'), findsNothing);

    // Clear empties the buffer and counts the dropped lines.
    await tester.tap(find.byTooltip('Clear'));
    await tester.pump();
    expect(s.lines, isEmpty);
    expect(s.dropped, 300);
    expect(tester.takeException(), isNull);
    dock.closeAll();
  });

  testWidgets('log stream keeps at most 10k lines', (tester) async {
    final lines = [for (var i = 0; i < 10050; i++) LogMessage(line: 'line $i')];
    final dock = await pumpLogDock(tester, fixture('pod-web'), api: FakeApiClient(logLines: {'demo/web-6fd47b8fcb-4v4m9/nginx': lines}));
    final s = dock.active!;
    expect(s.lines.length, 10000);
    expect(s.dropped, 50);
    expect(s.lines.first, 'line 50');
    dock.closeAll();
  });

  testWidgets('logs pick the troubled container and show the not-started state', (tester) async {
    await loadRealFonts();
    var dock = await pumpLogDock(tester, fixture('pod-bad-image'), size: const Size(560, 300));
    expect(find.textContaining('has not started yet: ImagePullBackOff'), findsOneWidget);
    dock.closeAll();

    dock = await pumpLogDock(tester, fixture('pod-crashy'),
        api: FakeApiClient(logLines: {'demo/crashy/app': const [LogMessage(line: 'starting'), LogMessage(line: 'fatal: config missing')]}));
    expect(dock.active!.container, 'app');
    expect(find.textContaining('fatal: config missing'), findsOneWidget);
    expect(tester.takeException(), isNull);
    dock.closeAll();
  });

  testWidgets('container rows open logs (and previous-instance logs after restarts)', (tester) async {
    await pumpPanel(tester, fixture('pod-crashy'), size: const Size(560, 3000));
    final dock = Provider.of<LogDock>(tester.element(find.byType(ListView).first), listen: false);
    await tester.tap(find.byKey(const ValueKey('view-logs-app')));
    await tester.pump();
    expect(dock.tabs.map((t) => t.label), ['crashy/app']);
    expect(dock.active!.previous, isFalse);

    // Same stream again focuses the tab, switching it to the previous instance.
    await tester.tap(find.byKey(const ValueKey('view-previous-logs-app')));
    await tester.pump();
    expect(dock.tabs.length, 1);
    expect(dock.active!.previous, isTrue);

    // No restarts: no previous-instance link.
    await pumpPanel(tester, fixture('pod-web'), size: const Size(560, 3000));
    expect(find.byKey(const ValueKey('view-logs-nginx')), findsOneWidget);
    expect(find.byKey(const ValueKey('view-previous-logs-nginx')), findsNothing);
    dock.closeAll();
  });

  test('pod panel offers a Logs action instead of a Logs tab', () {
    final pod = fixture('pod-web');
    final ctx = PanelContext(object: pod, type: testType('', 'Pod'), api: FakeApiClient(), app: AppState(FakeApiClient()));
    expect(const PodPanel().tabs(ctx), isEmpty);
    expect(const PodPanel().actions(ctx).map((a) => a.id), ['logs', 'terminal']);
  });
}
