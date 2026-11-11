import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'package:xterm/xterm.dart';

import '../../api/client.dart';
import '../../state/dock_tab.dart';
import 'exec_protocol.dart';
import 'sgr_filter.dart';

enum TerminalPhase {
  connecting,
  running,
  exited,
  error,

  /// Creating an ephemeral debug container before attaching.
  startingDebug,
}

/// Defaults applied to new sessions (font size also changes live).
class TerminalSettings {
  static double fontSize = 13;
  static const double minFontSize = 8;
  static const double maxFontSize = 28;

  /// Scrollback lines kept per session. Applies to new sessions.
  static int scrollback = 10000;
  static const scrollbackChoices = [1000, 5000, 10000, 50000];

  static const debugImages = ['busybox:1.36', 'nicolaka/netshoot'];
}

/// Shell choices for the picker. `auto` = zsh → bash → ash → sh.
const terminalShells = ['auto', 'bash', 'zsh', 'ash', 'sh'];

/// One terminal session in a dock tab. Owns the xterm [Terminal] buffer and
/// the exec connection, so it keeps running while its tab is hidden or the
/// dock is collapsed. The dock disposes it (closing the session) on close.
class TerminalTab extends DockTab {
  final ExecTransport transport;
  ExecRequest _request;
  ExecRequest get request => _request;

  late final Terminal terminal;
  final TerminalController controller = TerminalController();

  static int _seq = 0;
  @override
  final String id = 'terminal-${++_seq}';

  TerminalPhase phase = TerminalPhase.connecting;
  int? exitCode;
  String? errorReason;
  String? errorMessage;

  /// Resolved container (the backend picks a default when none was given).
  /// For a local shell: the kube context it was started with.
  String? container;

  /// The command the backend reported starting.
  List<String>? startedCommand;

  /// When set, the session runs in this debug container, targeting
  /// [debugTarget].
  String? debugTarget;

  double fontSize = TerminalSettings.fontSize;

  ExecConnection? _conn;
  StreamSubscription<ExecEvent>? _sub;
  ByteConversionSink? _decoder;
  bool _disposed = false;

  TerminalTab({required this.transport, required ExecRequest request, int? scrollback}) : _request = request {
    container = request.container;
    terminal = Terminal(maxLines: scrollback ?? TerminalSettings.scrollback, platform: terminalPlatform);
    terminal.onOutput = _onTerminalInput;
    terminal.onResize = (w, h, _, _) => _conn?.resize(w, h);
    controller.addListener(notifyListeners); // selection → copy button state
    connect();
  }

  @override
  String get namespace => _request.namespace;
  @override
  String get pod => _request.pod;
  @override
  String get label => isConsole ? (_request.title ?? 'console: $pod') : isLocal ? (_request.title ?? 'local · ${container ?? ''}') : '$pod/${container ?? 'default'}';

  /// A login shell on this machine rather than in a pod.
  bool get isLocal => _request.local;

  /// A KubeVirt VMI serial console (no shell choice, no resize).
  bool get isConsole => _request.console;

  /// What runs: an explicit command or the shell preference.
  String get commandLabel {
    if (isConsole) return 'serial console';
    if (isLocal) {
      final sh = startedCommand?.firstOrNull;
      return sh == null ? 'login shell' : sh.split('/').last;
    }
    final c = _request.command;
    if (c != null && c.isNotEmpty) return c.join(' ');
    return _request.shell == 'auto' ? 'auto shell' : _request.shell;
  }

  bool get isLive => phase == TerminalPhase.running || phase == TerminalPhase.connecting;

  @override
  bool get confirmClose => phase == TerminalPhase.running;

  bool get noShell => phase == TerminalPhase.error && errorReason == ExecReason.noShell;

  bool get hasSelection => controller.selection != null;

  String? get selectedText {
    final sel = controller.selection;
    return sel == null ? null : terminal.buffer.getText(sel);
  }

  // ---- lifecycle ------------------------------------------------------------

  /// (Re)starts the session with the current request.
  void connect() {
    _closeConnection();
    phase = TerminalPhase.connecting;
    exitCode = null;
    errorReason = null;
    errorMessage = null;
    final cols = terminal.viewWidth, rows = terminal.viewHeight;
    final conn = transport.connect(_request.copyWith(cols: cols, rows: rows));
    _conn = conn;
    _decoder = const Utf8Decoder(allowMalformed: true).startChunkedConversion(_TerminalSink(terminal));
    _sub = conn.events.listen(_onEvent, onDone: () {
      if (_conn != conn || _disposed) return;
      if (isLive) _fail(ExecReason.connection, 'Connection closed');
    });
    conn.resize(cols, rows);
    notifyListeners();
  }

  /// Restart, optionally with a different shell or command.
  void restart({String? shell, List<String>? command, bool clearCommand = false}) {
    _request = _request.copyWith(shell: shell, command: command, clearCommand: clearCommand || shell != null);
    // Leave any full-screen app's alternate screen and reset attributes.
    terminal.write('\x1b[0m\x1b[?1049l\x1b[?25h\r\n');
    connect();
  }

  /// Creates an ephemeral debug container targeting the current container
  /// and starts a session in it.
  Future<void> startDebugContainer(String image) async {
    final target = container ?? _request.container;
    _closeConnection();
    phase = TerminalPhase.startingDebug;
    errorReason = null;
    errorMessage = null;
    notifyListeners();
    terminal.write('\x1b[2mStarting debug container ($image)…\x1b[0m\r\n');
    try {
      final name = await transport.createDebugContainer(namespace: namespace, pod: pod, targetContainer: target, image: image);
      if (_disposed) return;
      debugTarget = target;
      container = name;
      _request = _request.copyWith(container: name, clearCommand: true, shell: 'auto');
      terminal.write('\x1b[2mDebug container $name is running; processes of $target are visible (shared PID namespace).\x1b[0m\r\n');
      connect();
    } on ApiException catch (e) {
      if (!_disposed) _fail(ExecReason.execFailed, 'Could not start debug container: ${e.message}');
    } catch (e) {
      if (!_disposed) _fail(ExecReason.execFailed, 'Could not start debug container: $e');
    }
  }

  // ---- I/O ------------------------------------------------------------------

  void _onTerminalInput(String data) {
    if (phase == TerminalPhase.running || phase == TerminalPhase.connecting) {
      _conn?.sendInput(ExecFrames.input(data));
    }
  }

  void _onEvent(ExecEvent e) {
    if (_disposed) return;
    switch (e) {
      case ExecOutput(:final bytes):
        if (phase == TerminalPhase.connecting) {
          phase = TerminalPhase.running;
          notifyListeners();
        }
        _decoder?.add(bytes);
      case ExecStarted(container: final c, :final command):
        container = c;
        startedCommand = command;
        phase = TerminalPhase.running;
        notifyListeners();
      case ExecExit(:final code):
        exitCode = code;
        phase = TerminalPhase.exited;
        terminal.write('\r\n\x1b[0m\x1b[2m[process exited with code $code]\x1b[0m\r\n');
        _closeConnection();
        notifyListeners();
      case ExecError(:final reason, :final message, :final code):
        exitCode = code;
        _fail(reason, message);
    }
  }

  void _fail(String reason, String message) {
    phase = TerminalPhase.error;
    errorReason = reason;
    errorMessage = message;
    _closeConnection();
    notifyListeners();
  }

  /// Font size changes apply live; the view re-measures and sends a resize.
  void setFontSize(double size) {
    fontSize = size.clamp(TerminalSettings.minFontSize, TerminalSettings.maxFontSize);
    TerminalSettings.fontSize = fontSize;
    notifyListeners();
  }

  void paste(String text) {
    terminal.paste(text);
    controller.clearSelection();
  }

  void _closeConnection() {
    _sub?.cancel();
    _sub = null;
    _conn?.close();
    _conn = null;
    _decoder = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _closeConnection();
    controller.removeListener(notifyListeners);
    controller.dispose();
    super.dispose();
  }
}

/// Receives decoded UTF-8 text (multi-byte sequences may span frames).
class _TerminalSink implements Sink<String> {
  final Terminal terminal;
  _TerminalSink(this.terminal);

  /// Rewrites sequences xterm.dart mis-parses (see [SgrFilter]).
  final _filter = SgrFilter();
  @override
  void add(String data) {
    final text = data.isEmpty ? data : _filter.process(data);
    if (text.isNotEmpty) terminal.write(text);
  }

  @override
  void close() {}
}

/// The platform xterm emulates keyboard input for.
TerminalTargetPlatform get terminalPlatform => switch (defaultTargetPlatform) {
      TargetPlatform.windows => TerminalTargetPlatform.windows,
      TargetPlatform.linux => TerminalTargetPlatform.linux,
      _ => TerminalTargetPlatform.macos,
    };
