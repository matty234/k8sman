/// Client and models for the RBAC workspace endpoints (`/api/rbac/*`).
library;

import 'package:http/http.dart' as http;

import '../../api/backend_http.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../util/k8s.dart';

const rbacApiGroup = 'rbac.authorization.k8s.io';

String _s(dynamic v) => v == null ? '' : '$v';
List<String> _strs(dynamic v) => v is List ? [for (final e in v) '$e'] : const [];
List<int> _ints(dynamic v) => v is List ? [for (final e in v) (e as num).toInt()] : const [];

/// A User, Group or ServiceAccount.
class RbacSubject {
  final String kind;
  final String name;

  /// ServiceAccounts only.
  final String? namespace;
  const RbacSubject({required this.kind, required this.name, this.namespace});
  const RbacSubject.sa(String this.namespace, this.name) : kind = 'ServiceAccount';
  const RbacSubject.user(this.name)
      : kind = 'User',
        namespace = null;
  const RbacSubject.group(this.name)
      : kind = 'Group',
        namespace = null;

  factory RbacSubject.fromJson(Json j) {
    final ns = _s(j['namespace']);
    return RbacSubject(kind: _s(j['kind']), name: _s(j['name']), namespace: ns.isEmpty ? null : ns);
  }

  bool get isServiceAccount => kind == 'ServiceAccount';

  /// "rbac-demo/app" for ServiceAccounts, else the name.
  String get label => isServiceAccount ? '$namespace/$name' : name;

  /// The binding-subject JSON (apiGroup for users and groups).
  Json toSubjectJson() => isServiceAccount
      ? {'kind': kind, 'name': name, 'namespace': namespace}
      : {'kind': kind, 'apiGroup': rbacApiGroup, 'name': name};

  Json toJson() => {'kind': kind, 'name': name, if (namespace != null) 'namespace': namespace};

  ObjectRef? get objectRef => isServiceAccount ? ObjectRef(kind: 'ServiceAccount', name: name, namespace: namespace) : null;

  @override
  bool operator ==(Object other) => other is RbacSubject && other.kind == kind && other.name == name && other.namespace == namespace;
  @override
  int get hashCode => Object.hash(kind, name, namespace);
  @override
  String toString() => '$kind $label';
}

/// Plain-English description of the well-known groups.
String? wellKnownGroup(String name) => switch (name) {
      'system:authenticated' => 'every authenticated user and ServiceAccount',
      'system:unauthenticated' => 'anonymous requests',
      'system:serviceaccounts' => 'every ServiceAccount in every namespace',
      'system:masters' => 'cluster superusers (bypasses RBAC)',
      'system:nodes' => 'kubelets',
      _ when name.startsWith('system:serviceaccounts:') => 'every ServiceAccount in ${name.substring('system:serviceaccounts:'.length)}',
      _ => null,
    };

class SubjectInfo {
  final RbacSubject subject;
  final int bindings;
  final bool exists;
  const SubjectInfo(this.subject, {this.bindings = 0, this.exists = true});
  factory SubjectInfo.fromJson(Json j) => SubjectInfo(RbacSubject.fromJson(j), bindings: (j['bindings'] as num?)?.toInt() ?? 0, exists: j['exists'] != false);
}

class SubjectList {
  final List<SubjectInfo> serviceAccounts;
  final List<SubjectInfo> users;
  final List<SubjectInfo> groups;
  final String? serviceAccountsError;
  const SubjectList({this.serviceAccounts = const [], this.users = const [], this.groups = const [], this.serviceAccountsError});
  factory SubjectList.fromJson(Json j) => SubjectList(
        serviceAccounts: [for (final s in asMapList(j['serviceAccounts'])) SubjectInfo.fromJson(s)],
        users: [for (final s in asMapList(j['users'])) SubjectInfo.fromJson(s)],
        groups: [for (final s in asMapList(j['groups'])) SubjectInfo.fromJson(s)],
        serviceAccountsError: j['serviceAccountsError'] as String?,
      );
}

/// An RBAC object reference (Role, ClusterRole, binding, or a pseudo source
/// such as "SelfSubjectRulesReview").
class RbacRef {
  final String kind;
  final String name;
  final String? namespace;
  const RbacRef(this.kind, this.name, [this.namespace]);
  factory RbacRef.fromJson(Json j) {
    final ns = _s(j['namespace']);
    return RbacRef(_s(j['kind']), _s(j['name']), ns.isEmpty ? null : ns);
  }
  bool get isEmpty => kind.isEmpty;
  ObjectRef get objectRef => ObjectRef(group: rbacApiGroup, kind: kind, name: name, namespace: namespace);
  String get label => namespace == null ? name : '$namespace/$name';
  @override
  bool operator ==(Object other) => other is RbacRef && other.kind == kind && other.name == name && other.namespace == namespace;
  @override
  int get hashCode => Object.hash(kind, name, namespace);
}

class PolicyRuleData {
  final List<String> verbs;
  final List<String> apiGroups;
  final List<String> resources;
  final List<String> resourceNames;
  final List<String> nonResourceURLs;
  const PolicyRuleData({this.verbs = const [], this.apiGroups = const [], this.resources = const [], this.resourceNames = const [], this.nonResourceURLs = const []});
  factory PolicyRuleData.fromJson(Json j) => PolicyRuleData(
        verbs: _strs(j['verbs']),
        apiGroups: _strs(j['apiGroups']),
        resources: _strs(j['resources']),
        resourceNames: _strs(j['resourceNames']),
        nonResourceURLs: _strs(j['nonResourceURLs']),
      );

  /// One line: "get, list on pods, pods/log (core) names: a, b".
  String get summary {
    if (nonResourceURLs.isNotEmpty) return '${verbs.join(', ')} on ${nonResourceURLs.join(', ')}';
    final groups = apiGroups.map((g) => g.isEmpty ? 'core' : g).join(', ');
    final names = resourceNames.isEmpty ? '' : ' · only ${resourceNames.join(', ')}';
    return '${verbs.join(', ')} on ${resources.join(', ')} ($groups)$names';
  }
}

/// One way a subject is granted something: binding → role → rule.
class GrantPath {
  final RbacRef binding;
  final RbacRef role;
  final bool roleMissing;
  final RbacSubject? subject;
  final String scope;
  final PolicyRuleData rule;
  final RbacRef source;
  final int index;
  final List<String> via;
  const GrantPath({
    required this.binding,
    required this.role,
    this.roleMissing = false,
    this.subject,
    required this.scope,
    required this.rule,
    required this.source,
    this.index = 0,
    this.via = const [],
  });

  factory GrantPath.fromJson(Json j) {
    final r = asMap(j['rule']);
    final sub = asMap(j['subject']);
    return GrantPath(
      binding: RbacRef.fromJson(asMap(j['binding'])),
      role: RbacRef.fromJson(asMap(j['role'])),
      roleMissing: j['roleMissing'] == true,
      subject: _s(sub['kind']).isEmpty ? null : RbacSubject.fromJson(sub),
      scope: _s(j['scope']),
      rule: PolicyRuleData.fromJson(asMap(r['rule'])),
      source: RbacRef.fromJson(asMap(r['source'])),
      index: (r['index'] as num?)?.toInt() ?? 0,
      via: _strs(r['via']),
    );
  }

  bool get fullWildcard => rule.verbs.contains('*') && rule.resources.contains('*') && rule.apiGroups.contains('*');
  bool get aggregated => source != role;
}

class MatrixCell {
  final List<int> paths;
  final List<String> names;
  final String? danger;
  const MatrixCell({this.paths = const [], this.names = const [], this.danger});
  factory MatrixCell.fromJson(Json j) => MatrixCell(paths: _ints(j['paths']), names: _strs(j['names']), danger: j['danger'] as String?);

  /// Allowed only for specific objects (resourceNames).
  bool get limited => names.isNotEmpty;
}

class MatrixRow {
  final String group;
  final String resource;
  final String kind;
  final bool namespaced;
  final bool virtual;
  final List<String> verbs;
  final Map<String, MatrixCell> cells;
  const MatrixRow({required this.group, required this.resource, this.kind = '', this.namespaced = true, this.virtual = false, this.verbs = const [], this.cells = const {}});
  factory MatrixRow.fromJson(Json j) => MatrixRow(
        group: _s(j['group']),
        resource: _s(j['resource']),
        kind: _s(j['kind']),
        namespaced: j['namespaced'] == true,
        virtual: j['virtual'] == true,
        verbs: _strs(j['verbs']),
        cells: {for (final e in asMap(j['cells']).entries) e.key: MatrixCell.fromJson(asMap(e.value))},
      );

  String get groupLabel => group.isEmpty ? 'core' : group;
  bool get isSubresource => resource.contains('/');
  String get key => '$group/$resource';

  /// Whether the API serves [verb] on this resource (unknown = yes).
  bool supports(String verb) =>
      verbs.isEmpty || verb == '*' || verbs.contains(verb) || const {'escalate', 'bind', 'impersonate'}.contains(verb) && _special(verb);

  bool _special(String verb) => switch (verb) {
        'escalate' || 'bind' => group == rbacApiGroup && (resource == 'roles' || resource == 'clusterroles'),
        'impersonate' => resource == 'users' || resource == 'groups' || resource == 'serviceaccounts' || resource == 'uids' || resource.startsWith('userextras'),
        _ => false,
      };
}

class NonResourceGrant {
  final List<String> urls;
  final List<String> verbs;
  final List<int> paths;
  const NonResourceGrant(this.urls, this.verbs, this.paths);
  factory NonResourceGrant.fromJson(Json j) => NonResourceGrant(_strs(j['urls']), _strs(j['verbs']), _ints(j['paths']));
}

class BindingSummary {
  final RbacRef binding;
  final RbacRef role;
  final bool roleMissing;
  final RbacSubject subject;
  final String scope;
  final bool inherited;
  const BindingSummary({required this.binding, required this.role, this.roleMissing = false, required this.subject, required this.scope, this.inherited = false});
  factory BindingSummary.fromJson(Json j) => BindingSummary(
        binding: RbacRef.fromJson(asMap(j['binding'])),
        role: RbacRef.fromJson(asMap(j['role'])),
        roleMissing: j['roleMissing'] == true,
        subject: RbacSubject.fromJson(asMap(j['subject'])),
        scope: _s(j['scope']),
        inherited: j['inherited'] == true,
      );
}

class Identity {
  final String user;
  final List<String> groups;
  const Identity(this.user, this.groups);
  factory Identity.fromJson(Json j) => Identity(_s(j['user']), _strs(j['groups']));
}

/// A subject's effective permissions as a resource × verb matrix.
class PermissionMatrixData {
  final RbacSubject? subject;
  final Identity identity;
  final String namespace;
  final List<String> verbs;
  final List<MatrixRow> rows;
  final List<GrantPath> paths;
  final List<NonResourceGrant> nonResource;
  final bool fullWildcard;
  final List<BindingSummary> bindings;
  final List<String> roleBindingNamespaces;
  final List<RbacRef> missingRoles;
  const PermissionMatrixData({
    this.subject,
    this.identity = const Identity('', []),
    this.namespace = '',
    this.verbs = const [],
    this.rows = const [],
    this.paths = const [],
    this.nonResource = const [],
    this.fullWildcard = false,
    this.bindings = const [],
    this.roleBindingNamespaces = const [],
    this.missingRoles = const [],
  });

  factory PermissionMatrixData.fromJson(Json j) => PermissionMatrixData(
        subject: j['subject'] is Map ? RbacSubject.fromJson(asMap(j['subject'])) : null,
        identity: Identity.fromJson(asMap(j['identity'])),
        namespace: _s(j['namespace']),
        verbs: _strs(j['verbs']),
        rows: [for (final r in asMapList(j['rows'])) MatrixRow.fromJson(r)],
        paths: [for (final p in asMapList(j['paths'])) GrantPath.fromJson(p)],
        nonResource: [for (final n in asMapList(j['nonResource'])) NonResourceGrant.fromJson(n)],
        fullWildcard: j['fullWildcard'] == true,
        bindings: [for (final b in asMapList(j['bindings'])) BindingSummary.fromJson(b)],
        roleBindingNamespaces: _strs(j['roleBindingNamespaces']),
        missingRoles: [for (final r in asMapList(j['missingRoles'])) RbacRef.fromJson(r)],
      );

  int get grantedCells => rows.fold(0, (n, r) => n + r.cells.length);
  int get dangerousCells => rows.fold(0, (n, r) => n + r.cells.values.where((c) => c.danger != null).length);
}

class WhoCanEntry {
  final RbacSubject subject;
  final List<GrantPath> paths;
  final bool partial;
  final List<String> names;
  final bool fullWildcard;
  final List<String> scopes;
  const WhoCanEntry({required this.subject, this.paths = const [], this.partial = false, this.names = const [], this.fullWildcard = false, this.scopes = const []});
  factory WhoCanEntry.fromJson(Json j) => WhoCanEntry(
        subject: RbacSubject.fromJson(asMap(j['subject'])),
        paths: [for (final p in asMapList(j['paths'])) GrantPath.fromJson(p)],
        partial: j['partial'] == true,
        names: _strs(j['names']),
        fullWildcard: j['fullWildcard'] == true,
        scopes: _strs(j['scopes']),
      );
}

/// An authorization question.
class AccessRequest {
  final String verb;
  final String group;

  /// "pods" or "pods/exec".
  final String resource;

  /// null = cluster-wide, "*" = any namespace (who-can only).
  final String? namespace;
  final String? name;
  final String? path;
  const AccessRequest({required this.verb, this.group = '', this.resource = '', this.namespace, this.name, this.path});

  Map<String, String?> toQuery() => {'verb': verb, 'group': group, 'resource': resource, 'namespace': namespace, 'resourceName': name, 'path': path};
  Json toJson() => {
        'verb': verb,
        'group': group,
        'resource': resource,
        if (namespace != null && namespace!.isNotEmpty) 'namespace': namespace,
        if (name != null && name!.isNotEmpty) 'name': name,
        if (path != null && path!.isNotEmpty) 'path': path,
      };

  String get label {
    if (path != null && path!.isNotEmpty) return '$verb $path';
    final g = group.isEmpty ? '' : '.$group';
    final n = name == null || name!.isEmpty ? '' : ' $name';
    return '$verb $resource$g$n';
  }
}

class WhoCanResult {
  final String? danger;
  final List<WhoCanEntry> entries;
  const WhoCanResult({this.danger, this.entries = const []});
  factory WhoCanResult.fromJson(Json j) => WhoCanResult(
        danger: j['danger'] as String?,
        entries: [for (final e in asMapList(j['entries'])) WhoCanEntry.fromJson(e)],
      );
}

class SelfAccess {
  final Identity? identity;

  /// "SelfSubjectReview" or "client certificate".
  final String identitySource;
  final String? identityError;
  final String evaluatedIn;
  final PermissionMatrixData matrix;
  final bool incomplete;
  final String? evaluationError;
  final bool readOnly;
  final String context;
  const SelfAccess({this.identity, this.identitySource = '', this.identityError, required this.evaluatedIn, required this.matrix, this.incomplete = false, this.evaluationError, this.readOnly = false, this.context = ''});
  factory SelfAccess.fromJson(Json j) => SelfAccess(
        identity: j['identity'] is Map ? Identity.fromJson(asMap(j['identity'])) : null,
        identitySource: _s(j['identitySource']),
        identityError: j['identityError'] as String?,
        evaluatedIn: _s(j['evaluatedIn']),
        matrix: PermissionMatrixData.fromJson(asMap(j['matrix'])),
        incomplete: j['incomplete'] == true,
        evaluationError: j['evaluationError'] as String?,
        readOnly: j['readOnly'] == true,
        context: _s(j['context']),
      );
}

class CheckResult {
  final bool allowed;
  final bool denied;
  final String reason;
  final String? evaluationError;
  final Identity? identity;

  /// The local resolver's answer (null if RBAC couldn't be listed).
  final bool? resolverAllowed;
  final List<GrantPath> resolverPaths;
  final bool? agree;
  const CheckResult({required this.allowed, this.denied = false, this.reason = '', this.evaluationError, this.identity, this.resolverAllowed, this.resolverPaths = const [], this.agree});
  factory CheckResult.fromJson(Json j) {
    final res = j['resolver'] is Map ? asMap(j['resolver']) : null;
    return CheckResult(
      allowed: j['allowed'] == true,
      denied: j['denied'] == true,
      reason: _s(j['reason']),
      evaluationError: j['evaluationError'] as String?,
      identity: j['identity'] is Map ? Identity.fromJson(asMap(j['identity'])) : null,
      resolverAllowed: res == null ? null : res['allowed'] == true,
      resolverPaths: res == null ? const [] : [for (final p in asMapList(res['paths'])) GrantPath.fromJson(p)],
      agree: j['agree'] as bool?,
    );
  }
}

class ApplyResult {
  final bool dryRun;
  final bool created;
  final String before;
  final String after;
  final String context;
  const ApplyResult({this.dryRun = false, this.created = false, this.before = '', this.after = '', this.context = ''});
  factory ApplyResult.fromJson(Json j) =>
      ApplyResult(dryRun: j['dryRun'] == true, created: j['created'] == true, before: _s(j['before']), after: _s(j['after']), context: _s(j['context']));
}

/// A served resource or subresource, for pickers and matrix rows.
class ApiResourceInfo {
  final String group;
  final String version;
  final String resource;
  final String kind;
  final bool namespaced;
  final List<String> verbs;
  final bool virtual;
  const ApiResourceInfo({required this.group, this.version = '', required this.resource, this.kind = '', this.namespaced = true, this.verbs = const [], this.virtual = false});
  factory ApiResourceInfo.fromJson(Json j) => ApiResourceInfo(
        group: _s(j['group']),
        version: _s(j['version']),
        resource: _s(j['resource']),
        kind: _s(j['kind']),
        namespaced: j['namespaced'] == true,
        verbs: _strs(j['verbs']),
        virtual: j['virtual'] == true,
      );
  String get groupLabel => group.isEmpty ? 'core' : group;
}

/// Talks to `/api/rbac`. Tests subclass it to serve canned data.
class AccessApi {
  final ApiClient api;
  final BackendHttp _http;
  AccessApi(this.api, {http.Client? httpClient}) : _http = BackendHttp(api, '/api/rbac', httpClient: httpClient);

  Future<SubjectList> subjects() async => SubjectList.fromJson(jsonObjectBody(await _http.get('/subjects')));

  /// [namespace] null = cluster-wide.
  Future<PermissionMatrixData> matrix(RbacSubject s, {String? namespace, List<String> groups = const []}) async =>
      PermissionMatrixData.fromJson(jsonObjectBody(await _http.get('/matrix', {
        'kind': s.kind,
        'name': s.name,
        'subjectNamespace': s.namespace,
        'namespace': namespace,
        'groups': groups.join(','),
      })));

  Future<WhoCanResult> whoCan(AccessRequest r) async => WhoCanResult.fromJson(jsonObjectBody(await _http.get('/who-can', r.toQuery())));

  Future<SelfAccess> self({String? namespace}) async => SelfAccess.fromJson(jsonObjectBody(await _http.get('/self', {'namespace': namespace})));

  /// SubjectAccessReview for [subject], or SelfSubjectAccessReview when null.
  Future<CheckResult> check(AccessRequest r, {RbacSubject? subject, List<String> groups = const []}) async => CheckResult.fromJson(jsonObjectBody(
      await _http.send('POST', '/check', body: {if (subject != null) 'subject': subject.toJson(), if (groups.isNotEmpty) 'groups': groups, 'request': r.toJson()})));

  Future<List<ApiResourceInfo>> resources() async {
    final j = jsonObjectBody(await _http.get('/resources'));
    return [
      for (final r in asMapList(j['resources'])) ApiResourceInfo.fromJson(r),
      for (final r in asMapList(j['virtual'])) ApiResourceInfo.fromJson(r),
    ];
  }

  /// Creates or replaces a Role/ClusterRole/binding. Replacing needs
  /// metadata.resourceVersion. [dryRun] persists nothing.
  Future<ApplyResult> apply(Json object, {bool dryRun = false}) async =>
      ApplyResult.fromJson(jsonObjectBody(await _http.send('POST', '/apply', query: {'dryRun': dryRun ? 'true' : null}, body: object)));
}

/// True when the API server refused because the user would grant
/// permissions they don't hold (RBAC escalation prevention).
bool isEscalationError(Object e) {
  final m = e is ApiException ? e.message : '$e';
  return m.contains('attempting to grant RBAC permissions not currently held') || m.contains('escalate');
}
