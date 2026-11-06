import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';

import 'support/table_fakes.dart';

void main() {
  testWidgets('ticking two namespaces in the picker shows exactly their rows', (tester) async {
    final rows = [fakeRow('web', ns: 'default'), fakeRow('api', ns: 'demo'), fakeRow('dns', ns: 'kube-system')];
    final api = TableFakeApi();
    // The fake answers each watch with the rows of the scope it was asked for.
    api.onWatch = () => [
          WatchMessage(type: 'SNAPSHOT', table: fakeTable(podType, [for (final r in rows) if (api.lastWatchScope!.contains(r.namespace)) r])),
        ];
    final app = await pumpTable(tester, api, podType);
    expect(find.text('dns'), findsOneWidget, reason: 'all namespaces to start with');

    await tester.tap(find.byKey(const ValueKey('namespace-picker')));
    await tester.pump();
    Future<void> tick(String ns) async {
      final row = find.ancestor(of: find.text(ns), matching: find.byWidgetPredicate((w) => '${w.key}'.contains('picker-option-')));
      await tester.tap(find.descendant(of: row, matching: find.byKey(const ValueKey('picker-checkbox'))));
      await tester.pump();
    }

    await tick('demo');
    await tick('kube-system');
    // Checkboxes leave the popover open; Esc closes it.
    expect(find.byKey(const ValueKey('picker-search')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    await tester.pump();

    expect(app.namespaceScope, NamespaceScope.of(['kube-system', 'demo']));
    expect(app.namespace, isNull, reason: 'no single namespace for call sites that need one');
    expect(api.lastWatchScope, NamespaceScope.of(['demo', 'kube-system']));
    expect(find.text('api'), findsOneWidget);
    expect(find.text('dns'), findsOneWidget);
    expect(find.text('web'), findsNothing);
    expect(find.text('demo, kube-system'), findsOneWidget, reason: 'the picker button names the set');
  });
}
