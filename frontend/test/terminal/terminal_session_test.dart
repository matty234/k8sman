
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

}
