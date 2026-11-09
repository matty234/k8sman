import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/pod/pod_logic.dart';
import 'package:k8sman/ui/inspector/inspector.dart';

import '../../support/harness.dart';
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

}
