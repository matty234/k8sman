import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/pod/pod_logic.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';

Json fixture(String name) => jsonDecode(File('../dev/fixtures/$name.json').readAsStringSync()) as Json;

void main() {
  group('logic', () {
    test('effective status matches table semantics', () {
      expect(podEffectiveStatus(fixture('pod-web')), 'Running');
      expect(podEffectiveStatus(fixture('pod-crashy')), 'CrashLoopBackOff');
      expect(podEffectiveStatus(fixture('pod-bad-image')), 'ImagePullBackOff');
      final term = fixture('pod-web');
      (term['metadata'] as Map)['deletionTimestamp'] = '2026-11-03T12:00:00Z';
      expect(podEffectiveStatus(term), 'Terminating');
      final init = fixture('pod-web');
      ((init['status'] as Map)['initContainerStatuses'] as List)[0]['state'] = {
        'waiting': {'reason': 'CrashLoopBackOff'}
      };
      expect(podEffectiveStatus(init), 'Init:CrashLoopBackOff');
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
    await saveScreenshot(tester, 'pod-web');
    expect(tester.takeException(), isNull);
    for (final t in ['Status', 'Containers', 'Volumes', 'Scheduling', 'Conditions']) {
      expect(find.text(t), findsOneWidget, reason: t);
    }
    expect(find.text('INIT'), findsOneWidget);
    expect(find.textContaining('Healthy: all 2 containers'), findsOneWidget);
    expect(find.text('HTTP GET :http/ every 5s · timeout 1s · fail after 3'), findsOneWidget);
    expect(find.text('Burstable'), findsOneWidget);
    expect(find.text('nginx:1.27-alpine'), findsOneWidget);
    expect(find.text('field metadata.name'), findsOneWidget);
    expect(find.textContaining('heartbeat'), findsOneWidget); // command CodeBlock
  });

  testWidgets('pod-crashy shows CrashLoop insight and last state', (tester) async {
    await loadRealFonts();
    await pumpPanel(tester, fixture('pod-crashy'));
    await saveScreenshot(tester, 'pod-crashy');
    expect(tester.takeException(), isNull);
    expect(find.textContaining('is in CrashLoopBackOff: restarted 6 times, last exit code 3'), findsOneWidget);
    expect(find.text('Last state'), findsOneWidget);
    expect(find.textContaining('Error · exit 3'), findsOneWidget);
    expect(find.text('6 restarts'), findsNWidgets(2));
  });

  testWidgets('pod-bad-image explains the image pull failure', (tester) async {
    await loadRealFonts();
    await pumpPanel(tester, fixture('pod-bad-image'));
    await saveScreenshot(tester, 'pod-bad-image');
    expect(tester.takeException(), isNull);
    expect(find.textContaining("can't pull image registry.invalid/nope:latest"), findsOneWidget);
    expect(find.text('ImagePullBackOff'), findsWidgets);
  });

  testWidgets('links navigate to ConfigMap, Secret, Node and ServiceAccount', (tester) async {
    Future<void> tapAndExpect(String label, String kind, String name) async {
      final app = await pumpPanel(tester, fixture('pod-web'), size: const Size(560, 3000));
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
    await tapAndExpect('ConfigMap/web-config', 'ConfigMap', 'web-config'); // volume
  });

  testWidgets('logs tab streams lines, searches and filters', (tester) async {
    await loadRealFonts();
    final pod = fixture('pod-web');
    final lines = [
      for (var i = 0; i < 300; i++)
        LogMessage(line: i % 50 == 7 ? '2026/11/03 11:23:$i [error] upstream timed out ($i)' : '10.244.0.1 - - "GET /healthz HTTP/1.1" 200 $i'),
    ];
    final api = FakeApiClient(logLines: {'demo/web-6fd47b8fcb-4v4m9/nginx': lines});
    await pumpPanelTab(tester, pod, 'Logs', api: api);
    tester.view.physicalSize = const Size(560, 900);
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('300 lines'), findsOneWidget);
    expect(find.text('end of stream'), findsOneWidget);
    await saveScreenshot(tester, 'pod-logs');
    // Pinned to the bottom: the last line is visible.
    expect(find.textContaining('200 299'), findsOneWidget);
    await saveScreenshot(tester, 'pod-logs');

    await tester.enterText(find.byType(TextField), 'upstream');
    await tester.pump();
    expect(find.text('6 matches'), findsOneWidget);
    await tester.tap(find.text('Only matching'));
    await tester.pump();
    expect(find.textContaining('upstream timed out (7)'), findsOneWidget);
    expect(find.textContaining('GET /healthz'), findsNothing);
    await saveScreenshot(tester, 'pod-logs-filtered');
    expect(tester.takeException(), isNull);
  });

  testWidgets('logs tab picks the troubled container and shows not-started state', (tester) async {
    await loadRealFonts();
    await pumpPanelTab(tester, fixture('pod-bad-image'), 'Logs');
    tester.view.physicalSize = const Size(560, 500);
    await tester.pump();
    expect(find.textContaining('has not started yet: ImagePullBackOff'), findsOneWidget);
    await saveScreenshot(tester, 'pod-logs-not-started');

    await pumpPanelTab(tester, fixture('pod-crashy'), 'Logs',
        api: FakeApiClient(logLines: {'demo/crashy/app': const [LogMessage(line: 'starting'), LogMessage(line: 'fatal: config missing')]}));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump();
    expect(find.textContaining('fatal: config missing'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
