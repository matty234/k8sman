import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';

/// A loopback WebSocket server that counts open sockets and records queries.
class _Server {
  late HttpServer http;
  int opened = 0, closed = 0;
  final queries = <Map<String, String>>[];
  final List<Object> frames;
  _Server(this.frames);

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      queries.add(req.uri.queryParameters);
      final ws = await WebSocketTransformer.upgrade(req);
      opened++;
      ws.listen((_) {}, onDone: () => closed++);
      for (final f in frames) {
        ws.add(f is String ? f : jsonEncode(f));
      }
    });
  }

  Uri get base => Uri.parse('http://127.0.0.1:${http.port}');

  Future<void> until(bool Function() cond) async {
    for (var i = 0; i < 200 && !cond(); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  }
}

const _ref = ResourceRef(group: 'apps', resource: 'deployments');

void main() {
  test('watch asks for batch frames; cancelling closes the socket', () async {
    final s = _Server([
      {'type': 'BATCH', 'events': [{'type': 'ADDED', 'row': {'uid': 'u', 'name': 'web', 'resourceVersion': '1', 'cells': []}}]},
    ]);
    await s.start();
    addTearDown(() => s.http.close(force: true));
    final api = ApiClient(base: s.base);
    final got = Completer<WatchMessage>();
    final sub = api.watch(_ref).listen(got.complete);
    final m = await got.future.timeout(const Duration(seconds: 5));
    expect(m.events.single.row!.name, 'web');
    expect(s.queries.single['batch'], 'true');
    await sub.cancel();
    await s.until(() => s.closed == 1);
    expect(s.closed, 1, reason: 'the server saw the socket close');
  });

  test('a malformed frame is an error on the stream, not an uncaught exception', () async {
    final s = _Server(['not json', jsonEncode({'type': 'ERROR', 'error': 'boom'})]);
    await s.start();
    addTearDown(() => s.http.close(force: true));
    final errors = <Object>[];
    final got = Completer<WatchMessage>();
    final sub = ApiClient(base: s.base).watch(_ref).listen(got.complete, onError: errors.add);
    expect((await got.future.timeout(const Duration(seconds: 5))).error, 'boom');
    expect(errors, hasLength(1));
    await sub.cancel();
  });
}
