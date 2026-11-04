import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import 'backend_supervisor.dart';

/// Lifecycle of the backend process.
enum BackendPhase {
  /// Waiting for the embedded backend to report its address.
  starting,

  /// Listening; [BackendStatus.url] is set.
  running,

  /// Crashed and being restarted with backoff.
  restarting,

  /// Gave up restarting (or could not start); needs Retry.
  failed,

  /// Using a backend we didn't spawn (`--dart-define=K8SMAN_BACKEND=…`,
  /// or platforms without an embedded backend).
  external,
}

class BackendStatus {
  final BackendPhase phase;
  final String? url;

  /// Bearer token of the backend at [url] (per launch). Never log it.
  final String? token;
  final String? error;

  /// Tail of the backend's stderr/stdout.
  final String log;
  final int restarts;
  const BackendStatus(this.phase, {this.url, this.token, this.error, this.log = '', this.restarts = 0});

  bool get isReady => phase == BackendPhase.running || phase == BackendPhase.external;

  static BackendStatus fromNative(Map<Object?, Object?> m) {
    final phase = switch (m['state']) {
      'running' => BackendPhase.running,
      'restarting' => BackendPhase.restarting,
      'failed' || 'stopped' => BackendPhase.failed,
      _ => BackendPhase.starting,
    };
    return BackendStatus(
      phase,
      url: m['url'] as String?,
      token: m['token'] as String?,
      error: m['error'] as String?,
      log: (m['log'] as String?) ?? '',
      restarts: (m['restarts'] as int?) ?? 0,
    );
  }
}

/// Owns the connection to the backend. In the macOS app it asks the native
/// side (`BackendSupervisor.swift`, channel `k8sman/backend`) to spawn and
/// supervise the embedded `k8sman-server`; on Windows the Dart
/// [BackendSupervisor] does the same. Either way it points [api] at whatever
/// port is reported. [onReady] runs on first connect and after every restart (the
/// port changes), so the app can reload.
class BackendController extends ChangeNotifier {
  static const _channel = MethodChannel('k8sman/backend');

  final ApiClient api;
  final FutureOr<void> Function()? onReady;

  BackendStatus status = const BackendStatus(BackendPhase.starting);
  String? _connectedUrl;
  String? _connectedToken;

  /// Reads the token of an external backend started by hand (`make
  /// backend` writes it to [devTokenPath]). Replaceable in tests.
  String? Function() readDevToken = readDevTokenFile;

  /// True once the backend has been reachable at least once.
  bool everReady = false;

  /// Supervises the backend from Dart (Windows); null when the native side
  /// does it (macOS) or there is no embedded backend.
  BackendSupervisor? supervisor;

  BackendController(this.api, {this.onReady, this.supervisor});

  /// Whether this build spawns its own backend: the macOS and Windows apps,
  /// unless a backend URL was given with `--dart-define=K8SMAN_BACKEND=…`.
  static bool get embedded =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.windows) &&
      ApiClient.definedBackend.isEmpty;

  Future<void> start() async {
    if (!embedded) return _useExternal();
    if (defaultTargetPlatform == TargetPlatform.windows) {
      final sup = supervisor ??= BackendSupervisor.bundled();
      sup.onChange = (m) => _apply(BackendStatus.fromNative(m));
      return sup.start();
    }
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'status' && call.arguments is Map) _apply(BackendStatus.fromNative(call.arguments as Map));
      return null;
    });
    try {
      final s = await _channel.invokeMethod<Map<Object?, Object?>>('start');
      if (s != null) _apply(BackendStatus.fromNative(s));
    } on MissingPluginException {
      // Not running inside the macOS runner (e.g. tests): use the default URL.
      await _useExternal();
    }
  }

  /// Kill and respawn the embedded backend (or just reconnect to an external one).
  Future<void> retry() async {
    if (!embedded || status.phase == BackendPhase.external) {
      _connectedUrl = null;
      return _useExternal();
    }
    status = BackendStatus(BackendPhase.starting, log: status.log, restarts: status.restarts);
    notifyListeners();
    final sup = supervisor;
    if (sup != null) return sup.restart();
    await _channel.invokeMethod<void>('restart');
  }

  /// An external backend's token: `--dart-define=K8SMAN_TOKEN=…`, else the
  /// dev-token file (re-read on every retry: the server writes a new one
  /// each time it starts), else whatever [api] already has.
  Future<void> _useExternal() async {
    final token = ApiClient.definedToken.isNotEmpty ? ApiClient.definedToken : (readDevToken() ?? api.token);
    _apply(BackendStatus(BackendPhase.external, url: api.base.toString(), token: token));
  }

  void _apply(BackendStatus s) {
    status = s;
    final url = s.url;
    // A restart may reuse the port, but always brings a new token.
    final connect = s.isReady && url != null && (url != _connectedUrl || s.token != _connectedToken);
    if (connect) {
      _connectedUrl = url;
      _connectedToken = s.token;
      api.base = Uri.parse(url);
      api.token = s.token;
      everReady = true;
    }
    notifyListeners();
    if (connect) onReady?.call();
  }
}

/// `~/.config/k8sman/dev-token` (`%USERPROFILE%\.config\k8sman\dev-token` on
/// Windows), where a backend started without `K8SMAN_AUTH_TOKEN` writes the
/// token it generated (`devTokenPath` in backend/cmd/k8sman-server).
String? devTokenPath([Map<String, String>? env]) {
  final e = env ?? Platform.environment;
  final home = Platform.isWindows ? (e['USERPROFILE'] ?? e['HOME']) : (e['HOME'] ?? e['USERPROFILE']);
  if (home == null || home.isEmpty) return null;
  final sep = Platform.pathSeparator;
  return [home, '.config', 'k8sman', 'dev-token'].join(sep);
}

/// The token in [devTokenPath], or null when there is none.
String? readDevTokenFile([String? path]) {
  final p = path ?? devTokenPath();
  if (p == null) return null;
  try {
    final t = File(p).readAsStringSync().trim();
    return t.isEmpty ? null : t;
  } on FileSystemException {
    return null;
  }
}

/// Shows backend startup and failure states in front of [child]. Before the
/// first connection it replaces [child]; after that a crash shows a banner
/// over it, so the UI keeps its state while the backend restarts.
class BackendGate extends StatelessWidget {
  final Widget child;
  const BackendGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final backend = context.watch<BackendController?>();
    if (backend == null) return child;
    final s = backend.status;
    if (!backend.everReady) {
      return s.isReady ? child : Scaffold(body: WindowDragArea(child: _StartupView(status: s, onRetry: backend.retry)));
    }
    return Stack(children: [
      child,
      if (!s.isReady)
        Positioned(
          left: 0,
          right: 0,
          bottom: 16,
          child: Center(child: _CrashBanner(status: s, onRetry: backend.retry)),
        ),
    ]);
  }
}

class _StartupView extends StatelessWidget {
  final BackendStatus status;
  final VoidCallback onRetry;
  const _StartupView({required this.status, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = status.phase == BackendPhase.failed;
    if (!failed) {
      return Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(height: 14),
          Text(status.phase == BackendPhase.restarting ? 'Restarting backend…' : 'Starting backend…',
              style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor)),
          if (status.phase == BackendPhase.restarting && status.error != null) ...[
            const SizedBox(height: 6),
            Text(status.error!, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ],
        ]),
      );
    }
    return Center(
      child: SizedBox(
        width: 620,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('The k8sman backend could not start', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          if (status.error != null) InlineMessage(status.error!, isError: true),
          if (status.log.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('Backend output', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            const SizedBox(height: 4),
            _LogTail(status.log),
          ],
          const SizedBox(height: 16),
          Row(children: [
            FilledButton(onPressed: onRetry, child: const Text('Retry')),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => Clipboard.setData(ClipboardData(text: '${status.error ?? ''}\n\n${status.log}')),
              child: const Text('Copy details'),
            ),
          ]),
        ]),
      ),
    );
  }
}

class _LogTail extends StatelessWidget {
  final String log;
  const _LogTail(this.log);

  @override
  Widget build(BuildContext context) {
    final lines = log.trimRight().split('\n');
    final tail = lines.length > 40 ? lines.sublist(lines.length - 40) : lines;
    return Container(
      constraints: const BoxConstraints(maxHeight: 260),
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: SingleChildScrollView(
        reverse: true,
        child: SelectableText(tail.join('\n'), style: monoStyle(context, size: 11)),
      ),
    );
  }
}

class _CrashBanner extends StatelessWidget {
  final BackendStatus status;
  final VoidCallback onRetry;
  const _CrashBanner({required this.status, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final failed = status.phase == BackendPhase.failed;
    return Material(
      elevation: 6,
      borderRadius: BorderRadius.circular(8),
      color: theme.colorScheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 8, 8),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (failed)
            Icon(Icons.error_outline, size: 16, color: theme.colorScheme.error)
          else
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 520),
            child: Text(
              failed
                  ? 'Backend stopped: ${status.error ?? 'unknown error'}'
                  : 'Backend ${status.error != null ? '${status.error!.replaceFirst('The backend ', '').replaceAll('.', '')}; ' : ''}restarting…',
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.bodyMedium,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(onPressed: onRetry, child: Text(failed ? 'Retry' : 'Restart now')),
        ]),
      ),
    );
  }
}
