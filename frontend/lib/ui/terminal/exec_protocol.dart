/// Wire protocol and transport for `WS /api/exec` and
/// `POST /api/debug-container` (see API.md). Self-contained so the terminal
/// doesn't depend on (or change) `lib/api/client.dart`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import '../../api/client.dart';

/// Error reasons sent by the backend in `{type:"error", reason}`.
abstract final class ExecReason {
  static const noShell = 'noShell';
  static const commandNotFound = 'commandNotFound';
  static const podNotFound = 'podNotFound';
  static const containerNotFound = 'containerNotFound';
  static const containerNotRunning = 'containerNotRunning';
  static const forbidden = 'forbidden';
  static const execFailed = 'execFailed';

  /// Client-side: the WebSocket couldn't connect or dropped.
  static const connection = 'connection';
}

/// What to run, and where.
class ExecRequest {
  final String namespace;
  final String pod;

  /// Null = the pod's default container.
  final String? container;

  /// An explicit command (exec'd as-is). Null = auto shell selection.
  final List<String>? command;

  /// Preferred shell for auto selection (`auto`, `bash`, `zsh`, ...).
  final String shell;
  final int? cols;
  final int? rows;

  const ExecRequest({required this.namespace, required this.pod, this.container, this.command, this.shell = 'auto', this.cols, this.rows});

  ExecRequest copyWith({String? container, List<String>? command, bool clearCommand = false, String? shell, int? cols, int? rows}) => ExecRequest(
        namespace: namespace,
        pod: pod,
        container: container ?? this.container,
        command: clearCommand ? null : (command ?? this.command),
        shell: shell ?? this.shell,
        cols: cols ?? this.cols,
        rows: rows ?? this.rows,
      );

  /// Query parameters for `/api/exec`. The command goes JSON-encoded so
  /// arguments with spaces survive.
  Map<String, String> toQuery() => {
        'namespace': namespace,
        'pod': pod,
        if (container != null && container!.isNotEmpty) 'container': container!,
        if (command != null && command!.isNotEmpty) 'command': jsonEncode(command),
        if (command == null || command!.isEmpty) 'shell': shell,
        if (cols != null) 'cols': '$cols',
        if (rows != null) 'rows': '$rows',
      };

  Uri uri(Uri base) => base.replace(
        scheme: base.scheme == 'https' ? 'wss' : 'ws',
        path: '/api/exec',
        queryParameters: toQuery(),
      );
}

// ---- frames ------------------------------------------------------------------

sealed class ExecEvent {
  const ExecEvent();
}

/// Terminal output bytes (stdout; the TTY merges stderr).
class ExecOutput extends ExecEvent {
  final Uint8List bytes;
  const ExecOutput(this.bytes);
}

/// The process started; [container] is the resolved container name.
class ExecStarted extends ExecEvent {
  final String container;
  final List<String> command;
  const ExecStarted(this.container, this.command);
}

class ExecExit extends ExecEvent {
  final int code;
  const ExecExit(this.code);
}

class ExecError extends ExecEvent {
  final String reason;
  final String message;
  final int? code;
  const ExecError(this.reason, this.message, {this.code});
}

/// Encoding/decoding of `/api/exec` frames. Binary frames are raw terminal
/// bytes; text frames are JSON control messages.
abstract final class ExecFrames {
  static Uint8List input(String text) => utf8.encode(text);

  static String resize(int cols, int rows) => jsonEncode({'type': 'resize', 'cols': cols, 'rows': rows});

  /// Decodes one WebSocket message. Unknown control frames return null.
  static ExecEvent? decode(Object? message) {
    if (message is Uint8List) return ExecOutput(message);
    if (message is List<int>) return ExecOutput(Uint8List.fromList(message));
    if (message is! String) return null;
    final Map<String, dynamic> j;
    try {
      j = Map<String, dynamic>.from(jsonDecode(message) as Map);
    } catch (_) {
      return null;
    }
    final code = (j['code'] as num?)?.toInt();
    return switch (j['type']) {
      'started' => ExecStarted('${j['container'] ?? ''}', [for (final c in (j['command'] as List? ?? const [])) '$c']),
      'exit' => ExecExit(code ?? 0),
      'error' => ExecError('${j['reason'] ?? ExecReason.execFailed}', '${j['message'] ?? 'exec failed'}', code: code),
      _ => null,
    };
  }
}

// ---- transport -----------------------------------------------------------------

/// A live exec session.
abstract class ExecConnection {
  /// Decoded frames; closes when the socket closes.
  Stream<ExecEvent> get events;
  void sendInput(Uint8List bytes);
  void resize(int cols, int rows);
  Future<void> close();
}

/// Opens exec sessions and creates debug containers. Swap in a fake for tests.
abstract class ExecTransport {
  ExecConnection connect(ExecRequest request);

  /// Adds an ephemeral debug container and waits for it to run. Returns its name.
  Future<String> createDebugContainer({required String namespace, required String pod, String? targetContainer, required String image});
}

/// Builds the transport for an [ApiClient]. Tests may replace this.
ExecTransport Function(ApiClient api) execTransportFor = (api) => WsExecTransport(() => api.base);

class WsExecTransport implements ExecTransport {
  /// Read on every call: the app sets the embedded backend's address at launch.
  final Uri Function() base;
  final http.Client _http;
  WsExecTransport(this.base, {http.Client? httpClient}) : _http = httpClient ?? http.Client();

  @override
  ExecConnection connect(ExecRequest request) => _WsExecConnection(request.uri(base()));

  @override
  Future<String> createDebugContainer({required String namespace, required String pod, String? targetContainer, required String image}) async {
    final res = await _http.post(
      base().replace(path: '/api/debug-container'),
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({'namespace': namespace, 'pod': pod, 'targetContainer': ?targetContainer, 'image': image}),
    );
    final Object? j;
    try {
      j = jsonDecode(res.body);
    } catch (_) {
      throw ApiException(res.statusCode, res.body);
    }
    if (res.statusCode >= 400 || j is! Map) {
      throw ApiException(res.statusCode, j is Map ? '${j['error']}' : res.body, reason: j is Map ? j['reason'] as String? : null);
    }
    return '${j['name']}';
  }
}

class _WsExecConnection implements ExecConnection {
  final WebSocketChannel _ch;
  final _events = StreamController<ExecEvent>();
  bool _closed = false;

  _WsExecConnection(Uri uri) : _ch = WebSocketChannel.connect(uri) {
    _ch.ready.then((_) {}, onError: (Object e) {
      if (!_closed) _add(ExecError(ExecReason.connection, 'Could not connect to the backend: $e'));
    });
    _ch.stream.listen(
      (m) {
        final ev = ExecFrames.decode(m);
        if (ev != null) _add(ev);
      },
      onError: (Object e) {
        if (!_closed) _add(ExecError(ExecReason.connection, '$e'));
      },
      onDone: () {
        // Let a pending handshake error (e.g. 403 in read-only mode) land first.
        Future<void>.delayed(Duration.zero, _events.close);
      },
      cancelOnError: true,
    );
  }

  void _add(ExecEvent e) {
    if (!_events.isClosed) _events.add(e);
  }

  @override
  Stream<ExecEvent> get events => _events.stream;

  @override
  void sendInput(Uint8List bytes) {
    if (!_closed) _ch.sink.add(bytes);
  }

  @override
  void resize(int cols, int rows) {
    if (!_closed) _ch.sink.add(ExecFrames.resize(cols, rows));
  }

  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _ch.sink.close();
  }
}
