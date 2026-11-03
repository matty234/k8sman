import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';

import 'support/screenshot.dart';
import 'support/table_fakes.dart';

/// Visual review only: writes build/screenshots/table-*.png.
void main() {
  // Note: flutter_test draws elevation shadows as solid black outlines.
  final pods = TableData.fromJson(jsonDecode(File('../dev/fixtures/api-table-pods.json').readAsStringSync()));
  final type = ResourceType(
    group: '',
    version: 'v1',
    resource: 'pods',
    kind: 'Pod',
    verbs: const ['get', 'list', 'watch', 'delete'],
  );
  final table = TableData(
    resource: type,
    columns: pods.columns,
    isDefaultColumns: true,
    resourceVersion: '1',
    rows: [
      for (final r in pods.rows)
        TableRowData(uid: r.uid, name: r.name, namespace: r.namespace, resourceVersion: '1', cells: r.cells, controlled: r.name.startsWith('web')),
    ],
  );

  for (final b in Brightness.values) {
    testWidgets('bulk bar with 3 selected and the bulk confirm (${b.name})', (tester) async {
      await loadRealFonts();
      final api = TableFakeApi()..onWatch = () => [WatchMessage(type: 'SNAPSHOT', table: table)];
      final app = await pumpTable(tester, api, type, size: const Size(1100, 520), brightness: b, context: 'prod-eu');
      final names = app.types.isEmpty ? <String>[] : table.rows.map((r) => r.name).toList()..sort();
      await tester.tap(find.text(names[1]));
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.tap(find.text(names[3]));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();
      await saveScreenshot(tester, 'table-bulk-bar-${b.name}');
      await tester.tap(find.byKey(const ValueKey('bulk-Delete pods')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400)); // dialog fade-in
      await saveScreenshot(tester, 'table-bulk-confirm-${b.name}');
    });
  }

  const host = 'https://api.prod-eu.example.com:6443';
  final errors = <String, WatchMessage>{
    'unreachable': const WatchMessage(type: 'ERROR', reason: 'Unreachable', code: 502, host: host,
        error: 'Get "$host/api/v1/pods": dial tcp 10.20.0.4:6443: connect: connection refused'),
    'timeout': const WatchMessage(type: 'ERROR', reason: 'Timeout', code: 504, host: host,
        error: 'Get "$host/api/v1/pods": net/http: TLS handshake timeout'),
    'unauthorized': const WatchMessage(type: 'ERROR', reason: 'Unauthorized', code: 401, host: host,
        error: 'Get "$host/api/v1/pods": getting credentials: exec: executable aws failed with exit code 255: Error when retrieving token from sso: Token has expired and refresh failed'),
    'forbidden': const WatchMessage(type: 'ERROR', reason: 'Forbidden', code: 403, host: host,
        error: 'pods is forbidden: User "alice@example.com" cannot list resource "pods" in API group "" at the cluster scope'),
    'notfound': const WatchMessage(type: 'ERROR', reason: 'NotFound', code: 404, host: host,
        error: 'resource type not served: resource /v1 "pods" not found'),
  };
  for (final e in errors.entries) {
    testWidgets('error state: ${e.key}', (tester) async {
      await loadRealFonts();
      final api = TableFakeApi()..onWatch = () => [e.value];
      await pumpTable(tester, api, type, size: const Size(1000, 620), context: 'prod-eu');
      await tester.pump(const Duration(milliseconds: 1100));
      await saveScreenshot(tester, 'table-error-${e.key}');
      await tester.pump(const Duration(seconds: 20));
    });
  }

  testWidgets('error state: backend down', (tester) async {
    await loadRealFonts();
    final api = TableFakeApi()..watchError = Exception('WebSocketChannelException: SocketException: Connection refused (OS Error: Connection refused, errno = 61), address = 127.0.0.1, port = 7443');
    await pumpTable(tester, api, type, size: const Size(1000, 520), context: 'prod-eu');
    await tester.pump(const Duration(milliseconds: 1100));
    await saveScreenshot(tester, 'table-error-backend-down');
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('stale rows banner', (tester) async {
    await loadRealFonts();
    final api = TableFakeApi()..onWatch = () => [WatchMessage(type: 'SNAPSHOT', table: table)];
    await pumpTable(tester, api, type, size: const Size(1000, 420), context: 'prod-eu');
    api.watchController!.add(errors['unreachable']!);
    await tester.pump(const Duration(milliseconds: 1100));
    await saveScreenshot(tester, 'table-stale-banner');
    await tester.pump(const Duration(seconds: 20));
  });

  testWidgets('namespace picker open with a query', (tester) async {
    await loadRealFonts();
    final api = TableFakeApi()
      ..namespaceList = [
        for (final n in ['argocd', 'cert-manager', 'default', 'demo', 'ingress-nginx', 'kube-node-lease', 'kube-public', 'kube-system', 'monitoring', 'payments-api', 'payments-worker', 'platform-kube-tools'])
          n,
      ]
      ..onWatch = () => [WatchMessage(type: 'SNAPSHOT', table: table)];
    final app = await pumpTable(tester, api, type, size: const Size(1000, 520));
    app
      ..setNamespace('monitoring')
      ..setNamespace('demo');
    await tester.pump();
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('namespace-picker')));
    await tester.pump();
    await saveScreenshot(tester, 'namespace-picker-open');
    await tester.enterText(find.byKey(const ValueKey('picker-search')), 'kube');
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await saveScreenshot(tester, 'namespace-picker-query');
  });
}
