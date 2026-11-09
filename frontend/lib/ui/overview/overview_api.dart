/// Client and models for `GET /api/overview` (cluster health summary).
library;

import '../../state/namespace_scope.dart';
import 'package:http/http.dart' as http;

import '../../api/backend_http.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/cluster_error.dart';
import '../../util/k8s.dart';
import '../widgets/partial_banner.dart' show parsePartialErrors;

/// Fetches the health overview from the backend behind an [ApiClient],
/// reusing its base URL. Tests subclass this to serve canned JSON.
class OverviewApi {
  final ApiClient api;
  final BackendHttp _http;
  OverviewApi(this.api, {http.Client? httpClient}) : _http = BackendHttp(api, '/api/', httpClient: httpClient);

  /// [scope]: all namespaces, one, or a set.
  Future<OverviewData> fetch({NamespaceScope scope = NamespaceScope.all}) async =>
      OverviewData.fromJson(jsonObjectBody(await _http.get('overview', scope.query)));
}

enum IssueSeverity {
  critical,
  warning,
  info;

  static IssueSeverity parse(dynamic s) => switch (s) {
        'critical' => critical,
        'warning' => warning,
        _ => info,
      };

  /// Maps onto the app-wide badge colours.
  Severity get badge => switch (this) {
        critical => Severity.error,
        warning => Severity.warn,
        info => Severity.info,
      };
}

class OverviewOwner {
  final String group;
  final String kind;
  final String name;
  const OverviewOwner({required this.group, required this.kind, required this.name});

  static OverviewOwner? fromJson(dynamic j) =>
      j is Map ? OverviewOwner(group: '${j['group'] ?? ''}', kind: '${j['kind'] ?? ''}', name: '${j['name'] ?? ''}') : null;

  @override
  bool operator ==(Object other) => other is OverviewOwner && other.group == group && other.kind == kind && other.name == name;
  @override
  int get hashCode => Object.hash(group, kind, name);
}

class OverviewIssue {
  final IssueSeverity severity;
  final String category;
  final String kind;
  final String group;
  final String? namespace;
  final String name;
  final String reason;
  final String message;
  final String? since;
  final int count;
  final OverviewOwner? owner;

  const OverviewIssue({
    required this.severity,
    required this.category,
    required this.kind,
    required this.group,
    required this.name,
    required this.reason,
    required this.message,
    this.namespace,
    this.since,
    this.count = 0,
    this.owner,
  });

  factory OverviewIssue.fromJson(Json j) => OverviewIssue(
        severity: IssueSeverity.parse(j['severity']),
        category: '${j['category'] ?? ''}',
        kind: '${j['kind'] ?? ''}',
        group: '${j['group'] ?? ''}',
        namespace: (j['namespace'] as String?)?.isEmpty == true ? null : j['namespace'] as String?,
        name: '${j['name'] ?? ''}',
        reason: '${j['reason'] ?? ''}',
        message: '${j['message'] ?? ''}',
        since: j['since'] as String?,
        count: (j['count'] as num?)?.toInt() ?? 0,
        owner: OverviewOwner.fromJson(j['owner']),
      );

  ObjectRef get ref => ObjectRef(group: group, kind: kind, name: name, namespace: namespace);
}

class OverviewCategory {
  final String id;
  final String label;
  final String section;
  final IssueSeverity severity;
  final int count;
  const OverviewCategory({required this.id, required this.label, required this.section, required this.severity, required this.count});

  factory OverviewCategory.fromJson(Json j) => OverviewCategory(
        id: '${j['id']}',
        label: '${j['label'] ?? j['id']}',
        section: '${j['section'] ?? ''}',
        severity: IssueSeverity.parse(j['severity']),
        count: (j['count'] as num?)?.toInt() ?? 0,
      );
}

class NodeHealth {
  final String name;
  final bool ready;
  final bool cordoned;
  final List<String> pressure;
  final List<String> roles;
  final String version;
  final int pods;
  const NodeHealth({required this.name, required this.ready, this.cordoned = false, this.pressure = const [], this.roles = const [], this.version = '', this.pods = 0});

  factory NodeHealth.fromJson(Json j) => NodeHealth(
        name: '${j['name']}',
        ready: j['ready'] == true,
        cordoned: j['cordoned'] == true,
        pressure: List<String>.from(j['pressure'] ?? const []),
        roles: List<String>.from(j['roles'] ?? const []),
        version: '${j['version'] ?? ''}',
        pods: (j['pods'] as num?)?.toInt() ?? 0,
      );
}

class WarningReason {
  final String reason;
  final int count;
  final int objects;
  final String latestMessage;
  final String? lastSeen;
  final ObjectRef? example;
  const WarningReason({required this.reason, required this.count, required this.objects, required this.latestMessage, this.lastSeen, this.example});

  factory WarningReason.fromJson(Json j) {
    final ex = asMap(j['example']);
    return WarningReason(
      reason: '${j['reason'] ?? ''}',
      count: (j['count'] as num?)?.toInt() ?? 0,
      objects: (j['objects'] as num?)?.toInt() ?? 0,
      latestMessage: '${j['latestMessage'] ?? ''}',
      lastSeen: j['lastSeen'] as String?,
      example: ex['name'] == null
          ? null
          : ObjectRef(
              group: '${ex['group'] ?? ''}',
              kind: '${ex['kind'] ?? ''}',
              name: '${ex['name']}',
              namespace: (ex['namespace'] as String?)?.isEmpty == true ? null : ex['namespace'] as String?,
            ),
    );
  }
}

class OverviewData {
  final String? generatedAt;
  final String namespace;

  /// Raw per-type tallies: `counts['pods']['crashLoop']` etc.
  final Json counts;
  final List<OverviewCategory> categories;
  final List<OverviewIssue> issues;
  final List<NodeHealth> nodes;
  final List<WarningReason> topWarnings;

  /// Lists the backend could not read (e.g. nodes when RBAC forbids it).
  final Map<String, String> errors;

  /// Namespaces of the set that could not be read (RBAC); the rest is
  /// analysed.
  final Map<String, ClusterError> partialErrors;

  /// Sources the backend had not finished when it answered (`deployments`,
  /// `alerts`, `argocd`, ...). What they feed is unknown, not zero: tiles
  /// and sections for them show placeholders until a later fetch has them.
  final Set<String> pending;

  const OverviewData({
    this.generatedAt,
    this.namespace = '',
    this.counts = const {},
    this.categories = const [],
    this.issues = const [],
    this.nodes = const [],
    this.topWarnings = const [],
    this.errors = const {},
    this.partialErrors = const {},
    this.pending = const {},
  });

  factory OverviewData.fromJson(Json j) => OverviewData(
        generatedAt: j['generatedAt'] as String?,
        namespace: '${j['namespace'] ?? ''}',
        counts: asMap(j['counts']),
        categories: [for (final c in asMapList(j['categories'])) OverviewCategory.fromJson(c)],
        issues: [for (final i in asMapList(j['issues'])) OverviewIssue.fromJson(i)],
        nodes: [for (final n in asMapList(j['nodes'])) NodeHealth.fromJson(n)],
        topWarnings: [for (final w in asMapList(j['topWarnings'])) WarningReason.fromJson(w)],
        errors: {for (final e in asMap(j['errors']).entries) e.key: '${e.value}'},
        partialErrors: parsePartialErrors(j['partialErrors']),
        pending: {for (final p in (j['pending'] as List?) ?? const []) '$p'},
      );

  /// Whether source [name] is still loading.
  bool isPending(String name) => pending.contains(name);

  /// Summary-tile sections (the backend's category sections) with a source
  /// still loading, in display order.
  List<String> get loadingSections {
    const sources = {
      'nodes': ['nodes'],
      'alerts': ['alerts'],
      'workloads': ['deployments', 'statefulsets', 'daemonsets'],
      'jobs': ['jobs', 'cronjobs', 'workflows'],
      'storage': ['pvcs'],
      'argocd': ['argocd'],
      'network': ['gateway'],
    };
    final known = {for (final v in sources.values) ...v, 'pods', 'replicasets', 'events'};
    return [
      for (final e in sources.entries)
        if (e.value.any(pending.contains)) e.key,
      // A module's own section (e.g. hubble).
      for (final p in pending.toList()..sort())
        if (!known.contains(p)) p,
    ];
  }

  int count(String type, String field) => (dig<num>(counts, [type, field]) ?? 0).toInt();

  /// Problems worth a tile (critical or warning).
  bool get healthy => !categories.any((c) => c.severity != IssueSeverity.info);
}

/// Issues that share a namespace, category and top-level owner, e.g.
/// "3 pods of Deployment web are CrashLoopBackOff". Issues without an owner
/// form a group of one.
class IssueGroup {
  final List<OverviewIssue> issues;
  IssueGroup(this.issues);

  OverviewIssue get first => issues.first;

  /// The workload the group is about. Issues are keyed by their owner, or by
  /// their own object when they have none, so one group can mix both, e.g.
  /// an alert on a Deployment plus pod alerts owned by it. Take the first
  /// owner present rather than assuming the first issue has one.
  OverviewOwner? get owner {
    for (final i in issues) {
      if (i.owner != null) return i.owner;
    }
    return null;
  }

  /// [owner], or the first issue's own object when no issue has an owner
  /// (e.g. several alerts on the same Deployment). Never null.
  OverviewOwner get subject => owner ?? OverviewOwner(group: first.group, kind: first.kind, name: first.name);
  IssueSeverity get severity => first.severity;
  bool get isGroup => owner != null;
  String get category => first.category;
  String? get namespace => first.namespace;

  /// Most recent `since` of the group.
  String? get latestSince {
    String? best;
    DateTime? bestT;
    for (final i in issues) {
      final t = parseTime(i.since);
      if (t != null && (bestT == null || t.isAfter(bestT))) {
        bestT = t;
        best = i.since;
      }
    }
    return best;
  }

  /// Identifier for expansion state.
  String get key => '${first.namespace}/${subject.group}/${subject.kind}/${subject.name}/$category';
}

/// Groups issues by (namespace, owner, category), keeping the backend's order
/// (severity, then recency) by first appearance.
List<IssueGroup> groupIssues(Iterable<OverviewIssue> issues) {
  final byKey = <String, List<OverviewIssue>>{};
  for (final i in issues) {
    final k = i.owner != null
        ? '${i.namespace}/${i.owner!.group}/${i.owner!.kind}/${i.owner!.name}/${i.category}/${i.severity.name}'
        : '${i.namespace}/${i.group}/${i.kind}/${i.name}/${i.category}/${i.severity.name}';
    byKey.putIfAbsent(k, () => []).add(i);
  }
  return [for (final l in byKey.values) IssueGroup(l)];
}
