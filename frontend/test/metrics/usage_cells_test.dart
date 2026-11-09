import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/metrics/quantity_cell.dart';
import 'package:k8sman/state/table_query.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/util/k8s.dart';

import '../support/screenshot.dart';
import '../support/table_fakes.dart';

const _cpu = ColumnDef(name: 'CPU', query: '.k8sman.usage', type: 'usage');
const _mem = ColumnDef(name: 'Memory', query: '.k8sman.usage', type: 'usage');

Map<String, dynamic> _usage(double raw, {double? base, String? basis, String unit = 'cpu'}) => {
  'raw': raw,
  'base': base,
  'percent': base == null ? null : (raw / base * 1000).round() / 10,
  'basis': basis,
  'unit': unit,
};

void main() {
  testWidgets('Pods usage cells: value, bar and % (amber ≥70, red ≥90), sorted by %, filterable, narrow keeps the value', (tester) async {
    await loadRealFonts();
    final pods = TableData.fromJson(jsonDecode(File('../dev/fixtures/api-table-pods.json').readAsStringSync()));
    // CPU against the limit (or request); one pod has neither.
    final cpu = <String, Map<String, dynamic>>{
      'bad-image': _usage(0.012, base: 0.5, basis: 'limit'),
      'crashy': _usage(0.38, base: 0.5, basis: 'limit'),
      'web-6fd47b8fcb-4v4m9': _usage(0.19, base: 0.2, basis: 'request'),
      'web-6fd47b8fcb-z7wpf': _usage(1.25),
    };
    final mem = <String, Map<String, dynamic>>{
      for (final (i, r) in pods.rows.indexed) r.name: _usage((40 + i * 30) * 1048576.0, base: 256 * 1048576.0, basis: 'limit', unit: 'bytes'),
    };
    const at = 5; // after Restarts
    final columns = [...pods.columns.take(at), _cpu, _mem, ...pods.columns.skip(at)];
    final table = TableData(
      resource: podType,
      columns: columns,
      isDefaultColumns: true,
      resourceVersion: '1',
      rows: [
        for (final r in pods.rows)
          TableRowData(
            uid: r.uid,
            name: r.name,
            namespace: r.namespace,
            resourceVersion: '1',
            cells: [...r.cells.take(at), cpu[r.name], mem[r.name], ...r.cells.skip(at)],
          ),
      ],
    );
    final api = TableFakeApi()..onWatch = () => [WatchMessage(type: 'SNAPSHOT', table: table)];
    final app = await pumpTable(tester, api, podType, size: const Size(1280, 440), brightness: Brightness.dark);
    await tester.pump();
    await saveScreenshot(tester, 'metrics-pods-usage');
    expect(tester.takeException(), isNull);

    final ctx = tester.element(find.text('2%'));
    Color? colour(String t) => tester.widget<Text>(find.text(t)).style?.color;
    expect(colour('2%'), Theme.of(ctx).hintColor, reason: 'calm below 70%');
    expect(colour('76%'), severityColor(ctx, Severity.warn));
    expect(colour('95%'), severityColor(ctx, Severity.error));
    expect(find.text('1.25'), findsOneWidget, reason: 'no limit or request: the value alone');

    // Sorting by CPU orders by %; a pod without a base ranks below any with one.
    await tester.tap(find.text('CPU'));
    await tester.pump();
    double y(String name) => tester.getTopLeft(find.text(name)).dy;
    expect(y('web-6fd47b8fcb-z7wpf'), lessThan(y('bad-image')));
    expect(y('bad-image'), lessThan(y('crashy')));
    expect(y('crashy'), lessThan(y('web-6fd47b8fcb-4v4m9')));

    // Filters compare the value, or the percentage with `%`.
    bool match(String q, String name) => TableQuery.parse(q, columns).matches(table.rows.firstWhere((r) => r.name == name));
    expect(match('cpu>300m', 'crashy'), isTrue);
    expect(match('cpu>300m', 'bad-image'), isFalse);
    expect(match('cpu%>80', 'web-6fd47b8fcb-4v4m9'), isTrue);
    expect(match('cpu%>80', 'crashy'), isFalse);
    expect(app.types, isNotEmpty);

    // Under ~90px only the value is left (coloured when over a threshold).
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: SizedBox(width: 80, child: UsageCell(value: cpu['web-6fd47b8fcb-4v4m9']))),
    ));
    expect(find.text('190m'), findsOneWidget);
    expect(find.text('95%'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PVC Used: bar, % and used / size; "—" without stats', (tester) async {
    await loadRealFonts();
    const pvcType = ResourceType(group: '', version: 'v1', resource: 'persistentvolumeclaims', kind: 'PersistentVolumeClaim', verbs: ['get', 'list', 'watch']);
    const columns = [
      ColumnDef(name: 'Name', query: '.metadata.name'),
      ColumnDef(name: 'Namespace', query: '.metadata.namespace'),
      ColumnDef(name: 'Status', query: '.status.phase', type: 'status'),
      ColumnDef(name: 'Capacity', query: '.status.capacity.storage'),
      ColumnDef(name: 'Used', query: '.k8sman.usage', type: 'usage'),
      ColumnDef(name: 'StorageClass', query: '.spec.storageClassName'),
    ];
    const gi = 1024 * 1024 * 1024.0;
    TableRowData row(String name, String cap, Map<String, dynamic>? used) =>
        TableRowData(uid: name, name: name, namespace: 'demo', resourceVersion: '1', cells: [name, 'demo', 'Bound', cap, used, 'standard']);
    Map<String, dynamic> used(double u, double c) => _usage(u * gi, base: c * gi, basis: 'capacity', unit: 'bytes');
    final table = TableData(resource: pvcType, columns: columns, isDefaultColumns: true, resourceVersion: '1', rows: [
      row('data-redis-0', '50Gi', used(12, 50)),
      row('data-postgres-0', '20Gi', used(17, 20)),
      row('logs', '10Gi', used(9.4, 10)),
      row('unmounted', '5Gi', null),
    ]);
    final api = TableFakeApi()..onWatch = () => [WatchMessage(type: 'SNAPSHOT', table: table)];
    await pumpTable(tester, api, pvcType, size: const Size(1100, 300), brightness: Brightness.dark);
    await tester.pump();
    await saveScreenshot(tester, 'metrics-pvc-used');
    expect(find.text('12 / 50 Gi'), findsOneWidget);
    expect(find.text('24%'), findsOneWidget);
    final ctx = tester.element(find.text('24%'));
    expect(tester.widget<Text>(find.text('85%')).style?.color, severityColor(ctx, Severity.warn), reason: 'PVCs: amber from 80%');
    expect(tester.widget<Text>(find.text('94%')).style?.color, severityColor(ctx, Severity.error));
    expect(find.text('—'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
