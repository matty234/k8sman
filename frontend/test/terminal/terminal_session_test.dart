import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/terminal/exec_protocol.dart';
import 'package:k8sman/ui/terminal/terminal_session.dart';
import 'package:k8sman/ui/terminal/terminal_tab.dart';

import 'fake_exec.dart';

/// Stream events land in a microtask after the frame; pump once more to render them.
Future<void> flush(WidgetTester tester) async {
  await tester.pump();
  await tester.pump();
}

String screenText(TerminalTab t) => [for (var i = 0; i < t.terminal.buffer.lines.length; i++) t.terminal.buffer.lines[i].toString()].join('\n');

void main() {
  testWidgets('output renders into the terminal buffer (UTF-8 split across frames)', (tester) async {
    final transport = FakeExecTransport();
    final tab = newTab(transport);
    await pumpDock(tester, tabs: [tab]);
    final c = transport.last;
    c.emit(const ExecStarted('nginx', ['/bin/sh']));
    c.output('hello \x1b[32mworld\x1b[0m\r\n');
    // "é" split over two frames must still decode.
    c.emit(ExecOutput(Uint8List.fromList([0x63, 0x61, 0x66, 0xC3])));
    c.emit(ExecOutput(Uint8List.fromList([0xA9, 0x0D, 0x0A])));
    await flush(tester);
    expect(tab.phase, TerminalPhase.running);
    expect(screenText(tab), contains('hello world'));
    expect(screenText(tab), contains('café'));
    expect(find.byKey(const ValueKey('terminal-view')), findsOneWidget);
    expect(find.textContaining('connected'), findsOneWidget);
    tab.dispose();
  });

  testWidgets('typed input is sent as binary frames', (tester) async {
    final transport = FakeExecTransport();
    final tab = newTab(transport);
    await pumpDock(tester, tabs: [tab]);
    final c = transport.last;
    c.emit(const ExecStarted('nginx', ['/bin/sh']));
    await flush(tester);
    await tester.tap(find.byKey(const ValueKey('terminal-view')));
    await tester.pump(const Duration(milliseconds: 500)); // let the double-tap timer lapse
    tester.testTextInput.enterText('ls');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
    await flush(tester);
    expect(c.inputText, contains('ls'));
    expect(c.inputText, contains('\r'));
    expect(c.inputText, contains('\x1b[A'));
    tab.dispose();
  });

  testWidgets('resize sends a control frame with the view size', (tester) async {
    final transport = FakeExecTransport();
    final tab = newTab(transport);
    await pumpDock(tester, tabs: [tab], size: const Size(1000, 420));
    final c = transport.last;
    expect(c.resizes, isNotEmpty);
    final first = c.resizes.last;
    expect(first, (tab.terminal.viewWidth, tab.terminal.viewHeight));
    expect(first.$1, greaterThan(60)); // ~1000px of 13pt cells (test font)

    tester.view.physicalSize = const Size(600, 420);
    await flush(tester);
    final second = c.resizes.last;
    expect(second.$1, lessThan(first.$1));
    expect(second, (tab.terminal.viewWidth, tab.terminal.viewHeight));
    tab.dispose();
  });

  testWidgets('exit shows the ended state; Restart session reconnects', (tester) async {
    final transport = FakeExecTransport();
    final tab = newTab(transport);
    await pumpDock(tester, tabs: [tab]);
    transport.last
      ..emit(const ExecStarted('nginx', ['/bin/sh']))
      ..emit(const ExecExit(3));
    await flush(tester);
    expect(tab.phase, TerminalPhase.exited);
    expect(find.text('Session ended · exit code 3'), findsOneWidget);
    expect(screenText(tab), contains('[process exited with code 3]'));
    expect(transport.last.closed, isTrue);

    await tester.tap(find.byKey(const ValueKey('terminal-restart-session')));
    await flush(tester);
    expect(transport.connections, hasLength(2));
    expect(tab.phase, TerminalPhase.connecting);
    expect(find.byKey(const ValueKey('terminal-state-banner')), findsNothing);
    tab.dispose();
  });

  testWidgets('no shell offers a debug container; confirming creates it and execs into it', (tester) async {
    final transport = FakeExecTransport();
    final tab = newTab(transport, container: 'pause');
    await pumpDock(tester, tabs: [tab], size: const Size(1000, 800)); // room for the confirm dialog
    transport.last.emit(const ExecError(ExecReason.noShell, 'stat /bin/sh: no such file or directory'));
    await flush(tester);
    expect(tab.noShell, isTrue);
    expect(find.text('No shell in container pause'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('terminal-start-debug')));
    await tester.pumpAndSettle();
    // The confirmation explains the pod spec change and offers images.
    expect(find.textContaining('cannot be undone'), findsOneWidget);
    expect(find.text('nicolaka/netshoot'), findsOneWidget);
    await tester.tap(find.text('nicolaka/netshoot'));
    await flush(tester);
    await tester.tap(find.widgetWithText(FilledButton, 'Start debug container'));
    await tester.pumpAndSettle();
    expect(transport.debugRequests.single, {'namespace': 'demo', 'pod': 'web-6fd47b8fcb-442dt', 'target': 'pause', 'image': 'nicolaka/netshoot'});
    expect(transport.connections, hasLength(2));
    expect(transport.last.request.container, 'debugger');
    expect(tab.debugTarget, 'pause');
    tab.dispose();
  });

  testWidgets('read-only hides the debug container button', (tester) async {
    final transport = FakeExecTransport();
    final tab = newTab(transport, container: 'pause');
    await pumpDock(tester, tabs: [tab], readOnly: true);
    transport.last.emit(const ExecError(ExecReason.noShell, 'no /bin/sh'));
    await flush(tester);
    expect(find.byKey(const ValueKey('terminal-start-debug')), findsNothing);
    tab.dispose();
  });

  testWidgets('focused terminal keeps plain keys from app shortcuts but lets ⌘J through', (tester) async {
    final transport = FakeExecTransport();
    final tab = newTab(transport);
    var plain = 0, cmdJ = 0;
    await pumpDock(tester, tabs: [tab], shortcuts: {
      const SingleActivator(LogicalKeyboardKey.keyJ): () => plain++,
      const SingleActivator(LogicalKeyboardKey.keyJ, meta: true): () => cmdJ++,
    });
    transport.last.emit(const ExecStarted('nginx', ['/bin/sh']));
    await flush(tester);
    await tester.tap(find.byKey(const ValueKey('terminal-view')));
    await tester.pump(const Duration(milliseconds: 500)); // let the double-tap timer lapse
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    expect(plain, 0);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyJ);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    expect(cmdJ, 1);
    tab.dispose();
  });

  testWidgets('dock: terminal tab has its own icon and asks before closing a running session', (tester) async {
    final transport = FakeExecTransport();
    final tab = newTab(transport);
    final (dock, _) = await pumpDock(tester, tabs: [tab]);
    transport.last.emit(const ExecStarted('nginx', ['/bin/sh']));
    await flush(tester);
    expect(find.byKey(const ValueKey('dock-alerts-tab')), findsOneWidget); // the strip's fixed first tab
    expect(find.descendant(of: find.byKey(ValueKey('dock-tab-${tab.id}')), matching: find.byIcon(Icons.terminal)), findsOneWidget);

    // Collapsing keeps the session alive.
    dock.setCollapsed(true);
    await flush(tester);
    expect(find.byType(TerminalSession), findsNothing);
    expect(transport.last.closed, isFalse);
    dock.setCollapsed(false);
    await flush(tester);

    await tester.tap(find.byKey(ValueKey('dock-tab-close-${tab.id}')));
    await tester.pumpAndSettle();
    expect(find.text('End the terminal session?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(dock.tabs, [tab]);

    await tester.tap(find.byKey(ValueKey('dock-tab-close-${tab.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('confirm-close-terminal')));
    await tester.pumpAndSettle();
    expect(dock.tabs, isEmpty);
    expect(transport.last.closed, isTrue);
  });

  test('frames round-trip through the tab', () async {
    final transport = FakeExecTransport();
    final tab = newTab(transport);
    tab.terminal.textInput('pwd');
    expect(utf8.decode(transport.last.input.expand((b) => b).toList()), 'pwd');
    tab.dispose();
  });

  testWidgets('dock + opens a local shell tab labelled with its context', (tester) async {
    final transport = FakeExecTransport();
    final old = execTransportFor;
    execTransportFor = (_) => transport;
    addTearDown(() => execTransportFor = old);
    final (dock, _) = await pumpDock(tester, tabs: const [], readOnly: true);

    await tester.tap(find.byKey(const ValueKey('dock-new-local-shell')));
    await flush(tester);
    final tab = dock.activeTab! as TerminalTab;
    expect(tab.isLocal, isTrue, reason: 'allowed in read-only mode: the backend prints a notice instead');
    expect(transport.last.request.local, isTrue);
    transport.last.emit(const ExecStarted('kind-dev', ['/bin/zsh', '-l']));
    transport.last.output('% ');
    await flush(tester);
    expect(tab.label, 'local · kind-dev');
    expect(tab.commandLabel, 'zsh');
    final tabChip = find.byKey(ValueKey('dock-tab-${tab.id}'));
    expect(find.descendant(of: tabChip, matching: find.byIcon(Icons.laptop_mac)), findsOneWidget);
    expect(find.descendant(of: tabChip, matching: find.textContaining('local')), findsOneWidget);
    expect(find.byKey(const ValueKey('terminal-shell-picker')), findsNothing, reason: 'no pod shell choices');
    expect(find.textContaining('kubectl → kind-dev'), findsOneWidget);
    dock.closeAll();
    await tester.pump();
  });
}
