/// Data models mirroring the Go backend's JSON (see /API.md).
library;

typedef Json = Map<String, dynamic>;

/// Identifies a resource collection. [version] may be null to let the
/// backend pick the server-preferred version.
class ResourceRef {
  final String group;
  final String? version;
  final String resource;
  const ResourceRef({this.group = '', this.version, required this.resource});

  Map<String, String> toQuery() => {
        'group': group,
        'version': ?version,
        'resource': resource,
      };

  /// kubectl-style key, e.g. `deployments.apps`.
  String get key => group.isEmpty ? resource : '$resource.$group';

  @override
  bool operator ==(Object other) =>
      other is ResourceRef && other.group == group && other.resource == resource && other.version == version;
  @override
  int get hashCode => Object.hash(group, version, resource);
  @override
  String toString() => key;
}

/// A discovered, listable API resource.
class ResourceType {
  final String group;
  final String version;
  final String resource;
  final String kind;
  final bool namespaced;
  final List<String> verbs;
  final List<String> shortNames;
  final List<String> categories;
  final bool custom;

  const ResourceType({
    required this.group,
    required this.version,
    required this.resource,
    required this.kind,
    this.namespaced = true,
    this.verbs = const [],
    this.shortNames = const [],
    this.categories = const [],
    this.custom = false,
  });

  factory ResourceType.fromJson(Json j) => ResourceType(
        group: j['group'] ?? '',
        version: j['version'] ?? '',
        resource: j['resource'] ?? '',
        kind: j['kind'] ?? '',
        namespaced: j['namespaced'] ?? false,
        verbs: List<String>.from(j['verbs'] ?? const []),
        shortNames: List<String>.from(j['shortNames'] ?? const []),
        categories: List<String>.from(j['categories'] ?? const []),
        custom: j['custom'] ?? false,
      );

  ResourceRef get ref => ResourceRef(group: group, version: version, resource: resource);

  /// `group/Kind` — the key panels register under. Core group is empty: `/Pod`.
  String get gk => '$group/$kind';

  String get apiVersion => group.isEmpty ? version : '$group/$version';

  bool can(String verb) => verbs.contains(verb);

  @override
  bool operator ==(Object other) =>
      other is ResourceType && other.group == group && other.resource == resource && other.version == version;
  @override
  int get hashCode => Object.hash(group, version, resource);
}

/// A jq-backed table column.
class ColumnDef {
  final String name;
  final String query;

  /// string | number | age | status | bool | labels
  final String type;
  const ColumnDef({required this.name, required this.query, this.type = 'string'});

  factory ColumnDef.fromJson(Json j) =>
      ColumnDef(name: j['name'] ?? '', query: j['query'] ?? '', type: (j['type'] as String?)?.isNotEmpty == true ? j['type'] : 'string');

  Json toJson() => {'name': name, 'query': query, if (type != 'string') 'type': type};

  ColumnDef copyWith({String? name, String? query, String? type}) =>
      ColumnDef(name: name ?? this.name, query: query ?? this.query, type: type ?? this.type);
}

class TableRowData {
  final String uid;
  final String name;
  final String? namespace;
  final String resourceVersion;
  final List<dynamic> cells;
  final Json? object;

  /// A controller owns the object (e.g. a ReplicaSet's pod): deleting it
  /// makes the controller recreate it.
  final bool controlled;

  const TableRowData({
    required this.uid,
    required this.name,
    this.namespace,
    required this.resourceVersion,
    required this.cells,
    this.object,
    this.controlled = false,
  });

  factory TableRowData.fromJson(Json j) => TableRowData(
        uid: j['uid'] ?? '',
        name: j['name'] ?? '',
        namespace: j['namespace'],
        resourceVersion: j['resourceVersion'] ?? '',
        cells: List<dynamic>.from(j['cells'] ?? const []),
        object: j['object'],
        controlled: j['controlled'] == true,
      );
}

class TableData {
  final ResourceType resource;
  final List<ColumnDef> columns;
  final bool isDefaultColumns;
  final String resourceVersion;
  final List<TableRowData> rows;

  /// column index → first jq error seen evaluating that column.
  final Map<int, String> columnErrors;

  const TableData({
    required this.resource,
    required this.columns,
    required this.isDefaultColumns,
    required this.resourceVersion,
    required this.rows,
    this.columnErrors = const {},
  });

  factory TableData.fromJson(Json j) => TableData(
        resource: ResourceType.fromJson(j['resource']),
        columns: [for (final c in (j['columns'] as List? ?? const [])) ColumnDef.fromJson(c)],
        isDefaultColumns: j['isDefaultColumns'] ?? false,
        resourceVersion: j['resourceVersion'] ?? '',
        rows: [for (final r in (j['rows'] as List? ?? const [])) TableRowData.fromJson(r)],
        columnErrors: {
          for (final e in ((j['columnErrors'] as Map?) ?? const {}).entries) int.parse(e.key.toString()): e.value.toString()
        },
      );
}

/// A frame from /api/watch.
class WatchMessage {
  /// SNAPSHOT | ADDED | MODIFIED | DELETED | ERROR | BATCH
  final String type;
  final TableData? table;
  final TableRowData? row;
  final String? error;

  /// On ERROR (newer backends): Unreachable, Unauthorized, Forbidden,
  /// NotFound, Timeout or another Kubernetes StatusReason.
  final String? reason;

  /// On ERROR: the HTTP status equivalent (401, 403, 404, 502, 504, …).
  final int? code;

  /// On ERROR: the cluster API server URL.
  final String? host;

  /// On BATCH (only with `batch=true`): ADDED/MODIFIED/DELETED frames to
  /// apply in order, with one UI update for the lot.
  final List<WatchMessage> events;
  const WatchMessage({required this.type, this.table, this.row, this.error, this.reason, this.code, this.host, this.events = const []});

  factory WatchMessage.fromJson(Json j) => WatchMessage(
        type: j['type'] ?? 'ERROR',
        table: j['table'] != null ? TableData.fromJson(j['table']) : null,
        row: j['row'] != null ? TableRowData.fromJson(j['row']) : null,
        error: j['error'],
        reason: j['reason'],
        code: j['code'],
        host: j['host'],
        events: [for (final e in (j['events'] as List? ?? const [])) WatchMessage.fromJson(Map<String, dynamic>.from(e))],
      );
}

/// A frame from /api/logs.
class LogMessage {
  final String? line;
  final String? error;
  final bool eof;
  const LogMessage({this.line, this.error, this.eof = false});
  factory LogMessage.fromJson(Json j) => LogMessage(line: j['line'], error: j['error'], eof: j['eof'] ?? false);
}

class ContextInfo {
  final String name;
  final String cluster;
  final String user;
  final String? namespace;

  /// API server URL (newer backends).
  final String? server;

  /// Exec credential plugin or auth provider, e.g. "kubelogin", "aws"; null
  /// for static credentials. Such plugins may wait for a browser login.
  final String? auth;
  const ContextInfo({required this.name, required this.cluster, required this.user, this.namespace, this.server, this.auth});
  factory ContextInfo.fromJson(Json j) => ContextInfo(
      name: j['name'] ?? '',
      cluster: j['cluster'] ?? '',
      user: j['user'] ?? '',
      namespace: j['namespace'],
      server: j['server'],
      auth: j['auth']);
}

class ColumnsConfig {
  final List<ColumnDef> columns;
  final List<ColumnDef> defaults;
  final bool isDefault;
  const ColumnsConfig({required this.columns, required this.defaults, required this.isDefault});
  factory ColumnsConfig.fromJson(Json j) => ColumnsConfig(
        columns: [for (final c in (j['columns'] as List? ?? const [])) ColumnDef.fromJson(c)],
        defaults: [for (final c in (j['defaults'] as List? ?? const [])) ColumnDef.fromJson(c)],
        isDefault: j['isDefault'] ?? false,
      );
}

/// Points at one object, e.g. from an ownerReference or a pod's nodeName.
class ObjectRef {
  final String group;
  final String kind;
  final String name;
  final String? namespace;
  const ObjectRef({this.group = '', required this.kind, required this.name, this.namespace});

  /// From an ownerReference / objectReference-like map with apiVersion+kind.
  factory ObjectRef.fromOwnerRef(Json j, {String? namespace}) {
    final apiVersion = (j['apiVersion'] ?? 'v1') as String;
    final group = apiVersion.contains('/') ? apiVersion.split('/').first : '';
    return ObjectRef(group: group, kind: j['kind'] ?? '', name: j['name'] ?? '', namespace: j['namespace'] ?? namespace);
  }

  @override
  String toString() => '$kind/${namespace != null ? '$namespace/' : ''}$name';
}

class UpdateResult {
  final bool dryRun;
  final String resourceVersion;
  final String yaml;
  final String context;
  const UpdateResult({required this.dryRun, required this.resourceVersion, required this.yaml, required this.context});
  factory UpdateResult.fromJson(Json j) =>
      UpdateResult(dryRun: j['dryRun'] ?? false, resourceVersion: j['resourceVersion'] ?? '', yaml: j['yaml'] ?? '', context: j['context'] ?? '');
}

/// `POST /api/apply`: one result per object in the submitted documents.
class ManifestResult {
  final bool dryRun;

  /// `create`, or `apply` for server-side apply.
  final String mode;
  final String context;
  final List<ManifestItem> results;
  const ManifestResult({required this.dryRun, this.mode = 'create', this.context = '', required this.results});
  factory ManifestResult.fromJson(Json j) => ManifestResult(
        dryRun: j['dryRun'] ?? false,
        mode: j['mode'] ?? 'create',
        context: j['context'] ?? '',
        results: [for (final r in (j['results'] as List? ?? const [])) ManifestItem.fromJson(Map<String, dynamic>.from(r))],
      );
  bool get ok => results.every((r) => r.ok);
}

class ManifestItem {
  /// Document index, and the document's first line (1-based) in the body.
  final int index;
  final int line;
  final String group;
  final String version;
  final String kind;
  final String? namespace;
  final String name;
  final bool created;
  final String? error;

  /// Kubernetes StatusReason, e.g. AlreadyExists, Invalid, Conflict.
  final String? reason;
  final List<Map<String, dynamic>> causes;
  const ManifestItem({
    this.index = 0,
    this.line = 1,
    this.group = '',
    this.version = '',
    required this.kind,
    this.namespace,
    required this.name,
    this.created = false,
    this.error,
    this.reason,
    this.causes = const [],
  });
  factory ManifestItem.fromJson(Json j) => ManifestItem(
        index: j['index'] ?? 0,
        line: j['line'] ?? 1,
        group: j['group'] ?? '',
        version: j['version'] ?? '',
        kind: j['kind'] ?? '',
        namespace: j['namespace'],
        name: j['name'] ?? '',
        created: j['created'] ?? false,
        error: j['error'],
        reason: j['reason'],
        causes: [for (final c in (j['causes'] as List? ?? const [])) Map<String, dynamic>.from(c)],
      );
  bool get ok => error == null || error!.isEmpty;
  ObjectRef get ref => ObjectRef(group: group, kind: kind, name: name, namespace: namespace);
}

class ActionResult {
  final String message;
  final bool dryRun;
  final String context;

  /// Object created by the action (e.g. the Job from a CronJob trigger).
  final ObjectRef? created;
  const ActionResult({required this.message, this.dryRun = false, this.context = '', this.created});
  factory ActionResult.fromJson(Json j) => ActionResult(
        message: j['message'] ?? '',
        dryRun: j['dryRun'] ?? false,
        context: j['context'] ?? '',
        created: j['created'] == null
            ? null
            : ObjectRef(group: j['created']['group'] ?? '', kind: j['created']['kind'] ?? '', name: j['created']['name'] ?? '', namespace: j['created']['namespace']),
      );
}

class PortForward {
  final String id;
  final String context;
  final String namespace;
  final String kind;
  final String name;
  final String port;
  final int localPort;
  final String address;
  final bool autoStart;
  final String? label;

  /// stopped | starting | active | reconnecting | error
  final String state;
  final String? pod;
  final int? remotePort;
  final String? error;
  final DateTime? since;
  final int reconnects;
  final int connections;
  final String? url;

  const PortForward({
    required this.id,
    required this.context,
    required this.namespace,
    required this.kind,
    required this.name,
    required this.port,
    required this.localPort,
    this.address = '127.0.0.1',
    this.autoStart = false,
    this.label,
    required this.state,
    this.pod,
    this.remotePort,
    this.error,
    this.since,
    this.reconnects = 0,
    this.connections = 0,
    this.url,
  });

  factory PortForward.fromJson(Json j) => PortForward(
        id: j['id'] ?? '',
        context: j['context'] ?? '',
        namespace: j['namespace'] ?? '',
        kind: j['kind'] ?? '',
        name: j['name'] ?? '',
        port: '${j['port'] ?? ''}',
        localPort: j['localPort'] ?? 0,
        address: j['address'] ?? '127.0.0.1',
        autoStart: j['autoStart'] ?? false,
        label: j['label'],
        state: j['state'] ?? 'stopped',
        pod: j['pod'],
        remotePort: j['remotePort'],
        error: j['error'],
        since: j['since'] != null && !(j['since'] as String).startsWith('0001') ? DateTime.tryParse(j['since']) : null,
        reconnects: j['reconnects'] ?? 0,
        connections: j['connections'] ?? 0,
        url: j['url'],
      );

  String get target => '$kind/$name:$port';
}

List<String> _strings(Object? v) => [for (final e in (v as List? ?? const [])) '$e'];

/// `GET /api/nodes/drain-plan`: what a drain would evict, skip, or refuse.
class DrainPlan {
  final String node;
  final List<String> evict;
  final List<String> warnings;
  final List<String> blockers;
  const DrainPlan({required this.node, this.evict = const [], this.warnings = const [], this.blockers = const []});
  factory DrainPlan.fromJson(Json j) =>
      DrainPlan(node: '${j['node'] ?? ''}', evict: _strings(j['evict']), warnings: _strings(j['warnings']), blockers: _strings(j['blockers']));
}

/// `POST /api/nodes/drain`: the pods evicted, and why it stopped short if it did.
class DrainResult {
  final String node;
  final List<String> evicted;
  final String? error;
  const DrainResult({required this.node, this.evicted = const [], this.error});
  factory DrainResult.fromJson(Json j) =>
      DrainResult(node: '${j['node'] ?? ''}', evicted: _strings(j['evicted']), error: (j['error'] as String?)?.isEmpty ?? true ? null : j['error'] as String);
}
