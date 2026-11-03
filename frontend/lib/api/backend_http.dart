/// Request plumbing shared by [ApiClient] and the typed per-area clients
/// (Prometheus, Helm, Argo CD, overview, security): URL building, JSON
/// bodies and the backend's `{error, reason, causes}` error shape.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import 'client.dart';
import 'models.dart';

/// [base] with [path] and the non-empty values of [query].
Uri backendUri(Uri base, String path, [Map<String, String?> query = const {}]) {
  final q = <String, String>{
    for (final e in query.entries)
      if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
  };
  return base.replace(path: path, queryParameters: q.isEmpty ? null : q);
}

/// Throws an [ApiException] when [res] is an error response, taking the
/// message, Kubernetes reason and field causes from the JSON body if present.
void throwIfFailed(http.Response res) {
  if (res.statusCode < 400) return;
  var msg = res.body;
  String? reason;
  var causes = <Map<String, dynamic>>[];
  try {
    final j = jsonDecode(res.body) as Map;
    msg = '${j['error'] ?? msg}';
    reason = j['reason'] as String?;
    causes = [for (final c in (j['causes'] as List? ?? const [])) Map<String, dynamic>.from(c)];
  } catch (_) {}
  throw ApiException(res.statusCode, msg, reason: reason, causes: causes);
}

/// The decoded JSON body, or null when it is empty.
dynamic jsonBody(http.Response res) => res.body.isEmpty ? null : jsonDecode(res.body);

/// The body as a JSON object.
Json jsonObjectBody(http.Response res) => Map<String, dynamic>.from(jsonDecode(res.body) as Map);

/// JSON requests against one area of the backend, e.g. `/api/prom/`. The
/// backend URL is read from [api] on every call: the app updates it when the
/// embedded backend (re)starts.
class BackendHttp {
  final ApiClient api;

  /// Path prefix prepended to every request path, e.g. `/api/prom/`.
  final String prefix;
  final http.Client _http;
  BackendHttp(this.api, this.prefix, {http.Client? httpClient}) : _http = httpClient ?? http.Client();

  Uri uri(String path, [Map<String, String?> query = const {}]) => backendUri(api.base, '$prefix$path', query);

  /// GETs [path]; throws [ApiException] on an error status.
  Future<http.Response> get(String path, [Map<String, String?> query = const {}]) async {
    final res = await _http.get(uri(path, query));
    throwIfFailed(res);
    return res;
  }

  /// Sends [method] to [path] with an optional JSON [body]; throws
  /// [ApiException] on an error status.
  Future<http.Response> send(String method, String path, {Map<String, String?> query = const {}, Object? body}) async {
    final req = http.Request(method, uri(path, query));
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await _http.send(req));
    throwIfFailed(res);
    return res;
  }
}
