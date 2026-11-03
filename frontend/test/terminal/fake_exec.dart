import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:k8sman/ui/logs/log_dock_view.dart';
import 'package:k8sman/ui/terminal/exec_protocol.dart';
import 'package:k8sman/ui/terminal/terminal_tab.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';

/// A scripted exec session: tests push events and inspect what was sent.
class FakeExecConnection implements ExecConnection {
  final ExecRequest request;
  final _events = StreamController<ExecEvent>();
  final List<Uint8List> input = [];
  final List<(int, int)> resizes = [];
  bool closed = false;
  FakeExecConnection(this.request);

  void emit(ExecEvent e) => _events.add(e);
  void output(String s) => emit(ExecOutput(utf8.encode(s)));
  String get inputText => utf8.decode([for (final b in input) ...b]);

  @override
  Stream<ExecEvent> get events => _events.stream;
  @override
  void sendInput(Uint8List bytes) => input.add(bytes);
  @override
  void resize(int cols, int rows) => resizes.add((cols, rows));
  @override
  Future<void> close() async {
    closed = true;
    await _events.close();
  }
}

class FakeExecTransport implements ExecTransport {
  final List<FakeExecConnection> connections = [];
  final List<Map<String, String?>> debugRequests = [];
  String debugName = 'debugger';

  FakeExecConnection get last => connections.last;

  @override
  ExecConnection connect(ExecRequest request) {
    final c = FakeExecConnection(request);
    connections.add(c);
    return c;
  }

  @override
  Future<String> createDebugContainer({required String namespace, required String pod, String? targetContainer, required String image}) async {
    debugRequests.add({'namespace': namespace, 'pod': pod, 'target': targetContainer, 'image': image});
    return debugName;
  }
}

/// Renders the dock (as the shell does) with [tabs] open.
Future<(LogDock, AppState)> pumpDock(
  WidgetTester tester, {
  required List<DockTab> tabs,
  Size size = const Size(1000, 420),
  bool readOnly = false,
  Map<ShortcutActivator, VoidCallback> shortcuts = const {},
}) async {
  final api = FakeApiClient();
  final app = AppState(api)
    ..types = testTypes
    ..readOnly = readOnly
    ..currentContext = 'kind-k8sman-dev';
  final dock = LogDock(api);
  for (final t in tabs) {
    dock.add(t);
  }
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [
      Provider<ApiClient>.value(value: api),
      ChangeNotifierProvider<AppState>.value(value: app),
      ChangeNotifierProvider<LogDock>.value(value: dock),
    ],
    child: MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: buildTheme(Brightness.dark),
      home: CallbackShortcuts(
        bindings: shortcuts,
        child: Focus(
          autofocus: true,
          child: Scaffold(body: Column(children: [const Spacer(), LogDockView(maxHeight: size.height - 40)])),
        ),
      ),
    ),
  ));
  await tester.pump();
  return (dock, app);
}

TerminalTab newTab(FakeExecTransport t, {String container = 'nginx'}) =>
    TerminalTab(transport: t, request: ExecRequest(namespace: 'demo', pod: 'web-6fd47b8fcb-442dt', container: container));
