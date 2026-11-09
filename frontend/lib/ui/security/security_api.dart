/// Client and models for the security endpoints:
/// `GET /api/security`, `GET /api/security/scanner`, `POST /api/security/scan`.
library;

import '../../state/namespace_scope.dart';
import 'package:http/http.dart' as http;

import '../../api/backend_http.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/cluster_error.dart';
import '../../util/k8s.dart';
import '../widgets/partial_banner.dart' show parsePartialErrors;
import '../../util/json.dart';

/// Talks to the backend behind an [ApiClient], reusing its base URL. Tests
/// subclass this to serve canned JSON.
class SecurityApi {
  final ApiClient api;
  final BackendHttp _http;
  SecurityApi(this.api, {http.Client? httpClient}) : _http = BackendHttp(api, '/api/security', httpClient: httpClient);

  /// [scope]: all namespaces, one, or a set.
  Future<SecurityData> fetch({NamespaceScope scope = NamespaceScope.all, bool includeSystem = false}) async {
    final q = <String, String>{
      for (final e in scope.query.entries) e.key: e.value!,
      if (includeSystem) 'includeSystem': 'true',
    };
    return SecurityData.fromJson(jsonObjectBody(await _http.get('', q)));
  }

  /// The ignore rules of the current context.
  Future<List<SecIgnoreRule>> ignores() async => [for (final r in await api.getSecurityIgnores()) SecIgnoreRule.fromJson(r)];

  Future<void> _setIgnores(List<SecIgnoreRule> rules) => api.putSecurityIgnores([for (final r in rules) r.toJson()]);

  /// Adds [rules] to the current context's ignore rules.
  Future<void> addIgnores(List<SecIgnoreRule> rules) async => _setIgnores([...await ignores(), ...rules]);

  /// Removes every rule that contributes to ignoring [f].
  Future<void> unignore(SecFinding f) async => _setIgnores([for (final r in await ignores()) if (!r.relevantTo(f)) r]);

  /// Removes one rule (the settings list).
  Future<void> removeIgnore(SecIgnoreRule rule) async => _setIgnores([for (final r in await ignores()) if (!r.sameTarget(rule)) r]);

  Future<ScannerStatus> scanner() async => ScannerStatus.fromJson(jsonObjectBody(await _http.get('/scanner')));

  Future<ScanResult> scan(String image, {bool force = false}) async =>
      ScanResult.fromJson(jsonObjectBody(await _http.send('POST', '/scan', body: {'image': image, if (force) 'force': true})));
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

enum SecSeverity {
  critical,
  high,
  medium,
  low,
  info;

  static SecSeverity parse(dynamic s) => switch ('$s'.toLowerCase()) {
        'critical' => critical,
        'high' => high,
        'medium' => medium,
        'low' => low,
        _ => info,
      };

  String get label => switch (this) {
        critical => 'Critical',
        high => 'High',
        medium => 'Medium',
        low => 'Low',
        info => 'Info',
      };
}

List<Json> _maps(dynamic v) => asMapList(v);

ObjectRef refFromJson(Json j) {
  final ns = asStr(j['namespace']);
  return ObjectRef(group: asStr(j['group']), kind: asStr(j['kind']), name: asStr(j['name']), namespace: ns.isEmpty ? null : ns);
}

class SecCategory {
  final String id;
  final String title;
  final int total;
  final Map<SecSeverity, int> counts;
  const SecCategory({required this.id, required this.title, required this.total, required this.counts});

  factory SecCategory.fromJson(Json j) => SecCategory(
        id: asStr(j['id']),
        title: asStr(j['title']),
        total: asInt(j['total']),
        counts: {for (final e in asMap(j['counts']).entries) SecSeverity.parse(e.key): asInt(e.value)},
      );

  int count(SecSeverity s) => counts[s] ?? 0;

  /// Most severe level with findings, or null when there are none.
  SecSeverity? get worst => SecSeverity.values.where((s) => count(s) > 0).firstOrNull;
}

class SecFinding {
  final String id;
  final String check;
  final SecSeverity severity;
  final String category;
  final String title;
  final String detail;
  final String remediation;
  final String? namespace;
  final List<ObjectRef> objects;
  final List<String> checks;

  const SecFinding({
    required this.id,
    required this.check,
    required this.severity,
    required this.category,
    required this.title,
    required this.detail,
    required this.remediation,
    required this.objects,
    this.namespace,
    this.checks = const [],
  });

  factory SecFinding.fromJson(Json j) => SecFinding(
        id: asStr(j['id']),
        check: asStr(j['check']),
        severity: SecSeverity.parse(j['severity']),
        category: asStr(j['category']),
        title: asStr(j['title']),
        detail: asStr(j['detail']),
        remediation: asStr(j['remediation']),
        namespace: asStr(j['namespace']).isEmpty ? null : asStr(j['namespace']),
        objects: [for (final o in _maps(j['objects'])) refFromJson(o)],
        checks: [for (final c in (j['checks'] as List? ?? const [])) '$c'],
      );
}

/// What an ignore rule covers, mirroring the backend's `security.IgnoreRule`:
/// a check everywhere, in one namespace, or one target object ([kind] and
/// [name], in the object's [namespace]).
class SecIgnoreRule {
  final String check;
  final String? namespace;
  final String? kind;
  final String? name;
  final String reason;
  final String at;
  const SecIgnoreRule({required this.check, this.namespace, this.kind, this.name, this.reason = '', this.at = ''});

  factory SecIgnoreRule.fromJson(Json j) => SecIgnoreRule(
        check: asStr(j['check']),
        namespace: asStr(j['namespace']).isEmpty ? null : asStr(j['namespace']),
        kind: asStr(j['kind']).isEmpty ? null : asStr(j['kind']),
        name: asStr(j['name']).isEmpty ? null : asStr(j['name']),
        reason: asStr(j['reason']),
        at: asStr(j['at']),
      );

  Json toJson() => {
        'check': check,
        if (namespace != null) 'namespace': namespace,
        if (kind != null) 'kind': kind,
        if (name != null) 'name': name,
        if (reason.isNotEmpty) 'reason': reason,
        if (at.isNotEmpty) 'at': at,
      };

  bool get isObject => kind != null && name != null;

  bool sameTarget(SecIgnoreRule o) => check == o.check && namespace == o.namespace && kind == o.kind && name == o.name;

  bool _coversObject(ObjectRef o) => isObject && o.kind == kind && o.name == name && (namespace == null || namespace == o.namespace);

  /// Whether this rule contributes to ignoring [f].
  bool relevantTo(SecFinding f) {
    if (check != f.check) return false;
    return isObject ? f.objects.any(_coversObject) : (namespace == null || namespace == f.namespace);
  }

  /// A short description of the scope, for lists.
  String get scope {
    if (isObject) return '$kind ${namespace != null ? '$namespace/' : ''}$name';
    return namespace != null ? 'in $namespace' : 'everywhere';
  }
}

/// Whether [rules] ignore [f]: a rule for its check (everywhere or in its
/// namespace), or object rules that between them cover every one of its
/// objects. Mirrors the backend's `security.Ignoring`.
bool ignoredBy(List<SecIgnoreRule> rules, SecFinding f) {
  final mine = [for (final r in rules) if (r.check == f.check) r];
  if (mine.any((r) => !r.isObject && (r.namespace == null || r.namespace == f.namespace))) return true;
  return f.objects.isNotEmpty && f.objects.every((o) => mine.any((r) => r._coversObject(o)));
}

/// A finding hidden by [rule].
class SecIgnored {
  final SecFinding finding;
  final SecIgnoreRule rule;
  const SecIgnored(this.finding, this.rule);
}

class GrantSubject {
  final String kind;
  final String name;
  final String? namespace;
  final bool? exists;
  final bool? used;
  const GrantSubject({required this.kind, required this.name, this.namespace, this.exists, this.used});

  factory GrantSubject.fromJson(Json j) => GrantSubject(
        kind: asStr(j['kind']),
        name: asStr(j['name']),
        namespace: asStr(j['namespace']).isEmpty ? null : asStr(j['namespace']),
        exists: j['exists'] as bool?,
        used: j['used'] as bool?,
      );

  ObjectRef? get ref => kind == 'ServiceAccount' && exists != false ? ObjectRef(kind: 'ServiceAccount', name: name, namespace: namespace) : null;
}

class Grant {
  final ObjectRef binding;
  final ObjectRef role;
  final bool roleMissing;
  final String scope;
  final List<GrantSubject> subjects;
  final int score;
  final List<String> reasons;
  final bool unused;
  final bool system;

  const Grant({
    required this.binding,
    required this.role,
    required this.scope,
    required this.subjects,
    required this.score,
    required this.reasons,
    this.roleMissing = false,
    this.unused = false,
    this.system = false,
  });

  factory Grant.fromJson(Json j) => Grant(
        binding: refFromJson(asMap(j['binding'])),
        role: refFromJson(asMap(j['role'])),
        roleMissing: j['roleMissing'] == true,
        scope: asStr(j['scope']),
        subjects: [for (final s in _maps(j['subjects'])) GrantSubject.fromJson(s)],
        score: asInt(j['score']),
        reasons: [for (final r in (j['reasons'] as List? ?? const [])) '$r'],
        unused: j['unused'] == true,
        system: j['system'] == true,
      );

  bool get clusterWide => scope == 'cluster';
}

class NamespaceNetwork {
  final String namespace;
  final int policies;
  final int workloads;
  final String ingress;
  final String egress;
  final int ingressOpen;
  final int egressOpen;
  final int exposed;
  final String? psa;

  const NamespaceNetwork({
    required this.namespace,
    required this.policies,
    required this.workloads,
    required this.ingress,
    required this.egress,
    this.ingressOpen = 0,
    this.egressOpen = 0,
    this.exposed = 0,
    this.psa,
  });

  factory NamespaceNetwork.fromJson(Json j) => NamespaceNetwork(
        namespace: asStr(j['namespace']),
        policies: asInt(j['policies']),
        workloads: asInt(j['workloads']),
        ingress: asStr(j['ingress']),
        egress: asStr(j['egress']),
        ingressOpen: asInt(j['ingressOpen']),
        egressOpen: asInt(j['egressOpen']),
        exposed: asInt(j['exposed']),
        psa: asStr(j['psa']).isEmpty ? null : asStr(j['psa']),
      );
}

class VulnCounts {
  final int critical, high, medium, low, unknown, fixableCritical, fixableHigh;
  const VulnCounts({this.critical = 0, this.high = 0, this.medium = 0, this.low = 0, this.unknown = 0, this.fixableCritical = 0, this.fixableHigh = 0});

  factory VulnCounts.fromJson(Json j) => VulnCounts(
        critical: asInt(j['critical']),
        high: asInt(j['high']),
        medium: asInt(j['medium']),
        low: asInt(j['low']),
        unknown: asInt(j['unknown']),
        fixableCritical: asInt(j['fixableCritical']),
        fixableHigh: asInt(j['fixableHigh']),
      );

  int get fixable => fixableCritical + fixableHigh;
}

class Cve {
  final String id;
  final SecSeverity severity;
  final String package;
  final String installed;
  final String? fixed;
  final String title;
  final String? link;
  final double score;
  final List<String> images;

  const Cve({
    required this.id,
    required this.severity,
    required this.package,
    required this.installed,
    this.fixed,
    this.title = '',
    this.link,
    this.score = 0,
    this.images = const [],
  });

  factory Cve.fromJson(Json j) => Cve(
        id: asStr(j['id']),
        severity: SecSeverity.parse(j['severity']),
        package: asStr(j['package']),
        installed: asStr(j['installed']),
        fixed: asStr(j['fixed']).isEmpty ? null : asStr(j['fixed']),
        title: asStr(j['title']),
        link: asStr(j['link']).isEmpty ? null : asStr(j['link']),
        score: (j['score'] as num?)?.toDouble() ?? 0,
        images: [for (final i in (j['images'] as List? ?? const [])) '$i'],
      );
}

class ImageSummary {
  final String image;
  final List<ObjectRef> workloads;
  final bool scanned;
  final String? source;
  final String? scannedAt;
  final VulnCounts counts;
  final List<Cve> topCves;

  const ImageSummary({
    required this.image,
    required this.workloads,
    required this.scanned,
    required this.counts,
    this.source,
    this.scannedAt,
    this.topCves = const [],
  });

  factory ImageSummary.fromJson(Json j) => ImageSummary(
        image: asStr(j['image']),
        workloads: [for (final w in _maps(j['workloads'])) refFromJson(w)],
        scanned: j['scanned'] == true,
        source: j['source'] as String?,
        scannedAt: j['scannedAt'] as String?,
        counts: VulnCounts.fromJson(asMap(j['counts'])),
        topCves: [for (final c in _maps(j['topCVEs'])) Cve.fromJson(c)],
      );

  ImageSummary withScan(ScanResult r) => ImageSummary(
        image: image,
        workloads: workloads,
        scanned: true,
        source: 'trivy-cli',
        scannedAt: r.scannedAt,
        counts: r.counts,
        topCves: r.vulnerabilities.take(5).toList(),
      );
}

class SecurityData {
  final String generatedAt;
  final String namespace;
  final bool includeSystem;
  final int score;
  final List<SecCategory> categories;
  final List<SecFinding> findings;

  /// Findings hidden by the context's ignore rules: they are not in
  /// [findings], the category counts or the score.
  final List<SecIgnored> ignored;
  final List<Grant> permissive;
  final List<NamespaceNetwork> network;
  final List<ImageSummary> images;
  final List<Cve> topCves;
  final bool trivyOperator;
  final bool gatewayApi;
  final Map<String, String> errors;

  /// Namespaces of the set that could not be read (RBAC); the rest is
  /// analysed.
  final Map<String, ClusterError> partialErrors;

  /// Categories whose lists are still loading (the backend answered early):
  /// their tiles, findings and sections are unknown, not zero, and the score
  /// leaves them out.
  final Set<String> pending;

  const SecurityData({
    required this.generatedAt,
    required this.namespace,
    required this.score,
    required this.categories,
    required this.findings,
    this.includeSystem = false,
    this.ignored = const [],
    this.permissive = const [],
    this.network = const [],
    this.images = const [],
    this.topCves = const [],
    this.trivyOperator = false,
    this.gatewayApi = false,
    this.errors = const {},
    this.partialErrors = const {},
    this.pending = const {},
  });

  factory SecurityData.fromJson(Json j) {
    final sources = asMap(j['sources']);
    return SecurityData(
      generatedAt: asStr(j['generatedAt']),
      namespace: asStr(j['namespace']),
      includeSystem: j['includeSystem'] == true,
      score: asInt(j['score']),
      categories: [for (final c in _maps(j['categories'])) SecCategory.fromJson(c)],
      findings: [for (final f in _maps(j['findings'])) SecFinding.fromJson(f)],
      ignored: [for (final f in _maps(j['ignored'])) SecIgnored(SecFinding.fromJson(f), SecIgnoreRule.fromJson(asMap(f['rule'])))],
      permissive: [for (final g in _maps(j['permissive'])) Grant.fromJson(g)],
      network: [for (final n in _maps(j['network'])) NamespaceNetwork.fromJson(n)],
      images: [for (final i in _maps(j['images'])) ImageSummary.fromJson(i)],
      topCves: [for (final c in _maps(j['topCVEs'])) Cve.fromJson(c)],
      trivyOperator: sources['trivyOperator'] == true,
      gatewayApi: sources['gatewayAPI'] == true,
      errors: {for (final e in asMap(j['errors']).entries) e.key: '${e.value}'},
      partialErrors: parsePartialErrors(j['partialErrors']),
      pending: {for (final p in (j['pending'] as List?) ?? const []) '$p'},
    );
  }

  bool isPending(String category) => pending.contains(category);

  int countAll(SecSeverity s) => categories.fold(0, (n, c) => n + c.count(s));
}

class ScannerStatus {
  final bool operatorInstalled;
  final bool operatorHasReports;
  final bool operatorScanning;
  final List<String> operatorReports;
  final bool trivyAvailable;
  final String? trivyPath;
  final String? trivyVersion;
  final String installHint;

  const ScannerStatus({
    this.operatorInstalled = false,
    this.operatorHasReports = false,
    this.operatorScanning = false,
    this.operatorReports = const [],
    this.trivyAvailable = false,
    this.trivyPath,
    this.trivyVersion,
    this.installHint = 'Install trivy (`brew install trivy`) to scan images on demand.',
  });

  factory ScannerStatus.fromJson(Json j) {
    final op = asMap(j['operator']);
    final t = asMap(j['trivy']);
    return ScannerStatus(
      operatorInstalled: op['installed'] == true,
      operatorHasReports: op['hasReports'] == true,
      operatorScanning: op['scanning'] == true,
      operatorReports: [for (final r in (op['reports'] as List? ?? const [])) '$r'],
      trivyAvailable: t['available'] == true,
      trivyPath: t['path'] as String?,
      trivyVersion: asStr(t['version']).isEmpty ? null : asStr(t['version']),
      installHint: asStr(j['installHint']).isEmpty ? const ScannerStatus().installHint : asStr(j['installHint']),
    );
  }
}

class ScanResult {
  final String image;
  final String scannedAt;
  final bool cached;
  final String? os;
  final VulnCounts counts;
  final List<Cve> vulnerabilities;
  final int total;

  const ScanResult({required this.image, required this.scannedAt, required this.counts, this.cached = false, this.os, this.vulnerabilities = const [], this.total = 0});

  factory ScanResult.fromJson(Json j) => ScanResult(
        image: asStr(j['image']),
        scannedAt: asStr(j['scannedAt']),
        cached: j['cached'] == true,
        os: j['os'] as String?,
        counts: VulnCounts.fromJson(asMap(j['counts'])),
        vulnerabilities: [for (final v in _maps(j['vulnerabilities'])) Cve.fromJson(v)],
        total: asInt(j['total']),
      );
}
