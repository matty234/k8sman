import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/backend_http.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/app/backend.dart';
import 'package:k8sman/ui/terminal/exec_protocol.dart';

const _token = 'test-token-0123456789abcdef0123456789abcdef';

/// One request as the loopback server saw it.
class _Seen {
  final String method, path;
  final String? auth, contentType;
  final bool upgrade;
  _Seen(HttpRequest r)
      : method = r.method,
        path = r.uri.path,
        auth = r.headers.value(HttpHeaders.authorizationHeader),
        contentType = r.headers.value(HttpHeaders.contentTypeHeader),
        upgrade = WebSocketTransformer.isUpgradeRequest(r);
  @override
  String toString() => '$method $path';
}

/// A loopback backend that, like the real one, refuses requests without the
/// token (401) and mutations without a JSON/YAML Content-Type (415).
class _Backend {
  late HttpServer http;
  final seen = <_Seen>[];

  Future<void> start() async {
    http = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    http.listen((req) async {
      final s = _Seen(req);
      seen.add(s);
      if (s.auth != 'Bearer $_token') {
        req.response.statusCode = 401;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'error': 'missing or invalid bearer token', 'code': 401}));
        await req.response.close();
        return;
      }
      if (const {'POST', 'PUT', 'PATCH', 'DELETE'}.contains(s.method) &&
          !(s.contentType ?? '').startsWith('application/json') &&
          !(s.contentType ?? '').startsWith('application/yaml')) {
        req.response.statusCode = 415;
        await req.response.close();
        return;
      }
      if (s.upgrade) {
        final ws = await WebSocketTransformer.upgrade(req);
        ws.add(jsonEncode({'eof': true}));
        await ws.close();
        return;
      }
      await utf8.decoder.bind(req).join();
      req.response.headers.contentType = ContentType.json;
      req.response.write(switch (s.path) {
        '/api/object' => jsonEncode({'object': {}}),
        '/api/debug-container' => jsonEncode({'name': 'debugger-1'}),
        _ => '{}',
      });
      await req.response.close();
    });
  }

  Uri get base => Uri.parse('http://127.0.0.1:${http.port}');
}

void main() {
  late _Backend b;
  setUp(() async {
    b = _Backend();
    await b.start();
  });
  tearDown(() => b.http.close(force: true));

  test('ApiClient sends the bearer token on every HTTP call, and JSON on every mutation', () async {
    final api = ApiClient(base: b.base, token: _token);
    await api.health();
    await api.switchContext('dev');
    await api.resetColumns(const ResourceRef(resource: 'pods'));
    await api.startPortForward('x');
    await api.deletePortForward('x');
    await api.updateObject(const ResourceRef(resource: 'pods'), name: 'p', yaml: 'kind: Pod');
    await api.groupIcon('example.com');
    await api.probe('reach'); // its own AbortableRequest, not _get
    await api.putSidebar(null);
    expect(b.seen, hasLength(9));
    for (final s in b.seen) {
      expect(s.auth, 'Bearer $_token', reason: '$s');
      if (s.method != 'GET') expect(s.contentType, anyOf(startsWith('application/json'), startsWith('application/yaml')), reason: '$s');
    }
  });

  test('without a token the backend refuses (401 surfaces as ApiException)', () async {
    final api = ApiClient(base: b.base);
    expect(api.authHeaders, isEmpty);
    await expectLater(api.health(), throwsA(isA<ApiException>().having((e) => e.status, 'status', 401)));
  });

  test('BackendHttp (typed per-area clients) sends the token and JSON', () async {
    final api = ApiClient(base: b.base, token: _token);
    final h = BackendHttp(api, '/api/prom/');
    await h.get('status');
    await h.send('DELETE', 'silences/1');
    await h.send('POST', 'silences', body: {'x': 1});
    expect([for (final s in b.seen) s.auth], everyElement('Bearer $_token'));
    expect([for (final s in b.seen.skip(1)) s.contentType], everyElement(startsWith('application/json')));
  });

  test('WebSocket streams send the token in the handshake, not the URL', () async {
    final api = ApiClient(base: b.base, token: _token);
    final msgs = await api.logs(namespace: 'n', pod: 'p').toList().timeout(const Duration(seconds: 5));
    expect(msgs.single.eof, isTrue);
    final ws = b.seen.single;
    expect(ws.upgrade, isTrue);
    expect(ws.auth, 'Bearer $_token');
    expect(b.seen.single.path, '/api/logs');
  });

  test('WebSocket without a token fails the handshake', () async {
    final api = ApiClient(base: b.base);
    await expectLater(api.watch(const ResourceRef(resource: 'pods')).toList().timeout(const Duration(seconds: 5)), throwsA(anything));
    expect(b.seen.single.auth, isNull);
  });

  test('exec transport sends the token on the WebSocket and the debug-container POST', () async {
    final api = ApiClient(base: b.base, token: _token);
    final t = execTransportFor(api);
    expect(await t.createDebugContainer(namespace: 'n', pod: 'p', image: 'busybox'), 'debugger-1');
    final conn = t.connect(const ExecRequest(namespace: 'n', pod: 'p'));
    await conn.events.toList().timeout(const Duration(seconds: 5));
    expect(b.seen.map((s) => s.path), ['/api/debug-container', '/api/exec']);
    expect([for (final s in b.seen) s.auth], everyElement('Bearer $_token'));
    expect(b.seen.last.upgrade, isTrue);
  });

  group('BackendController', () {

    test('an external backend uses the dev-token file', () async {
      final api = ApiClient(base: b.base);
      final c = BackendController(api)..readDevToken = () => _token;
      await c.start(); // no native plugin in tests: external
      expect(c.status.phase, BackendPhase.external);
      expect(api.token, _token);
      await api.health();
    });

  });
}
