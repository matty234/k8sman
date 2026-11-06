import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/table_controller.dart';
import 'package:provider/provider.dart';

import 'support/table_fakes.dart';

const names = ['api', 'cache', 'db', 'queue', 'web', 'worker'];

TableController controllerOf(WidgetTester tester) => Provider.of<TableController>(tester.element(find.byType(ListView)), listen: false);

Set<String> selectedNames(WidgetTester tester) => controllerOf(tester).selectedRows.map((r) => r.name).toSet();

Future<void> withKey(WidgetTester tester, LogicalKeyboardKey key, Future<void> Function() body) async {
  await tester.sendKeyDownEvent(key);
  await body();
  await tester.sendKeyUpEvent(key);
}

Future<void> tapRow(WidgetTester tester, String name, {LogicalKeyboardKey? modifier}) async {
  Future<void> tap() async {
    await tester.tap(find.text(name).first);
    await tester.pump();
  }

  modifier == null ? await tap() : await withKey(tester, modifier, tap);
}

Future<void> press(WidgetTester tester, LogicalKeyboardKey key, {LogicalKeyboardKey? modifier}) async {
  if (modifier != null) await tester.sendKeyDownEvent(modifier);
  await tester.sendKeyEvent(key);
  if (modifier != null) await tester.sendKeyUpEvent(modifier);
  await tester.pump();
}

void main() {
  TableFakeApi apiWith(List<String> rows, {ResourceType type = deployType, bool controlled = false}) => TableFakeApi()
    ..onWatch = () => [WatchMessage(type: 'SNAPSHOT', table: fakeTable(type, [for (final n in rows) fakeRow(n, controlled: controlled)]))];

  testWidgets('click, ⌘-click, ⇧-click, ⌘A, Esc and ⇧↓ selection', (tester) async {
    final api = apiWith(names);
    final app = await pumpTable(tester, api, deployType);

    await tapRow(tester, 'cache');
    expect(selectedNames(tester), {'cache'});
    expect(app.detail?.name, 'cache', reason: 'plain click opens the inspector');
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);

    await tapRow(tester, 'queue', modifier: LogicalKeyboardKey.metaLeft);
    expect(selectedNames(tester), {'cache', 'queue'});
    expect(app.detail?.name, 'cache', reason: '⌘-click does not move the inspector');
    expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
    expect(find.text('2 selected'), findsOneWidget);

    // ⇧-click: range from the anchor (the last clicked row) in display order.
    await tapRow(tester, 'cache');
    await tapRow(tester, 'worker', modifier: LogicalKeyboardKey.shiftLeft);
    expect(selectedNames(tester), {'cache', 'db', 'queue', 'web', 'worker'});
    expect(find.text('5 selected'), findsOneWidget);

    // ⌘-click toggles one off.
    await tapRow(tester, 'queue', modifier: LogicalKeyboardKey.metaLeft);
    expect(selectedNames(tester), {'cache', 'db', 'web', 'worker'});

    await press(tester, LogicalKeyboardKey.keyA, modifier: LogicalKeyboardKey.metaLeft);
    expect(selectedNames(tester), names.toSet());

    await press(tester, LogicalKeyboardKey.escape);
    expect(selectedNames(tester), isEmpty);
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);
    expect(app.detail?.name, 'cache', reason: 'Esc clears a multi-selection first');

    // ↓ moves the single selection and the inspector, as before.
    await press(tester, LogicalKeyboardKey.arrowDown);
    expect(app.detail?.name, 'db');
    expect(selectedNames(tester), {'db'});

    // ⇧↓ extends.
    await press(tester, LogicalKeyboardKey.arrowDown, modifier: LogicalKeyboardKey.shiftLeft);
    await press(tester, LogicalKeyboardKey.arrowDown, modifier: LogicalKeyboardKey.shiftLeft);
    expect(selectedNames(tester), {'db', 'queue', 'web'});
    await press(tester, LogicalKeyboardKey.arrowUp, modifier: LogicalKeyboardKey.shiftLeft);
    expect(selectedNames(tester), {'db', 'queue'});

    // A second Esc with ≤1 selected closes the inspector, as before.
    await press(tester, LogicalKeyboardKey.escape);
    await press(tester, LogicalKeyboardKey.escape);
    expect(app.detail, isNull);
  });

  testWidgets('selection survives watch updates; deleted rows drop out', (tester) async {
    final api = apiWith(names);
    await pumpTable(tester, api, deployType);
    await tapRow(tester, 'cache');
    await tapRow(tester, 'db', modifier: LogicalKeyboardKey.metaLeft);
    await tapRow(tester, 'web', modifier: LogicalKeyboardKey.metaLeft);
    expect(selectedNames(tester), {'cache', 'db', 'web'});

    api.watchController!
      ..add(WatchMessage(type: 'MODIFIED', row: fakeRow('db')))
      ..add(WatchMessage(type: 'ADDED', row: fakeRow('blob')));
    await tester.pump();
    expect(selectedNames(tester), {'cache', 'db', 'web'});
    expect(find.text('3 selected'), findsOneWidget);

    api.watchController!.add(WatchMessage(type: 'DELETED', row: fakeRow('db')));
    await tester.pump();
    expect(selectedNames(tester), {'cache', 'web'});

    // A re-list without "web" drops it too: one left, so no bar.
    api.watchController!.add(WatchMessage(type: 'SNAPSHOT', table: fakeTable(deployType, [for (final n in names) if (n != 'web' && n != 'db') fakeRow(n)])));
    await tester.pump();
    expect(selectedNames(tester), {'cache'});
    expect(find.byKey(const ValueKey('selection-bar')), findsNothing);
  });

  testWidgets('⌘A selects only rows the filter shows', (tester) async {
    final api = apiWith(names);
    await pumpTable(tester, api, deployType);
    await tester.enterText(find.byType(TextField).first, 'w');
    await tester.pump();
    await tapRow(tester, 'web');
    await press(tester, LogicalKeyboardKey.keyA, modifier: LogicalKeyboardKey.metaLeft);
    expect(selectedNames(tester), {'web', 'worker'});
    expect(controllerOf(tester).selection, hasLength(2));
  });

  testWidgets('bulk bar offers Restart + Delete for deployments, nothing when read-only', (tester) async {
    final api = apiWith(names);
    await pumpTable(tester, api, deployType);
    await tapRow(tester, 'api');
    await tapRow(tester, 'db', modifier: LogicalKeyboardKey.shiftLeft);
    expect(find.text('3 selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('bulk-Restart')), findsOneWidget);
    expect(find.byKey(const ValueKey('bulk-Delete')), findsOneWidget);
    expect(find.text('Scale'), findsNothing, reason: 'scale is per-object');

    final ro = apiWith(names);
    await pumpTable(tester, ro, deployType, readOnly: true);
    await tapRow(tester, 'api');
    await tapRow(tester, 'db', modifier: LogicalKeyboardKey.shiftLeft);
    expect(find.text('3 selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('bulk-Delete')), findsNothing);

    // Argo CD Applications: refresh runs straight away, for each selected app.
    const appType = ResourceType(group: 'argoproj.io', version: 'v1alpha1', resource: 'applications', kind: 'Application', verbs: ['get', 'list', 'watch', 'patch']);
    final argo = apiWith(names, type: appType);
    await pumpTable(tester, argo, appType);
    await tapRow(tester, 'api');
    await tapRow(tester, 'db', modifier: LogicalKeyboardKey.shiftLeft);
    expect(find.byKey(const ValueKey('bulk-Sync')), findsOneWidget);
    expect(find.byKey(const ValueKey('bulk-Hard refresh')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('bulk-Refresh')));
    await tester.pumpAndSettle();
    expect(argo.actions.where((a) => a.contains('argocd-refresh')), hasLength(3));
  });

  testWidgets('pods with controllers get Restart pods and Delete pods', (tester) async {
    final api = apiWith(['web-1', 'web-2', 'web-3'], type: podType, controlled: true);
    await pumpTable(tester, api, podType);
    await tapRow(tester, 'web-1');
    await press(tester, LogicalKeyboardKey.keyA, modifier: LogicalKeyboardKey.metaLeft);
    expect(find.byKey(const ValueKey('bulk-Restart pods')), findsOneWidget);
    expect(find.byKey(const ValueKey('bulk-Delete pods')), findsOneWidget);
    expect(find.byKey(const ValueKey('bulk-Restart')), findsNothing);
  });

  testWidgets('bulk delete: one confirm listing names, then a partial-failure summary', (tester) async {
    final many = [for (var i = 1; i <= 12; i++) 'svc-${i.toString().padLeft(2, '0')}'];
    final api = apiWith(many)..failures = {'svc-07': 'Operation cannot be fulfilled: the object has been modified'};
    await pumpTable(tester, api, deployType, size: const Size(1200, 900), context: 'prod-eu');
    await tapRow(tester, 'svc-01');
    await press(tester, LogicalKeyboardKey.keyA, modifier: LogicalKeyboardKey.metaLeft);
    expect(find.text('12 selected'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('bulk-Delete')));
    await tester.pump();
    expect(find.text('Delete 12 Deployments?'), findsOneWidget);
    for (final n in many.take(10)) {
      expect(find.text('demo/$n'), findsOneWidget, reason: n);
    }
    expect(find.text('demo/svc-11'), findsNothing);
    expect(find.text('and 2 more'), findsOneWidget);
    expect(find.textContaining('prod-eu'), findsWidgets, reason: 'names the context');
    expect(api.actions, isEmpty, reason: 'nothing runs before confirming');

    await tester.tap(find.text('Delete 12'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 10));
    await tester.pump();
    expect(api.actions, hasLength(12));
    expect(api.actions.every((a) => a.startsWith('delete demo/')), isTrue);
    expect(find.text('Deleted 11, 1 failed'), findsOneWidget);
    expect(find.textContaining('svc-07', findRichText: true), findsWidgets);
    expect(find.textContaining('has been modified', findRichText: true), findsOneWidget);
    expect(find.text('Copy'), findsOneWidget);
  });

  testWidgets('bulk restart shows progress, then a summary snackbar', (tester) async {
    final api = apiWith(names)..actionDelay = const Duration(milliseconds: 100);
    await pumpTable(tester, api, deployType, context: 'kind-dev');
    await tapRow(tester, 'api');
    await press(tester, LogicalKeyboardKey.keyA, modifier: LogicalKeyboardKey.metaLeft);
    await tester.tap(find.byKey(const ValueKey('bulk-Restart')));
    await tester.pump();
    await tester.tap(find.text('Restart 6'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    // 4 at a time: the first batch is done.
    expect(find.text('Restarting 4/6…'), findsWidgets);
    await tester.pump(const Duration(milliseconds: 110));
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.actions, hasLength(6));
    expect(find.text('Restarted 6 Deployments'), findsOneWidget);
  });

  testWidgets('bulk progress toast never outlives the run, even with toasts queued around it', (tester) async {
    final api = apiWith(names)..actionDelay = const Duration(milliseconds: 100);
    await pumpTable(tester, api, deployType, context: 'kind-dev');
    final messenger = ScaffoldMessenger.of(tester.element(find.byType(ListView)));
    // Two toasts already up/queued (e.g. earlier action results): the
    // progress toast used to queue behind the second one, and the run's end
    // removed the wrong toast, leaving "Restarting…" up for a day.
    messenger
      ..showSnackBar(const SnackBar(content: Text('earlier 1')))
      ..showSnackBar(const SnackBar(content: Text('earlier 2')));
    await tester.pump();
    await tapRow(tester, 'api');
    await press(tester, LogicalKeyboardKey.keyA, modifier: LogicalKeyboardKey.metaLeft);
    await tester.tap(find.byKey(const ValueKey('bulk-Restart')));
    await tester.pump();
    await tester.tap(find.text('Restart 6'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 110));
    expect(find.text('Restarting 4/6…'), findsWidgets);
    messenger.showSnackBar(const SnackBar(content: Text('during the run')));
    await tester.pump(const Duration(milliseconds: 110));
    await tester.pump(const Duration(milliseconds: 400));
    expect(api.actions, hasLength(6));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(seconds: 5));
    }
    expect(find.textContaining('Restarting'), findsNothing);
    expect(find.text('during the run'), findsNothing);
    expect(find.text('Restarted 6 Deployments'), findsNothing, reason: 'the summary times out too');
  });

  testWidgets('right-click inside a multi-selection shows the bulk menu', (tester) async {
    final api = apiWith(names);
    await pumpTable(tester, api, deployType);
    await tapRow(tester, 'api');
    await tapRow(tester, 'db', modifier: LogicalKeyboardKey.shiftLeft);
    await tester.tap(find.text('cache'), buttons: kSecondaryButton);
    await tester.pump();
    expect(find.text('3 deployments selected'), findsOneWidget);
    expect(find.text('Restart 3 deployments'), findsOneWidget);
    expect(find.text('Delete 3 deployments…'), findsOneWidget);
    expect(find.text('Copy names'), findsOneWidget);
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();

    // Right-clicking an unselected row behaves as before (single-object menu).
    await tester.tap(find.text('worker'), buttons: kSecondaryButton);
    await tester.pump();
    await tester.pump();
    expect(find.text('Open'), findsOneWidget);
    expect(find.text('3 deployments selected'), findsNothing);
  });

  testWidgets('j/k move the selection, / focuses the filter, y asks for the YAML tab', (tester) async {
    final app = await pumpTable(tester, apiWith(names), deployType);
    final tc = controllerOf(tester);

    await press(tester, LogicalKeyboardKey.keyJ);
    await press(tester, LogicalKeyboardKey.keyJ);
    expect(selectedNames(tester), {'cache'});
    await press(tester, LogicalKeyboardKey.keyK);
    expect(app.detail?.name, 'api');

    await press(tester, LogicalKeyboardKey.keyY);
    expect(app.takeDetailTab(), DetailTab.yaml);

    await press(tester, LogicalKeyboardKey.slash);
    expect(tc.filterFocus.hasFocus, isTrue);
  });
}
