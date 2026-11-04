import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'backend_http.dart';
import 'kubeconfig.dart';
import 'models.dart';

export 'kubeconfig.dart';

class ApiException implements Exception {
  final int status;
  final String message;

  /// Kubernetes StatusReason, e.g. Conflict, Invalid, Forbidden.
  final String? reason;

  /// Field-level validation causes: {field, message, reason}.
  final List<Map<String, dynamic>> causes;
  ApiException(this.status, this.message, {this.reason, this.causes = const []});
  bool get isConflict => status == 409;
  bool get isNotFound => status == 404;
  bool get isForbidden => status == 403;
  @override
  String toString() => 'API $status: $message';
}

/// Thin client for the k8sman Go backend. All calls are read-only against
/// the cluster (column config writes go to the local config file).
class ApiClient {
  /// Backend URL. In the macOS app the embedded backend listens on a random
  /// port, so `BackendController` (lib/app/backend.dart) updates this once
  /// the backend reports its address, and again after a restart.
  Uri base;
  final http.Client _http;

  /// `--dart-define=K8SMAN_BACKEND=http://…` points the app at an existing
  /// backend (e.g. `make backend`) instead of spawning the embedded one.
  static const definedBackend = String.fromEnvironment('K8SMAN_BACKEND');
  static const defaultBackend = 'http://127.0.0.1:7443';

  /// `--dart-define=K8SMAN_TOKEN=…`: the bearer token of an external backend
  /// (`make backend` prints it and writes it to ~/.config/k8sman/dev-token,
  /// which the app also reads; see `BackendController`).
  static const definedToken = String.fromEnvironment('K8SMAN_TOKEN');

  /// Bearer token the backend requires on every request (HTTP and
  /// WebSocket). Set by `BackendController` from the supervisor's status
  /// (a fresh one per backend launch). Never log it.
  String? token;

  ApiClient({Uri? base, http.Client? httpClient, String? token})
      : base = base ?? Uri.parse(definedBackend.isNotEmpty ? definedBackend : defaultBackend),
        token = token ?? (definedToken.isNotEmpty ? definedToken : null),
        _http = httpClient ?? http.Client();

  /// `Authorization: Bearer <token>`, or nothing when no token is known.
  Map<String, String> get authHeaders {
    final t = token;
    return t == null || t.isEmpty ? const {} : {'Authorization': 'Bearer $t'};
  }

  /// Opens a WebSocket to the backend with [authHeaders] (desktop only: the
  /// handshake carries the Authorization header, not a query-string token).
  WebSocketChannel connectWebSocket(Uri uri) => IOWebSocketChannel.connect(uri, headers: authHeaders);

  Uri _uri(String path, [Map<String, String?> query = const {}]) => backendUri(base, '/api/$path', query);

  Future<dynamic> _get(String path, [Map<String, String?> query = const {}]) async {
    final res = await _http.get(_uri(path, query), headers: authHeaders);
    return _decode(res);
  }

  Future<dynamic> _send(String method, String path, Map<String, String?> query, Object? body) async {
    final req = http.Request(method, _uri(path, query))
      ..headers.addAll(authHeaders)
      // The backend requires a JSON Content-Type on every mutation (CSRF).
      ..headers['Content-Type'] = 'application/json';
    if (body != null) req.body = jsonEncode(body);
    final res = await http.Response.fromStream(await _http.send(req));
    return _decode(res);
  }

  dynamic _decode(http.Response res) {
    throwIfFailed(res);
    if (res.statusCode == 204 || res.body.isEmpty) return null;
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

  /// One connection step for the current context: `reach` (does anything
  /// answer at the server address? fails in ~10 s) or `auth` (do the
  /// credentials work? runs the exec plugin, which may wait for a browser
  /// login). Completing [abortTrigger] abandons the request, which also
  /// cancels the probe in the backend.
  Future<void> probe(String step, {Future<void>? abortTrigger}) async {
    final req = http.AbortableRequest('GET', _uri('probe', {'step': step}), abortTrigger: abortTrigger)..headers.addAll(authHeaders);
    _decode(await http.Response.fromStream(await _http.send(req)));
  }

  Future<void> switchContext(String name) => _send('POST', 'contexts/current', const {}, {'name': name});

  /// The active kubeconfig file and candidates to switch to.
  Future<KubeconfigList> kubeconfigs() async => KubeconfigList.fromJson(Map<String, dynamic>.from(await _get('kubeconfigs')));

  /// Switch to another kubeconfig file (its last used, else current, context).
  Future<KubeconfigList> switchKubeconfig(String path) async =>
      KubeconfigList.fromJson(Map<String, dynamic>.from(await _send('POST', 'kubeconfigs/current', const {}, {'path': path})));

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

  // ---- sidebar layout (settings.json) ----

  /// The saved sidebar layout (`{items:[…]}`), or null for the default.
  Future<Json?> getSidebar() async {
    final j = await _get('settings/sidebar') as Json;
    final s = j['sidebar'];
    return s == null ? null : Map<String, dynamic>.from(s as Map);
  }

  /// Saves the layout, or with null restores the default.
  Future<void> putSidebar(Json? layout) =>
      layout == null ? _send('DELETE', 'settings/sidebar', const {}, null) : _send('PUT', 'settings/sidebar', const {}, layout);

  // ---- columns ----

  Future<ColumnsConfig> getColumns(ResourceRef r) async => ColumnsConfig.fromJson(await _get('columns', r.toQuery()));

  Future<void> putColumns(ResourceRef r, List<ColumnDef> cols) =>
      _send('PUT', 'columns', r.toQuery(), {'columns': [for (final c in cols) c.toJson()]});

  Future<void> resetColumns(ResourceRef r) => _send('DELETE', 'columns', r.toQuery(), null);

  Future<TableData> previewColumns(ResourceRef r, List<ColumnDef> cols, {String? namespace, int limit = 25}) async =>
      TableData.fromJson(await _send('POST', 'columns/preview', {...r.toQuery(), 'namespace': namespace, 'limit': '$limit'},
          {'columns': [for (final c in cols) c.toJson()]}));

  // ---- metrics APIs ----

  /// JSON from `/api/metrics/<path>` (status, nodes, pods, custom, external, hpa...).
  /// Typed wrappers: `lib/metrics/metrics_api.dart`.
  Future<Json> metrics(String path, [Map<String, String?> query = const {}]) async => Map<String, dynamic>.from(await _get('metrics/$path', query));

  // ---- mutations (disabled when the backend runs --read-only) ----

  /// Replace an object from edited YAML (`kubectl edit` semantics). The YAML
  /// must keep metadata.resourceVersion; a concurrent change → 409.
  Future<UpdateResult> updateObject(ResourceRef r, {String? namespace, required String name, required String yaml, bool dryRun = false}) async {
    final req = http.Request('PUT', _uri('object', {...r.toQuery(), 'namespace': namespace, 'name': name, 'dryRun': dryRun ? 'true' : null}))
      ..headers.addAll(authHeaders)
      ..headers['Content-Type'] = 'application/yaml'
      ..body = yaml;
    return UpdateResult.fromJson(_decode(await http.Response.fromStream(await _http.send(req))));
  }

  /// Action names supported for a type (scale, restart, delete, ...).
  Future<List<String>> availableActions(ResourceRef r) async =>
      List<String>.from(((await _get('actions', r.toQuery())) as Json)['actions'] ?? const []);

  /// Run an action, e.g. `runAction(ref, namespace: ns, name: n, action: 'scale', body: {'replicas': 3})`.
  Future<ActionResult> runAction(ResourceRef r, {String? namespace, required String name, required String action, Json body = const {}}) async =>
      ActionResult.fromJson(await _send('POST', 'actions/$action', {...r.toQuery(), 'namespace': namespace, 'name': name}, body));

  Future<List<PortForward>> portForwards() async =>
      [for (final f in (((await _get('portforwards')) as Json)['forwards'] as List? ?? const [])) PortForward.fromJson(f)];

  /// [kind]: pod | service | deployment | statefulset | daemonset | replicaset.
  /// [port]: remote port number or name (service port for services).
  /// [localPort] 0 = same as remote if free, else a free port.
  Future<PortForward> createPortForward({
    required String namespace,
    required String kind,
    required String name,
    required String port,
    int localPort = 0,
    bool autoStart = false,
    String? label,
  }) async =>
      PortForward.fromJson(await _send('POST', 'portforwards', const {}, {
        'namespace': namespace,
        'kind': kind,
        'name': name,
        'port': port,
        'localPort': localPort,
        'autoStart': autoStart,
        'label': ?label,
      }));

  Future<PortForward> updatePortForward(String id, {bool? autoStart, String? label, int? localPort}) async =>
      PortForward.fromJson(await _send('PATCH', 'portforwards/$id', const {}, {'autoStart': ?autoStart, 'label': ?label, 'localPort': ?localPort}));

  Future<void> startPortForward(String id) => _send('POST', 'portforwards/$id/start', const {}, null);
  Future<void> stopPortForward(String id) => _send('POST', 'portforwards/$id/stop', const {}, null);
  Future<void> deletePortForward(String id) => _send('DELETE', 'portforwards/$id', const {}, null);

  // ---- icons ----

  /// The icon image for a CRD API group (a Helm chart icon or the group's
  /// website favicon), or null when the backend has no image (the group
  /// uses a bundled icon or a monogram). See API.md.
  Future<Uint8List?> groupIcon(String group) async {
    final res = await _http.get(_uri('icons/${Uri.encodeComponent(group)}'), headers: authHeaders);
    if (res.statusCode == 404) return null;
    if (res.statusCode >= 400) _decode(res);
    return res.bodyBytes;
  }

  // ---- streams ----

  Uri _ws(String path, Map<String, String?> query) {
    final u = _uri(path, query);
    return u.replace(scheme: u.scheme == 'https' ? 'wss' : 'ws');
  }

  /// One WebSocket per listen. Cancelling the subscription closes the socket
  /// (and drops anything still in flight); the socket closing ends the stream.
  Stream<Json> _wsStream(Uri uri) {
    WebSocketChannel? ch;
    StreamSubscription<dynamic>? sub;
    final controller = StreamController<Json>();
    controller.onListen = () {
      try {
        ch = connectWebSocket(uri);
        // A failed handshake (backend down, 401/403) also arrives as an
        // error on the stream; don't report it twice as uncaught.
        ch!.ready.catchError((Object _) {});
      } catch (e, st) {
        controller.addError(e, st);
        controller.close();
        return;
      }
      sub = ch!.stream.listen(
        (m) {
          try {
            controller.add(jsonDecode(m as String) as Json);
          } catch (e, st) {
            controller.addError(e, st);
          }
        },
        onError: controller.addError,
        onDone: controller.close,
      );
    };
    controller.onCancel = () async {
      final c = ch, s = sub;
      ch = null;
      sub = null;
      // Closing a socket that is still connecting (or failed to) must not
      // surface as an unhandled error, nor hold up the cancel.
      c?.sink.close().catchError((Object _) {});
      await s?.cancel();
    };
    return controller.stream;
  }

  /// Live table: a SNAPSHOT, then ADDED/MODIFIED/DELETED rows. Use a
  /// `fieldSelector` of `metadata.name=<name>` with [includeObject] to watch
  /// a single object.
  ///
  /// Asks for `batch=true`: newer backends may coalesce bursts into BATCH
  /// frames ([WatchMessage.events]); older ones ignore it and send single
  /// rows, so consumers must handle both.
  Stream<WatchMessage> watch(ResourceRef r,
          {String? namespace, String? labelSelector, String? fieldSelector, bool includeObject = false}) =>
      _wsStream(_ws('watch', {
        ...r.toQuery(),
        'namespace': namespace,
        'labelSelector': labelSelector,
        'fieldSelector': fieldSelector,
        'includeObject': includeObject ? 'true' : null,
        'batch': 'true',
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
