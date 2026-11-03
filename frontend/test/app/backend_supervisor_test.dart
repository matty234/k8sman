import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/app/backend_supervisor.dart';

/// A backend process driven by the test. Closing its stdin makes it exit 0,
/// like `k8sman-server --exit-on-stdin-eof`.
class FakeProcess implements Process {
  final _out = StreamController<List<int>>();
  final _err = StreamController<List<int>>();
  final _exit = Completer<int>();
  final _in = StreamController<List<int>>();
  late final IOSink _sink = IOSink(_in.sink);

  FakeProcess() {
    _in.stream.listen((_) {}, onDone: () => exit(0));
  }

  void say(String line) => _out.add(utf8.encode('$line\n'));
  void exit(int code) {
    if (!_exit.isCompleted) _exit.complete(code);
  }

  @override
  Stream<List<int>> get stdout => _out.stream;
  @override
  Stream<List<int>> get stderr => _err.stream;
  @override
  IOSink get stdin => _sink;
  @override
  Future<int> get exitCode => _exit.future;
  @override
  int get pid => 42;
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    exit(-1);
    return true;
  }
}

void main() {
  late List<FakeProcess> spawned;
  late List<List<String>> args;
  late List<Duration> delays;
  late List<Map<String, Object?>> updates;

  BackendSupervisor make() {
    spawned = [];
    args = [];
    delays = [];
    updates = [];
    const timeout = Duration(seconds: 30);
    return BackendSupervisor(
      executable: 'k8sman-server.exe',
      startupTimeout: timeout,
      start: (exe, a) async {
        args.add(a);
        return (spawned..add(FakeProcess())).last;
      },
      // Backoff delays return at once; the startup timeout never fires.
      sleep: (d) {
        if (d == timeout) return Completer<void>().future;
        delays.add(d);
        return Future.value();
      },
    )..onChange = updates.add;
  }

  Future<void> settle() => Future.delayed(Duration.zero);

  test('parses the listening line and backs off exponentially', () {
    expect(BackendSupervisor.parseListening('K8SMAN_LISTENING 127.0.0.1:51234'), 'http://127.0.0.1:51234');
    expect(BackendSupervisor.parseListening('K8SMAN_LISTENING [::1]:80 '), 'http://[::1]:80');
    expect(BackendSupervisor.parseListening('2026/01/01 k8sman-server started'), isNull);
    expect([for (var i = 1; i <= 7; i++) BackendSupervisor.backoff(i).inSeconds], [1, 2, 4, 8, 16, 30, 30]);
  });

  test('reports running, restarts a crash, gives up after max failures, and Retry starts afresh', () async {
    final sup = make();
    await sup.start();
    expect(args.single, containsAll(['--addr', '127.0.0.1:0', '--exit-on-stdin-eof']));
    expect(sup.status()['state'], 'starting');

    spawned.last.say('k8sman-server kubeconfig=x');
    spawned.last.say('K8SMAN_LISTENING 127.0.0.1:50000');
    await settle();
    expect(sup.status(), containsPair('url', 'http://127.0.0.1:50000'));
    expect(sup.status()['state'], 'running');
    expect(sup.status()['log'], 'k8sman-server kubeconfig=x');

    // Every start fails: 1s, 2s, 4s, 8s backoff, then it stays down.
    for (var i = 0; i < 5; i++) {
      spawned.last.exit(1);
      await settle();
      await settle();
    }
    expect(spawned, hasLength(5));
    expect(delays, [for (final s in [1, 2, 4, 8]) Duration(seconds: s)]);
    expect(sup.status()['state'], 'failed');
    expect(sup.status()['error'], 'The backend exited with status 1.');
    expect(sup.status()['restarts'], 4);
    expect(updates.map((u) => u['state']), contains('restarting'));

    await sup.restart();
    expect(spawned, hasLength(6));
    expect(sup.status()['state'], 'restarting');
    spawned.last.say('K8SMAN_LISTENING 127.0.0.1:50001');
    await settle();
    expect(sup.status()['url'], 'http://127.0.0.1:50001');
  });

  test('stop closes stdin and does not restart', () async {
    final sup = make();
    await sup.start();
    final p = spawned.single;
    await sup.stop();
    expect(await p.exitCode, 0, reason: 'exited on stdin EOF, not killed');
    await settle();
    expect(sup.status()['state'], 'stopped');
    expect(spawned, hasLength(1));
  });
}
