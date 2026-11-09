import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/table_controller.dart';
import 'package:k8sman/state/table_query.dart';
import 'package:k8sman/ui/resource_table.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/table_fakes.dart';

const cols = [
  ColumnDef(name: 'Status', query: '.status.phase'),
  ColumnDef(name: 'Restarts', query: '.r', type: 'number'),
  ColumnDef(name: 'Pod IP', query: '.status.podIP'),
  ColumnDef(name: 'Memory', query: '.m', type: 'quantity'),
  ColumnDef(name: 'Age', query: '.metadata.creationTimestamp', type: 'age'),
];

final now = DateTime.utc(2026, 11, 4, 12);
TableRowData row(String name, String status, int restarts, String ip, String mem, Duration age, {String ns = 'demo'}) => TableRowData(
  uid: name,
  name: name,
  namespace: ns,
  resourceVersion: '1',
  cells: [status, restarts, ip, mem, now.subtract(age).toIso8601String()],
);

final rows = [
  row('api', 'Running', 0, '10.0.0.1', '128Mi', const Duration(minutes: 5)),
  row('web', 'Running', 3, '10.0.0.2', '2Gi', const Duration(days: 3)),
  row('job', 'Completed', 0, '10.0.1.9', '64Mi', const Duration(days: 10), ns: 'batch'),
  row('bad', 'CrashLoopBackOff', 12, '10.0.0.3', '512Mi', const Duration(hours: 2)),
];

List<String> matching(String q) => [for (final r in rows) if (TableQuery.parse(q, cols).matches(r, now: now)) r.name];

void main() {
  test('query language: text, fields, negation, comparisons, AND, quotes', () {
    expect(matching(''), ['api', 'web', 'job', 'bad']);
    expect(matching('crash'), ['bad'], reason: 'plain text matches any cell');
    expect(matching('status=running'), ['api', 'web']);
    expect(matching('status:running'), ['api', 'web']);
    expect(matching('status!=running'), ['job', 'bad']);
    expect(matching('restarts>0'), ['web', 'bad']);
    expect(matching('restarts>=3 restarts<10'), ['web'], reason: 'terms combine');
    expect(matching('memory>256Mi'), ['web', 'bad'], reason: 'quantities by value');
    expect(matching('age<1h'), ['api']);
    expect(matching('age>1d'), ['web', 'job']);
    expect(matching('pod-ip=10.0.1'), ['job'], reason: 'spaced column names as hyphens');
    expect(matching('podip=10.0.1'), ['job']);
    expect(matching('namespace=batch'), ['job'], reason: 'name/namespace work without columns');
    expect(matching('status=running web'), ['web']);
    expect(matching('status='), ['api', 'web', 'job', 'bad'], reason: 'half-typed terms are ignored');
    expect(matching('restarts>lots'), isEmpty);
    expect(matching('"0.0.3"'), ['bad']);
    expect(matching('app=web'), isEmpty, reason: 'unknown key: plain text "app=web"');

    // Bare negation, negated column terms, regexes.
    expect(matching('!running'), ['job', 'bad']);
    expect(matching('-running'), ['job', 'bad']);
    expect(matching('!status=running'), ['job', 'bad']);
    expect(matching('!status=running !crash'), ['job']);
    expect(matching('/^(api|web)\$/'), ['api', 'web'], reason: 'regex on any cell, incl. name');
    expect(matching('status=/^run/'), ['api', 'web']);
    expect(matching('status!=/^run/'), ['job', 'bad']);
    expect(matching('!/crash|complete/'), ['api', 'web']);
    expect(matching('pod-ip=/10\\.0\\.1\\./'), ['job']);
    expect(matching('/(/'), isEmpty, reason: 'invalid regex matches nothing');
    expect(matching('!/(/'), isEmpty);
    expect(TableQuery.parse('/(/', cols).error, isNotNull);
    expect(TableQuery.parse('/a/', cols).error, isNull);
 
    // PVC "Used" (usage of capacity): a bare number is the percentage, a
    // quantity the bytes; claims without stats never match.
    const used = [ColumnDef(name: 'Used', query: '.k8sman.usage', type: 'usage')];
    TableRowData pvc(String n, double? p) => TableRowData(
        uid: n, name: n, namespace: 'demo', resourceVersion: '1', cells: [if (p == null) null else {'raw': p * 1e9, 'base': 100e9, 'percent': p, 'basis': 'capacity', 'unit': 'bytes'}]);
    final pvcs = [pvc('a', 12), pvc('b', 85), pvc('c', null)];
    List<String> usedMatching(String s) => [for (final r in pvcs) if (TableQuery.parse(s, used).matches(r, now: now)) r.name];
    expect(usedMatching('used>80'), ['b']);
    expect(usedMatching('used<20G'), ['a']);
  });

  test('suggestions: fields first, then values seen in the column', () {
    final fields = filterSuggestions('', cols, rows);
    expect(fields.map((s) => s.label), ['name=', 'namespace=', 'status=', 'restarts=', 'pod-ip=', 'memory=', 'age=']);
    expect(filterSuggestions('re', cols, rows).map((s) => s.result), ['restarts=']);
    expect(filterSuggestions('status=running r', cols, rows).map((s) => s.result), ['status=running restarts=']);
    expect(filterSuggestions('status=running ', cols, rows).map((s) => s.label), isNot(contains('status=')), reason: 'used fields drop out');

    final values = filterSuggestions('status=', cols, rows);
    expect(values.map((s) => s.label), ['Running', 'Completed', 'CrashLoopBackOff'], reason: 'most common first, then A–Z');
    expect(values.first.detail, '2');
    expect(values.first.result, 'status=Running ');
    expect(filterSuggestions('status=c', cols, rows).map((s) => s.label), ['Completed', 'CrashLoopBackOff']);
    expect(filterSuggestions('age=', cols, rows).map((s) => s.result), ['age<1h ', 'age<1d ', 'age>7d ']);
    expect(filterSuggestions('nginx', cols, rows), isEmpty);
  });

  testWidgets('filter box suggests fields and values; Tab/Enter pick them', (tester) async {
    final api = TableFakeApi()
      ..onWatch = () => [
        WatchMessage(type: 'SNAPSHOT', table: fakeTable(deployType, [fakeRow('api'), fakeRow('web'), fakeRow('db', ns: 'data')])),
      ];
    await pumpTable(tester, api, deployType);
    final tc = Provider.of<TableController>(tester.element(find.byType(ListView).first), listen: false);

    await tester.tap(find.byKey(const ValueKey('table-filter')));
    await tester.enterText(find.byKey(const ValueKey('table-filter')), 'names');
    await tester.pump();
    expect(find.byKey(const ValueKey('filter-suggestions')), findsOneWidget);
    expect(find.text('namespace='), findsOneWidget);
    expect(find.text('name='), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(tc.filter, 'namespace=');
    expect(find.text('demo'), findsWidgets, reason: 'values from the column');
    expect(find.text('data'), findsWidgets);

    await tester.enterText(find.byKey(const ValueKey('table-filter')), 'namespace=da');
    await tester.pump();
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pump();
    expect(tc.filter, 'namespace=data ');
    expect(tc.rows.map((r) => r.name), ['db']);
  });

  testWidgets('sort is kept when the table is left and reopened', (tester) async {
    final api = TableFakeApi()
      ..onWatch = () => [
        WatchMessage(type: 'SNAPSHOT', table: fakeTable(deployType, [fakeRow('api'), fakeRow('web'), fakeRow('db')])),
      ];
    final app = await pumpTable(tester, api, deployType);
    TableController tc() => Provider.of<TableController>(tester.element(find.byType(ListView).first), listen: false);
    await tester.tap(find.text('Name').first);
    await tester.pump();
    await tester.tap(find.text('Name').first);
    await tester.pump();
    expect(tc().rows.map((r) => r.name), ['web', 'db', 'api']);

    // Navigate away (the table is disposed) and back.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: ResourceTableView(type: deployType))),
    ));
    await tester.pump();
    await tester.pump();
    expect(tc().sortColumn, 0);
    expect(tc().sortAscending, isFalse);
    expect(tc().rows.map((r) => r.name), ['web', 'db', 'api']);
  });

  testWidgets('drag a header divider to resize a column; double-click fits it, again resets', (tester) async {
    final api = TableFakeApi()
      ..onWatch = () => [WatchMessage(type: 'SNAPSHOT', table: fakeTable(deployType, [fakeRow('api'), fakeRow('web')]))];
    final app = await pumpTable(tester, api, deployType, size: const Size(1000, 600));
    double nameWidth() => tester.getSize(find.ancestor(of: find.text('Name').first, matching: find.byType(SizedBox)).first).width;
    final before = nameWidth();

    final handle = find.byKey(const ValueKey('resize-Name'));
    await tester.drag(handle, const Offset(-120, 0));
    await tester.pump();
    expect(nameWidth(), closeTo(before - 120, 2));
    expect(app.tablePrefs.of(deployType.gk).widths['Name'], closeTo(before - 120, 2));

    await tester.drag(handle.hitTestable(), const Offset(-1000, 0));
    await tester.pump();
    expect(nameWidth(), 40, reason: 'has a minimum');

    Future<void> doubleClick() async {
      await tester.tap(handle.hitTestable());
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(handle.hitTestable());
      await tester.pump(const Duration(milliseconds: 400));
    }

    await doubleClick();
    final fitted = app.tablePrefs.of(deployType.gk).widths['Name']!;
    expect(fitted, inInclusiveRange(60, 150), reason: 'fits "api"/"web" and the header, not the minimum');
    expect(nameWidth(), fitted);
    await doubleClick();
    expect(app.tablePrefs.of(deployType.gk).widths, isEmpty);
    await tester.pump(const Duration(seconds: 1));
    expect(api.tablePrefsPuts.last, (deployType.gk, null), reason: 'nothing left to save');
    expect(nameWidth(), before);
  });

  testWidgets('sort, filter and widths are saved, and restored on the next launch', (tester) async {
    final api = TableFakeApi()
      ..onWatch = (() => [WatchMessage(type: 'SNAPSHOT', table: fakeTable(deployType, [fakeRow('api'), fakeRow('web'), fakeRow('db', ns: 'data')]))])
      ..tablePrefs = {
        deployType.gk: {'sortColumn': 'Name', 'sortDescending': true, 'filter': 'namespace=demo', 'widths': {'Name': 200}},
      };
    final app = await pumpTable(tester, api, deployType);
    await app.tablePrefs.load(); // AppState.init does this on connect
    // A fresh table (as after a relaunch) picks them up.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: ResourceTableView(type: deployType))),
    ));
    await tester.pump();
    await tester.pump();
    final tc = Provider.of<TableController>(tester.element(find.byType(ListView).first), listen: false);
    expect(tc.rows.map((r) => r.name), ['web', 'api']);
    expect(find.text('namespace=demo'), findsOneWidget, reason: 'filter box shows it');

    await tester.tap(find.text('Name').first);
    await tester.pump(const Duration(seconds: 1));
    expect(api.tablePrefsPuts.last.$1, deployType.gk);
    expect(api.tablePrefsPuts.last.$2, {'sortColumn': 'Name', 'widths': {'Name': 200.0}, 'filter': 'namespace=demo'});
  });

  testWidgets('drag a header sideways to move the column; back to the default order resets', (tester) async {
    final api = TableFakeApi()
      ..onWatch = (() => [WatchMessage(type: 'SNAPSHOT', table: fakeTable(deployType, [fakeRow('api'), fakeRow('web')]))]);
    final app = await pumpTable(tester, api, deployType, size: const Size(1000, 600));
    final version = app.columnsVersion;

    await tester.drag(find.byKey(const ValueKey('header-Name')), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(api.columnPuts, [['Namespace', 'Name']]);
    expect(app.columnsVersion, version + 1, reason: 'the table reloads with the new order');

    await tester.drag(find.byKey(const ValueKey('header-Name')), const Offset(20, 0));
    await tester.pumpAndSettle();
    expect(api.columnPuts, hasLength(1), reason: 'a nudge that lands in place saves nothing');

    // A move that restores the kind's defaults drops the saved order instead.
    api.columnDefaults = [testColumns[1], testColumns[0]];
    await tester.drag(find.byKey(const ValueKey('header-Name')), const Offset(600, 0));
    await tester.pumpAndSettle();
    expect(api.columnResets, 1);
    expect(api.columnPuts, hasLength(1));
  });
}
