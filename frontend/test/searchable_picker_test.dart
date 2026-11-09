import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';

import 'support/table_fakes.dart';

final search = find.byKey(const ValueKey('picker-search'));

Future<AppState> pumpWithNamespaces(WidgetTester tester, List<String> namespaces) async {
  final api = TableFakeApi()
    ..namespaceList = namespaces
    ..onWatch = () => [WatchMessage(type: 'SNAPSHOT', table: fakeTable(podType, [fakeRow('web')]))];
  return pumpTable(tester, api, podType);
}

Future<void> openPicker(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('namespace-picker')).first);
  await tester.pump();
}

Iterable<String> visibleOptions(WidgetTester tester) => tester
    .widgetList<Text>(find.descendant(
        of: find.byWidgetPredicate((w) => w.key is ValueKey && '${(w.key as ValueKey).value}'.startsWith('picker-option-')),
        matching: find.byType(Text)))
    .map((t) => t.textSpan?.toPlainText() ?? t.data ?? '');

void main() {
  testWidgets('opens instantly with the search field focused; filters case-insensitively with highlight', (tester) async {
    final app = await pumpWithNamespaces(tester, ['default', 'kube-system', 'kube-public', 'payments', 'Kubeflow']);
    await openPicker(tester);
    expect(search, findsOneWidget);
    // The table body holds focus, so the field's focus border animates in; it must then settle.
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
    final field = tester.widget<EditableText>(find.descendant(of: search, matching: find.byType(EditableText)));
    expect(field.focusNode.hasFocus, isTrue);
    expect(find.text('All namespaces'), findsWidgets);

    await tester.enterText(search, 'KUBE');
    await tester.pump();
    final shown = visibleOptions(tester).toList();
    expect(shown, ['All namespaces', 'kube-system', 'kube-public', 'Kubeflow']);
    // The match is highlighted (its own bold span; the checkbox icon is the
    // row's first RichText, the hover star its last).
    final rich = tester.widget<RichText>(find.descendant(of: find.byKey(const ValueKey('picker-option-1')), matching: find.byType(RichText)).at(1));
    final spans = (rich.text as TextSpan).children!.first as TextSpan;
    final hl = spans.children!.whereType<TextSpan>().firstWhere((s) => s.style?.fontWeight == FontWeight.w700);
    expect(hl.text, 'kube');

    // Enter takes the first match.
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(search, findsNothing);
    expect(app.namespace, 'kube-system');
  });

  testWidgets('↑/↓ move, Enter selects, Esc closes', (tester) async {
    final app = await pumpWithNamespaces(tester, ['alpha', 'beta', 'gamma']);
    await openPicker(tester);
    // Starts on the current choice (All namespaces).
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(app.namespace, 'beta');

    await openPicker(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();
    expect(search, findsNothing);
    expect(app.namespace, 'beta', reason: 'Esc changes nothing');
  });

}
