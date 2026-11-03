import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

import 'models.dart';

class ApiException implements Exception {
  final int status;
  final String message;
  ApiException(this.status, this.message);
  bool get isNotFound => status == 404;
  bool get isForbidden => status == 403;
  @override
  String toString() => 'API $status: $message';
}

/// Thin client for the k8sman Go backend. All calls are read-only against
/// the cluster (column config writes go to the local config file).
class ApiClient {
  final Uri base;
  final http.Client _http;

  ApiClient({Uri? base, http.Client? httpClient})
      : base = base ?? Uri.parse(const String.fromEnvironment('K8SMAN_BACKEND', defaultValue: 'http://127.0.0.1:7443')),
        _http = httpClient ?? http.Client();

  Uri _uri(String path, [Map<String, String?> query = const {}]) {
    final q = <String, String>{
      for (final e in query.entries)
        if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
    };
    return base.replace(path: '/api/$path', queryParameters: q.isEmpty ? null : q);
  }

  Future<dynamic> _get(String path, [Map<String, String?> query = const {}]) async {
    final res = await _http.get(_uri(path, query));
    return _decode(res);
  }

  Future<dynamic> _send(String method, String path, Map<String, String?> query, Object? body) async {
    final req = http.Request(method, _uri(path, query));
    if (body != null) {
      req.headers['Content-Type'] = 'application/json';
      req.body = jsonEncode(body);
    }
    final res = await http.Response.fromStream(await _http.send(req));
    return _decode(res);
  }

  dynamic _decode(http.Response res) {
    if (res.statusCode >= 400) {
      String msg = res.body;
      try {
        msg = (jsonDecode(res.body) as Map)['error'] ?? msg;
      } catch (_) {}
      throw ApiException(res.statusCode, msg);
    }
    if (res.headers['content-type']?.contains('json') ?? false) return jsonDecode(res.body);
    return res.body;
  }

  // ---- cluster ----

  Future<Json> health() async => await _get('health');

  Future<({String current, List<ContextInfo> contexts})> contexts() async {
    final j = await _get('contexts') as Json;
    return (
      current: (j['current'] ?? '') as String,
      contexts: [for (final c in (j['contexts'] as List? ?? const [])) ContextInfo.fromJson(c)],
    );
  }

  Future<void> switchContext(String name) => _send('POST', 'contexts/current', const {}, {'name': name});

  Future<List<ResourceType>> resources({bool refresh = false}) async {
    final j = await _get('resources', {'refresh': refresh ? 'true' : null}) as List;
    return [for (final r in j) ResourceType.fromJson(r)];
  }

  Future<({List<String> namespaces, String? defaultNamespace})> namespaces() async {
    final j = await _get('namespaces') as Json;
    return (namespaces: List<String>.from(j['namespaces'] ?? const []), defaultNamespace: j['default'] as String?);
  }

  // ---- objects ----

  /// List rendered through the column set.
  Future<TableData> table(ResourceRef r, {String? namespace, String? labelSelector, String? fieldSelector, bool includeObject = false}) async {
    final j = await _get('table', {
      ...r.toQuery(),
      'namespace': namespace,
      'labelSelector': labelSelector,
      'fieldSelector': fieldSelector,
      'includeObject': includeObject ? 'true' : null,
    });
    return TableData.fromJson(j);
  }

  /// Raw objects. Use for related resources, e.g.
  /// `items(ResourceRef(resource: 'pods'), namespace: ns, labelSelector: 'app=web')`.
  Future<List<Json>> items(ResourceRef r, {String? namespace, String? labelSelector, String? fieldSelector}) async {
    final j = await _get('items', {
      ...r.toQuery(),
      'namespace': namespace,
      'labelSelector': labelSelector,
      'fieldSelector': fieldSelector,
    }) as Json;
    return [for (final i in (j['items'] as List? ?? const [])) Map<String, dynamic>.from(i)];
  }

  Future<Json> object(ResourceRef r, {String? namespace, required String name}) async =>
      Map<String, dynamic>.from(await _get('object', {...r.toQuery(), 'namespace': namespace, 'name': name}));

  Future<String> objectYaml(ResourceRef r, {String? namespace, required String name, bool managedFields = false}) async =>
      (await _get('object', {
        ...r.toQuery(),
        'namespace': namespace,
        'name': name,
        'format': 'yaml',
        'managedFields': managedFields ? 'true' : null,
      })) as String;

  /// core/v1 Events for an object, newest first. Prefer [uid] when known.
  Future<List<Json>> events({String? namespace, String? uid, String? kind, String? name}) async {
    final j = await _get('events', {'namespace': namespace, 'uid': uid, 'kind': kind, 'name': name}) as Json;
    return [for (final i in (j['items'] as List? ?? const [])) Map<String, dynamic>.from(i)];
  }

  // ---- columns ----

  Future<ColumnsConfig> getColumns(ResourceRef r) async => ColumnsConfig.fromJson(await _get('columns', r.toQuery()));

  Future<void> putColumns(ResourceRef r, List<ColumnDef> cols) =>
      _send('PUT', 'columns', r.toQuery(), {'columns': [for (final c in cols) c.toJson()]});

  Future<void> resetColumns(ResourceRef r) => _send('DELETE', 'columns', r.toQuery(), null);

  Future<TableData> previewColumns(ResourceRef r, List<ColumnDef> cols, {String? namespace, int limit = 25}) async =>
      TableData.fromJson(await _send('POST', 'columns/preview', {...r.toQuery(), 'namespace': namespace, 'limit': '$limit'},
          {'columns': [for (final c in cols) c.toJson()]}));

  // ---- streams ----

  Uri _ws(String path, Map<String, String?> query) {
    final u = _uri(path, query);
    return u.replace(scheme: u.scheme == 'https' ? 'wss' : 'ws');
  }

  Stream<Json> _wsStream(Uri uri) {
    late WebSocketChannel ch;
    final controller = StreamController<Json>();
    controller.onListen = () {
      ch = WebSocketChannel.connect(uri);
      ch.stream.listen(
        (m) => controller.add(jsonDecode(m as String) as Json),
        onError: controller.addError,
        onDone: controller.close,
      );
    };
    controller.onCancel = () => ch.sink.close();
    return controller.stream;
  }

  /// Live table: a SNAPSHOT, then ADDED/MODIFIED/DELETED rows. Use a
  /// `fieldSelector` of `metadata.name=<name>` with [includeObject] to watch
  /// a single object.
  Stream<WatchMessage> watch(ResourceRef r,
          {String? namespace, String? labelSelector, String? fieldSelector, bool includeObject = false}) =>
      _wsStream(_ws('watch', {
        ...r.toQuery(),
        'namespace': namespace,
        'labelSelector': labelSelector,
        'fieldSelector': fieldSelector,
        'includeObject': includeObject ? 'true' : null,
      })).map(WatchMessage.fromJson);

  /// Container logs, one line per message, ending with eof or error.
  Stream<LogMessage> logs({
    required String namespace,
    required String pod,
    String? container,
    int tailLines = 500,
    bool previous = false,
    bool follow = true,
    bool timestamps = false,
    int? sinceSeconds,
  }) =>
      _wsStream(_ws('logs', {
        'namespace': namespace,
        'pod': pod,
        'container': container,
        'tailLines': '$tailLines',
        'previous': previous ? 'true' : null,
        'follow': follow ? null : 'false',
        'timestamps': timestamps ? 'true' : null,
        'sinceSeconds': sinceSeconds?.toString(),
      })).map(LogMessage.fromJson);
}
