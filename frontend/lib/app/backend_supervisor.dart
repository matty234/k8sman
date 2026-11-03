import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'backend.dart' show BackendStatus;

/// Starts a process; [Process.start] in the app, a fake in tests.
typedef ProcessStarter = Future<Process> Function(String executable, List<String> arguments);

/// Runs the embedded Go backend (`k8sman-server.exe` next to `k8sman.exe`)
/// and keeps it alive. The Dart port of `macos/Runner/BackendSupervisor.swift`,
/// used on Windows; it reports the same status map, so [BackendStatus.fromNative]
/// reads both.
///
/// - Spawned with `--addr 127.0.0.1:0`; the port is learned from the
///   `K8SMAN_LISTENING <addr>` line on stdout.
/// - Spawned with `--exit-on-stdin-eof` and its stdin a pipe held by this
///   process: when the app exits (or is killed) the pipe closes and the
///   backend shuts down cleanly. Windows has no SIGTERM, so [stop] and
///   [restart] close stdin too, then kill after [stopTimeout].
/// - If it crashes it is restarted with exponential backoff (1s, 2s, 4s, …,
///   at most 30s); after [maxQuickFailures] failed starts in a row it stays
///   down until [restart].
class BackendSupervisor {
  final String executable;
  final List<String> extraArgs;
  final int maxQuickFailures;
  final Duration startupTimeout;
  final Duration stopTimeout;
  final int maxLogLines;

  final ProcessStarter _start;
  final Future<void> Function(Duration) _sleep;
  final DateTime Function() _now;

  /// Called whenever the status changes.
  void Function(Map<String, Object?> status)? onChange;

  String _state = 'idle';
  String? _url;
  String? _error;
  final _log = <String>[];
  int _restarts = 0;
  int _failures = 0;
  int _generation = 0;
  bool _stopping = false;
  Process? _process;
  DateTime _startedAt = DateTime.fromMillisecondsSinceEpoch(0);

  BackendSupervisor({
    required this.executable,
    this.extraArgs = const [],
    this.maxQuickFailures = 5,
    this.startupTimeout = const Duration(seconds: 30),
    this.stopTimeout = const Duration(seconds: 3),
    this.maxLogLines = 200,
    ProcessStarter? start,
    Future<void> Function(Duration)? sleep,
    DateTime Function()? now,
  })  : _start = start ?? _defaultStart,
        _sleep = sleep ?? ((d) => Future<void>.delayed(d)),
        _now = now ?? DateTime.now;

  /// The backend shipped next to the running executable.
  factory BackendSupervisor.bundled() {
    final dir = File(Platform.resolvedExecutable).parent.path;
    final name = Platform.isWindows ? 'k8sman-server.exe' : 'k8sman-server';
    return BackendSupervisor(executable: '$dir${Platform.pathSeparator}$name');
  }

  static Future<Process> _defaultStart(String executable, List<String> arguments) {
    final home = Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    return Process.start(executable, arguments, workingDirectory: home);
  }

  /// `http://<addr>` from a `K8SMAN_LISTENING <addr>` line, else null.
  static String? parseListening(String line) {
    const prefix = 'K8SMAN_LISTENING ';
    if (!line.startsWith(prefix)) return null;
    final addr = line.substring(prefix.length).trim();
    return addr.isEmpty ? null : 'http://$addr';
  }

  /// Delay before restart number [failures] (1-based): 1s, 2s, 4s, … ≤ 30s.
  static Duration backoff(int failures) =>
      Duration(seconds: math.min(math.pow(2, math.max(0, failures - 1)).toInt(), 30));

  /// Same keys as the Swift supervisor's status dictionary.
  Map<String, Object?> status() => {
        'state': _state,
        'restarts': _restarts,
        'log': _log.join('\n'),
        'url': ?_url,
        'error': ?_error,
        'pid': ?_process?.pid,
      };

  /// Start the backend if it isn't running yet.
  Future<void> start() async {
    if (const {'idle', 'failed', 'stopped'}.contains(_state)) {
      await _launch();
    } else {
      _publish();
    }
  }

  /// Stop any running backend and start a fresh one now.
  Future<void> restart() async {
    _failures = 0;
    _generation++;
    final p = _process;
    _process = null;
    if (p != null) await _terminate(p);
    await _launch();
  }

  /// Ask the backend to shut down (it stops port-forwards), killing it if it
  /// hasn't exited after [stopTimeout].
  Future<void> stop() async {
    _stopping = true;
    _generation++;
    final p = _process;
    _process = null;
    _url = null;
    if (p != null) await _terminate(p);
    _state = 'stopped';
    _publish();
  }

  void _publish() => onChange?.call(status());

  void _appendLog(String text) {
    _log.addAll(const LineSplitter().convert(text).where((l) => l.isNotEmpty));
    if (_log.length > maxLogLines) _log.removeRange(0, _log.length - maxLogLines);
  }

  Future<void> _launch() async {
    final gen = ++_generation;
    _stopping = false;
    _url = null;
    _state = _restarts > 0 || _failures > 0 ? 'restarting' : 'starting';
    _error = null;
    _publish();

    final Process p;
    try {
      p = await _start(executable, ['--addr', '127.0.0.1:0', '--exit-on-stdin-eof', ...extraArgs]);
    } catch (e) {
      if (gen != _generation) return;
      _state = 'failed';
      _error = e is ProcessException && !File(executable).existsSync()
          ? 'The backend binary (${executable.split(RegExp(r'[\\/]')).last}) is missing next to the app.'
          : 'Could not start the backend: $e';
      _publish();
      return;
    }
    if (gen != _generation) {
      // Restarted or stopped while spawning.
      unawaited(_terminate(p));
      return;
    }
    _process = p;
    _startedAt = _now();
    // A closed pipe (backend gone) must not surface as an unhandled error.
    p.stdin.done.catchError((Object _) {});

    p.stdout.transform(const Utf8Decoder(allowMalformed: true)).transform(const LineSplitter()).listen((line) {
      if (gen != _generation) return;
      final url = parseListening(line);
      if (url == null) {
        _appendLog(line);
        return;
      }
      _url = url;
      _state = 'running';
      _error = null;
      _publish();
    }, onError: (Object _) {});
    p.stderr.transform(const Utf8Decoder(allowMalformed: true)).listen((chunk) {
      _appendLog(chunk);
      // Only push log updates while not healthy, to keep the UI quiet.
      if (_state != 'running' && gen == _generation) _publish();
    }, onError: (Object _) {});
    unawaited(p.exitCode.then((code) => _onExit(p, code, gen)));

    unawaited(_sleep(startupTimeout).then((_) {
      if (gen != _generation || _url != null || _process != p) return;
      _appendLog('k8sman: backend did not report a listening address within ${startupTimeout.inSeconds}s');
      p.kill();
    }));
  }

  Future<void> _onExit(Process p, int code, int gen) async {
    _closeStdin(p);
    if (gen != _generation) return;
    _process = null;
    _url = null;
    if (_stopping) {
      _state = 'stopped';
      _publish();
      return;
    }
    _error = 'The backend exited with status $code.';
    // A backend that ran for a while gets a fresh failure budget.
    if (_now().difference(_startedAt) > const Duration(seconds: 60)) _failures = 0;
    _failures++;
    if (_failures >= maxQuickFailures) {
      _state = 'failed';
      _publish();
      return;
    }
    _restarts++;
    _state = 'restarting';
    _publish();
    await _sleep(backoff(_failures));
    if (gen == _generation && !_stopping) await _launch();
  }

  /// Close stdin (the backend treats EOF like SIGTERM), then kill it if it
  /// is still running after [stopTimeout].
  Future<void> _terminate(Process p) async {
    _closeStdin(p);
    await p.exitCode.timeout(stopTimeout, onTimeout: () {
      p.kill();
      return -1;
    });
  }

  static void _closeStdin(Process p) {
    try {
      p.stdin.close().catchError((Object _) {});
    } catch (_) {
      // Already closed.
    }
  }
}
