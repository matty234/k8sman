import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import '../state/namespace_scope.dart';
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

  /// For a `LocalPortInUse` conflict: the forward holding the local port
  /// (`namespace/kind/name:port`; empty when another process has it) and a
  /// free port to use instead.
  final String? usedBy;
  final int? suggestedPort;
  ApiException(this.status, this.message, {this.reason, this.causes = const [], this.usedBy, this.suggestedPort});
  bool get isPortInUse => reason == 'LocalPortInUse';
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

  /// The context the UI is showing (set by AppState). Sent with every
  /// request so the backend refuses a change meant for another cluster if
  /// the context switched in between (409 ContextMismatch).
  String? context;

  /// `Authorization: Bearer <token>` and the context header, when known.
  Map<String, String> get authHeaders {
    final t = token;
    final c = context;
    return {
      if (t != null && t.isNotEmpty) 'Authorization': 'Bearer $t',
      if (c != null && c.isNotEmpty) 'X-K8sman-Context': c,
    };
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

  /// The kubeconfig's contexts. [readOnly] maps each read-only context to
  /// why: `flag` (--read-only), `context` (the user locked it) or `auto`
  /// (its name looks like production).
  Future<({String current, List<ContextInfo> contexts, Map<String, String> readOnly})> contexts() async {
    final j = await _get('contexts') as Json;
    final ro = j['readOnly'];
    return (
      current: (j['current'] ?? '') as String,
      contexts: [for (final c in (j['contexts'] as List? ?? const [])) ContextInfo.fromJson(c)],
      readOnly: {if (ro is Map) for (final e in ro.entries) '${e.key}': '${e.value}'},
    );
  }

  /// Lock (true) or unlock (false) a context, or null for automatic.
  /// Returns its effective state.
  Future<({bool readOnly, String reason})> setContextReadOnly(String context, bool? readOnly) async {
    final j = await _send('PUT', 'settings/readonly', const {}, {'context': context, 'readOnly': readOnly}) as Json;
    return (readOnly: j['readOnly'] == true, reason: (j['readOnlyReason'] ?? '') as String);
  }

  /// What draining [node] would do (`GET /api/nodes/drain-plan`).
  Future<DrainPlan> drainPlan(String node, {bool deleteEmptyDirData = false, bool force = false}) async =>
      DrainPlan.fromJson(await _get('nodes/drain-plan', {'name': node, 'deleteEmptyDirData': '$deleteEmptyDirData', 'force': '$force'}) as Json);

  /// Cordons [node] and evicts its pods like `kubectl drain`. Returns once it
  /// finished or gave up (see [DrainResult.error]).
  Future<DrainResult> drainNode(String node, {bool deleteEmptyDirData = false, bool force = false, int timeoutSeconds = 300}) async =>
      DrainResult.fromJson(await _send('POST', 'nodes/drain', {'name': node},
          {'deleteEmptyDirData': deleteEmptyDirData, 'force': force, 'timeoutSeconds': timeoutSeconds}) as Json);

  /// Saved table preferences per kind (`group/Kind`).
  Future<Map<String, Json>> getTablePrefs() async {
    final j = await _get('settings/tables') as Json;
    final t = j['tables'];
    return {if (t is Map) for (final e in t.entries) if (e.value is Map) '${e.key}': (e.value as Map).cast<String, dynamic>()};
  }

  /// Saves (or with null forgets) one kind's table preferences.
  Future<void> putTablePrefs(String kind, Json? prefs) async {
    await _send('PUT', 'settings/tables', const {}, {'kind': kind, 'prefs': prefs});
  }

  /// Namespaces the user added by hand for [context] (the current one if null).
  Future<List<String>> getRememberedNamespaces({String? context}) async {
    final j = await _get('settings/namespaces', {'context': context}) as Json;
    return [for (final n in (j['namespaces'] as List? ?? const [])) '$n'];
  }

  /// Replaces the namespaces added by hand for [context].
  Future<void> putRememberedNamespaces(List<String> namespaces, {String? context}) async {
    await _send('PUT', 'settings/namespaces', const {}, {'context': ?context, 'namespaces': namespaces});
  }

  /// Namespaces the user starred for [context] (the current one if null).
  /// Every saved context badge: context → (icon id, colour id or #hex).
  Future<Map<String, ({String icon, String color})>> getContextAppearances() async {
    final j = await _get('settings/context-appearance') as Json;
    final all = j['all'];
    return {
      if (all is Map)
        for (final e in all.entries)
          '${e.key}': (icon: '${(e.value as Map)['icon'] ?? ''}', color: '${(e.value as Map)['color'] ?? ''}'),
    };
  }

  /// Saves a context's badge; both empty forgets it.
  Future<void> putContextAppearance(String context, String icon, String color) async {
    await _send('PUT', 'settings/context-appearance', const {}, {'context': context, 'icon': icon, 'color': color});
  }

  Future<List<String>> getFavouriteNamespaces({String? context}) async {
    final j = await _get('settings/favourite-namespaces', {'context': context}) as Json;
    return [for (final n in (j['namespaces'] as List? ?? const [])) '$n'];
  }

  /// Replaces the starred namespaces for [context].
  Future<void> putFavouriteNamespaces(List<String> namespaces, {String? context}) async {
    await _send('PUT', 'settings/favourite-namespaces', const {}, {'context': ?context, 'namespaces': namespaces});
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

  /// The cluster's namespaces. [listed] is false when the user can't list
  /// them and the backend returned only the context's default.
  Future<({List<String> namespaces, String? defaultNamespace, bool listed})> namespaces() async {
    final j = await _get('namespaces') as Json;
    return (namespaces: List<String>.from(j['namespaces'] ?? const []), defaultNamespace: j['default'] as String?, listed: j['listed'] != false);
  }

  // ---- objects ----

  /// List rendered through the column set.
  /// [scope] (a namespace set) replaces [namespace] when given.
  Future<TableData> table(ResourceRef r,
      {String? namespace, NamespaceScope? scope, String? labelSelector, String? fieldSelector, bool includeObject = false}) async {
    final j = await _get('table', {
      ...r.toQuery(),
      ...scope?.query ?? {'namespace': namespace},
      'labelSelector': labelSelector,
      'fieldSelector': fieldSelector,
      'includeObject': includeObject ? 'true' : null,
    });
    return TableData.fromJson(j);
  }

  /// Raw objects. Use for related resources, e.g.
  /// `items(ResourceRef(resource: 'pods'), namespace: ns, labelSelector: 'app=web')`.
  /// [scope] (a namespace set) replaces [namespace] when given.
  Future<List<Json>> items(ResourceRef r, {String? namespace, NamespaceScope? scope, String? labelSelector, String? fieldSelector}) async =>
      (await itemsWithPartial(r, namespace: namespace, scope: scope, labelSelector: labelSelector, fieldSelector: fieldSelector)).items;

  /// [items] plus the response's `partialErrors` as sent (namespaces of a
  /// set that could not be read; see `parsePartialErrors`).
  Future<({List<Json> items, Object? partialErrors})> itemsWithPartial(ResourceRef r,
      {String? namespace, NamespaceScope? scope, String? labelSelector, String? fieldSelector}) async {
    final j = await _get('items', {
      ...r.toQuery(),
      ...scope?.query ?? {'namespace': namespace},
      'labelSelector': labelSelector,
      'fieldSelector': fieldSelector,
    }) as Json;
    return (items: [for (final i in (j['items'] as List? ?? const [])) Map<String, dynamic>.from(i)], partialErrors: j['partialErrors']);
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

  /// A subresource (`status` or `scale`) of an object, as YAML or JSON.
  Future<String> subresourceYaml(ResourceRef r, String subresource, {String? namespace, required String name}) async =>
      (await _get('object', {...r.toQuery(), 'namespace': namespace, 'name': name, 'format': 'yaml', 'subresource': subresource})) as String;

  Future<Json> subresource(ResourceRef r, String subresource, {String? namespace, required String name}) async =>
      Map<String, dynamic>.from(await _get('object', {...r.toQuery(), 'namespace': namespace, 'name': name, 'subresource': subresource}));

  /// core/v1 Events for an object, newest first. Prefer [uid] when known.
  Future<List<Json>> events({String? namespace, String? uid, String? kind, String? name}) async {
    final j = await _get('events', {'namespace': namespace, 'uid': uid, 'kind': kind, 'name': name}) as Json;
    return [for (final i in (j['items'] as List? ?? const [])) Map<String, dynamic>.from(i)];
  }

  /// Objects that name [uid] in their ownerReferences (`/api/owned`), from the
  /// backend's watch cache. [partial] means some kinds were not searched.
  Future<({List<Json> items, bool partial})> owned({required String uid, String? namespace}) async {
    final j = await _get('owned', {'uid': uid, 'namespace': namespace}) as Json;
    return (items: [for (final i in (j['items'] as List? ?? const [])) Map<String, dynamic>.from(i)], partial: j['partial'] == true);
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

  // ---- saved views (settings.json) ----

  /// Saved view records as stored (records of a newer version included:
  /// callers skip what they can't read) and the view opened at launch.
  ///
  /// `kubeconfigKeys` maps each kubeconfig path the views mention to its
  /// canonical key (resolved by the backend), so views match the active
  /// kubeconfig however its path was spelled.
  Future<({List<Json> views, String launchView, Map<String, String> kubeconfigKeys})> getViews() async {
    final j = await _get('settings/views') as Json;
    return (
      views: [for (final v in (j['views'] as List? ?? const [])) if (v is Map) Map<String, dynamic>.from(v)],
      launchView: (j['launchView'] as String?) ?? '',
      kubeconfigKeys: {for (final e in ((j['kubeconfigKeys'] as Map?) ?? const {}).entries) '${e.key}': '${e.value}'},
    );
  }

  /// Adds or replaces a view (by its id). With [index] the view is placed
  /// at that position of the order (undoing a delete).
  Future<void> putView(Json view, {int? index}) =>
      _send('PUT', 'settings/views/${Uri.encodeComponent('${view['id']}')}', {'index': index?.toString()}, view);

  /// Saves the order of the views.
  Future<void> reorderViews(List<String> ids) => _send('PUT', 'settings/views/order', const {}, {'ids': ids});

  Future<void> deleteView(String id) => _send('DELETE', 'settings/views/${Uri.encodeComponent(id)}', const {}, null);

  /// The view to open at launch ('' = reconnect to the last context).
  Future<void> setLaunchView(String id) => _send('PUT', 'settings/views/launch', const {}, {'id': id});

  /// Views as shareable YAML documents.
  Future<String> exportViews(List<Json> views) async => '${await _send('POST', 'settings/views/export', const {}, {'views': views})}';

  /// Parses YAML view documents into view records (fresh ids, not saved).
  Future<List<Json>> parseViews(String yaml) async {
    final j = await _send('POST', 'settings/views/parse', const {}, {'yaml': yaml}) as Json;
    return [for (final v in (j['views'] as List? ?? const [])) Map<String, dynamic>.from(v as Map)];
  }

  // ---- integrations (settings.json) ----

  /// Ids of the integration modules the user turned off.
  /// Whether the log viewer shows the newest line at the top.
  Future<bool> getLogNewestFirst() async => (await _get('settings/logs') as Json)['newestFirst'] == true;

  Future<void> putLogNewestFirst(bool v) => _send('PUT', 'settings/logs', const {}, {'newestFirst': v});

  /// Whether Copy link copies the `k8sman://` form (else the https one).
  Future<bool> getAppLinks() async => (await _get('settings/links') as Json)['appLinks'] == true;

  Future<void> putAppLinks(bool v) => _send('PUT', 'settings/links', const {}, {'appLinks': v});

  /// Remembered link mappings: cluster fingerprint → local context.
  Future<Map<String, String>> getLinkClusterMap() async {
    final m = (await _get('settings/link-clusters') as Json)['linkClusterMap'] as Map? ?? const {};
    return {for (final e in m.entries) '${e.key}': '${e.value}'};
  }

  /// Remembers (or with [context] '' forgets) where links for [fingerprint] open.
  Future<void> putLinkCluster(String fingerprint, String context) =>
      _send('PUT', 'settings/link-clusters', const {}, {'fingerprint': fingerprint, 'context': context});

  Future<Set<String>> getDisabledModules() async {
    final j = await _get('settings/modules') as Json;
    return {for (final id in (j['disabled'] as List? ?? const [])) '$id'};
  }

  Future<void> putDisabledModules(Set<String> ids) => _send('PUT', 'settings/modules', const {}, {'disabled': [...ids]..sort()});

  /// Module [id]'s own settings for the current kube context ({} when none
  /// are saved). See `Configurable` in backend/internal/server/module.go.
  Future<Json> getModuleSettings(String id) async =>
      Map<String, dynamic>.from((await _get('settings/modules/${Uri.encodeComponent(id)}') as Json)['settings'] as Map? ?? const {});

  /// Saves module [id]'s settings for the current kube context ({} clears).
  /// The module validates them: a bad value is an [ApiException] (400).
  Future<void> putModuleSettings(String id, Json settings) => _send('PUT', 'settings/modules/${Uri.encodeComponent(id)}', const {}, settings);

  // ---- CRD group icons (settings.json) ----

  /// Whether icons may be fetched from the internet: the saved choice
  /// (null = automatic), whether `--no-remote-icons` overrides it, and what
  /// applies to the current context.
  Future<({bool? remoteIcons, bool flag, bool effective})> getIconSettings() async => _iconSettings(await _get('settings/icons') as Json);

  /// Saves the choice (null = automatic) and returns the new state.
  Future<({bool? remoteIcons, bool flag, bool effective})> putIconSettings(bool? remoteIcons) async =>
      _iconSettings(await _send('PUT', 'settings/icons', const {}, {'remoteIcons': remoteIcons}) as Json);

  static ({bool? remoteIcons, bool flag, bool effective}) _iconSettings(Json j) =>
      (remoteIcons: j['remoteIcons'] as bool?, flag: j['flag'] == true, effective: j['effective'] == true);

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
  Future<UpdateResult> updateObject(ResourceRef r, {String? namespace, required String name, required String yaml, bool dryRun = false}) =>
      _putObject(r, namespace: namespace, name: name, yaml: yaml, dryRun: dryRun);

  /// Like [updateObject] but writes the `status` or `scale` subresource.
  Future<UpdateResult> updateSubresource(ResourceRef r, String subresource,
          {String? namespace, required String name, required String yaml, bool dryRun = false}) =>
      _putObject(r, namespace: namespace, name: name, yaml: yaml, dryRun: dryRun, subresource: subresource);

  Future<UpdateResult> _putObject(ResourceRef r, {String? namespace, required String name, required String yaml, bool dryRun = false, String? subresource}) async {
    final req = http.Request(
        'PUT', _uri('object', {...r.toQuery(), 'namespace': namespace, 'name': name, 'dryRun': dryRun ? 'true' : null, 'subresource': subresource}))
      ..headers.addAll(authHeaders)
      ..headers['Content-Type'] = 'application/yaml'
      ..body = yaml;
    return UpdateResult.fromJson(_decode(await http.Response.fromStream(await _http.send(req))));
  }

  /// Creates the objects in [yaml] (one or more `---` documents) with
  /// `POST /api/apply`; [namespace] is the default for namespaced objects
  /// without one. [serverSide] uses server-side apply, which also updates
  /// existing objects. Per-object failures come back in the results.
  Future<ManifestResult> applyManifests(String yaml, {String? namespace, bool dryRun = false, bool serverSide = false}) async {
    final req = http.Request('POST', _uri('apply', {'namespace': namespace, 'dryRun': dryRun ? 'true' : null, 'mode': serverSide ? 'apply' : null}))
      ..headers.addAll(authHeaders)
      ..headers['Content-Type'] = 'application/yaml'
      ..body = yaml;
    return ManifestResult.fromJson(_decode(await http.Response.fromStream(await _http.send(req))));
  }

  /// Action names supported for a type (scale, restart, delete, ...).
  Future<List<String>> availableActions(ResourceRef r) async =>
      List<String>.from(((await _get('actions', r.toQuery())) as Json)['actions'] ?? const []);

  /// Run an action, e.g. `runAction(ref, namespace: ns, name: n, action: 'scale', body: {'replicas': 3})`.
  Future<ActionResult> runAction(ResourceRef r, {String? namespace, required String name, required String action, Json body = const {}}) async =>
      ActionResult.fromJson(await _send('POST', 'actions/$action', {...r.toQuery(), 'namespace': namespace, 'name': name}, body));

  /// How many saved forwards the backend dropped at startup because their
  /// target is gone (from the last [portForwards] call).
  int removedForwards = 0;

  Future<List<PortForward>> portForwards() async {
    final j = (await _get('portforwards')) as Json;
    removedForwards = (j['removedGone'] as num?)?.toInt() ?? 0;
    return [for (final f in (j['forwards'] as List? ?? const [])) PortForward.fromJson(f)];
  }

  /// The local port to default to for remote port [remote]: the same number
  /// when it is free and >= 1024, else the next free one.
  Future<int> freeForwardPort(int remote) async => ((await _get('portforwards/free', {'port': '$remote'})) as Json)['port'] as int;

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
    bool replace = false,
    bool openInBrowser = false,
    bool https = false,
    bool ephemeral = false,
  }) async =>
      PortForward.fromJson(await _send('POST', 'portforwards', const {}, {
        'replace': replace,
        'namespace': namespace,
        'kind': kind,
        'name': name,
        'port': port,
        'localPort': localPort,
        'autoStart': autoStart,
        'label': ?label,
        if (openInBrowser) 'openInBrowser': true,
        if (https) 'https': true,
        if (ephemeral) 'ephemeral': true,
      }));

  Future<PortForward> updatePortForward(String id, {bool? autoStart, String? label, int? localPort}) async =>
      PortForward.fromJson(await _send('PATCH', 'portforwards/$id', const {}, {'autoStart': ?autoStart, 'label': ?label, 'localPort': ?localPort}));

  Future<void> startPortForward(String id) => _send('POST', 'portforwards/$id/start', const {}, null);
  Future<void> stopPortForward(String id) => _send('POST', 'portforwards/$id/stop', const {}, null);

  /// Stops every running forward (of [context] only, if given) in one
  /// request; they stay saved. Returns how many were stopped.
  Future<int> stopAllPortForwards({String? context}) async =>
      ((await _send('POST', 'portforwards/stop', {'context': context}, null)) as Json)['stopped'] as int;

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
  Stream<Json> _wsStream(Uri uri) => _wsRaw(uri).cast<Json>();

  /// Like [_wsStream] for sockets whose frames may be JSON arrays.
  Stream<dynamic> _wsRaw(Uri uri) {
    WebSocketChannel? ch;
    StreamSubscription<dynamic>? sub;
    final controller = StreamController<dynamic>();
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
            controller.add(jsonDecode(m as String));
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

  /// A backend WebSocket under /api/[path] whose frames are JSON objects,
  /// for modules' own streams (e.g. `hubble/flows`). Cancelling the
  /// subscription closes the socket.
  Stream<Json> jsonStream(String path, [Map<String, String?> query = const {}]) => _wsStream(_ws(path, query));

  /// Live table: a SNAPSHOT, then ADDED/MODIFIED/DELETED rows. Use a
  /// `fieldSelector` of `metadata.name=<name>` with [includeObject] to watch
  /// a single object.
  ///
  /// Asks for `batch=true`: newer backends may coalesce bursts into BATCH
  /// frames ([WatchMessage.events]); older ones ignore it and send single
  /// rows, so consumers must handle both.
  ///
  /// [scope] (a namespace set) replaces [namespace] when given; a set's
  /// forbidden namespaces arrive as PARTIAL_ERROR frames.
  ///
  /// [columns] replaces the kind's column configuration for this watch (a
  /// saved view's own columns).
  Stream<WatchMessage> watch(ResourceRef r,
          {String? namespace,
          NamespaceScope? scope,
          String? labelSelector,
          String? fieldSelector,
          bool includeObject = false,
          List<ColumnDef>? columns}) =>
      _wsStream(_ws('watch', {
        ...r.toQuery(),
        ...scope?.query ?? {'namespace': namespace},
        'columns': columns == null ? null : jsonEncode([for (final c in columns) c.toJson()]),
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

  /// Merged logs of many pods (one `/api/logs/aggregate` socket): follow a
  /// label [selector] or a fixed list of [pods]. [container] is a name, `*`
  /// for every container, or null for each pod's default.
  Stream<AggregateMessage> aggregateLogs({
    required String namespace,
    String? selector,
    List<String>? pods,
    String? container,
    int tailLines = 200,
    bool follow = true,
    bool previous = false,
    int? sinceSeconds,
  }) =>
      _wsRaw(_ws('logs/aggregate', {
        'namespace': namespace,
        'selector': selector,
        'pods': pods?.join(','),
        'container': container,
        'tailLines': '$tailLines',
        'follow': follow ? null : 'false',
        'previous': previous ? 'true' : null,
        'sinceSeconds': sinceSeconds?.toString(),
      })).map(AggregateMessage.fromJson);
}
