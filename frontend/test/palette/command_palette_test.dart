import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/palette/command_palette.dart';
import 'package:k8sman/ui/palette/palette_sources.dart';
import 'package:k8sman/ui/terminal/exec_protocol.dart';

import '../support/fixture_api.dart';
import '../terminal/fake_exec.dart';

/// Serves the by-name lookup lists from the fixtures.
class _Api extends FixtureApi {
  final List<String> tables = [];

  @override
  Future<TableData> table(ResourceRef r, {String? namespace, String? labelSelector, String? fieldSelector, bool includeObject = false}) async {
    tables.add(r.key);
    final file = switch (r.key) { 'pods' => 'api-table-pods.json', 'deployments.apps' => 'api-table-deployments.json', _ => null };
    if (file == null) throw ApiException(403, 'forbidden');
    return TableData.fromJson(fixture(file));
  }
}

final _search = find.byKey(const ValueKey('palette-search'));

Future<void> _pump(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _cmd(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await _pump(tester);
}

/// ⌘K, type [query], Enter.
Future<void> _go(WidgetTester tester, String query) async {
  await _cmd(tester, LogicalKeyboardKey.keyK);
  expect(_search, findsOneWidget);
  await tester.enterText(_search, query);
  await _pump(tester);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await _pump(tester);
  expect(_search, findsNothing);
}

void main() {
  setUp(PaletteObjectCache.clear);

  testWidgets('⌘K opens the palette; Enter goes to an object, a kind, an object of another kind, a page', (tester) async {
    final api = _Api();
    final (app, _) = await pumpShell(tester, api);
    await _pump(tester);
    expect(app.selectedType?.kind, 'Pod');

    // The sidebar's search button opens it too (and shows the shortcut).
    expect(find.text('⌘K'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('palette-launcher')));
    await _pump(tester);
    expect(_search, findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _pump(tester);

    // Esc and a second ⌘K both close it; ⌘P is an alias.
    await _cmd(tester, LogicalKeyboardKey.keyK);
    expect(_search, findsOneWidget);
    expect(find.text('Overview'), findsWidgets); // pages listed before typing
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await _pump(tester);
    expect(_search, findsNothing);
    await _cmd(tester, LogicalKeyboardKey.keyP);
    expect(_search, findsOneWidget);
    await _cmd(tester, LogicalKeyboardKey.keyK);
    expect(_search, findsNothing);

    // A row of the table on screen opens in the inspector.
    await _go(tester, 'crashy');
    expect(app.detail?.name, 'crashy');
    expect(app.detail?.type.kind, 'Pod');

    // A kind, by its short name: shows its table.
    await _go(tester, 'deploy');
    expect(app.view, MainView.resources);
    expect(app.selectedType?.kind, 'Deployment');

    // Pods are no longer on screen: found by the lookup across common kinds.
    await _cmd(tester, LogicalKeyboardKey.keyK);
    await tester.enterText(_search, 'rds0');
    await _pump(tester);
    expect(api.tables, contains('pods'));
    expect(find.text('Pod'), findsWidgets); // the result's type label
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _pump(tester);
    expect(app.detail?.name, 'redis-0');
    expect(app.detail?.type.kind, 'Pod');

    // Arrow keys move through results; a page.
    await _cmd(tester, LogicalKeyboardKey.keyK);
    await tester.enterText(_search, 'nodes');
    await _pump(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await _pump(tester);
    expect(app.view, MainView.nodes);
  });

  testWidgets('⌘K in a focused terminal clears it instead of opening the palette', (tester) async {
    final transport = FakeExecTransport();
    final tab = newTab(transport);
    var opened = 0;
    await pumpDock(tester, tabs: [tab], shortcuts: {for (final a in commandPaletteShortcuts) a: () => opened++});
    transport.last.emit(const ExecStarted('nginx', ['/bin/sh']));
    await _pump(tester);
    await tester.tap(find.byKey(const ValueKey('terminal-view')));
    await tester.pump(const Duration(milliseconds: 500)); // let the double-tap timer lapse
    await _cmd(tester, LogicalKeyboardKey.keyK);
    expect(opened, 0);
    expect(transport.last.inputText, contains('\x0c')); // clear asks the shell to redraw
    // ⌘P still reaches the app.
    await _cmd(tester, LogicalKeyboardKey.keyP);
    expect(opened, 1);
    tab.dispose();
  });
}
