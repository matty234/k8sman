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
