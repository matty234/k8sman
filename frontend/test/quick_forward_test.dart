import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';

import 'support/harness.dart';

Json _fx(String n) => Map<String, dynamic>.from(jsonDecode(File('../dev/fixtures/$n').readAsStringSync()));

class _PfApi extends FakeApiClient {
  final created = <String>[];
  @override
  Future<List<PortForward>> portForwards() async => const [];
  @override
  Future<PortForward> createPortForward({
    required String namespace,
    required String kind,
    required String name,
    required String port,
    int localPort = 0,
    bool autoStart = false,
    String? label,
    bool replace = false,
    bool openInBrowser = false,
    bool https = false,
    bool ephemeral = false,
  }) async {
    created.add('$namespace/$kind/$name:$port');
    return PortForward(id: 'x', context: 'kind', namespace: namespace, kind: kind, name: name, port: port, localPort: int.parse(port), state: 'active');
  }
}

void main() {
  testWidgets('pod: one-click forward on a container port becomes a localhost link', (tester) async {
    final api = _PfApi();
    final pod = _fx('pod-web.json');
    await pumpPanel(tester, pod, api: api);
    final btn = find.byKey(const ValueKey('quick-forward-pod-8080'));
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    await tester.pumpAndSettle();
    expect(api.created, ['demo/pod/${pod['metadata']['name']}:8080']);
    expect(find.text('localhost:8080'), findsOneWidget);
  });

  testWidgets('service: one-click forward per service port', (tester) async {
    final api = _PfApi();
    await pumpPanel(tester, _fx('svc-web.json'), api: api);
    final btn = find.byKey(const ValueKey('quick-forward-service-80'));
    expect(btn, findsOneWidget);
    await tester.tap(btn);
    await tester.pumpAndSettle();
    expect(api.created, ['demo/service/web:80']);
  });

  testWidgets('read-only hides quick forwards', (tester) async {
    await pumpPanel(tester, _fx('pod-web.json'), api: _PfApi(), readOnly: true);
    expect(find.byKey(const ValueKey('quick-forward-pod-8080')), findsNothing);
  });
}
