/// Client and models for the backend's Helm endpoints (`/api/helm/*`, see
/// API.md). Reuses the [ApiClient]'s base URL; errors are [ApiException]s.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../api/client.dart';
import '../../api/models.dart';
import '../../util/k8s.dart';

String _s(dynamic v) => v == null ? '' : '$v';
int _i(dynamic v) => v is num ? v.toInt() : int.tryParse('${v ?? ''}') ?? 0;
List<String> _strings(dynamic v) => [for (final x in (v as List? ?? const [])) '$x'];

/// Status → badge severity.
Severity helmStatusSeverity(String status) => switch (status) {
      'deployed' => Severity.ok,
      'failed' => Severity.error,
      'pending-install' || 'pending-upgrade' || 'pending-rollback' || 'uninstalling' => Severity.warn,
      _ => Severity.neutral,
    };

bool helmStatusIsPending(String status) => status.startsWith('pending-');

/// One release (latest revision) in the list, or one revision in history.
class HelmRelease {
  final String name;
  final String namespace;
  final int revision;
  final String status;
  final String chart;
  final String chartVersion;
  final String appVersion;
  final DateTime? updated;
  final String description;
  const HelmRelease({
    required this.name,
    required this.namespace,
    required this.revision,
    required this.status,
    this.chart = '',
    this.chartVersion = '',
    this.appVersion = '',
    this.updated,
    this.description = '',
  });

  factory HelmRelease.fromJson(Json j) => HelmRelease(
        name: _s(j['name']),
        namespace: _s(j['namespace']),
        revision: _i(j['revision']),
        status: _s(j['status']),
        chart: _s(j['chart']),
        chartVersion: _s(j['chartVersion']),
        appVersion: _s(j['appVersion']),
        updated: DateTime.tryParse(_s(j['updated'])),
        description: _s(j['description']),
      );

  String get key => '$namespace/$name';
  String get chartRef => chartVersion.isEmpty ? chart : '$chart-$chartVersion';
  bool get failed => status == 'failed';
  bool get pending => helmStatusIsPending(status);
  bool get problem => failed || pending;
}

class HelmReleaseList {
  final List<HelmRelease> releases;
  final int failed;
  final int pending;
  const HelmReleaseList(this.releases, {this.failed = 0, this.pending = 0});
  factory HelmReleaseList.fromJson(Json j) => HelmReleaseList(
        [for (final r in (j['releases'] as List? ?? const [])) HelmRelease.fromJson(Map<String, dynamic>.from(r))],
        failed: _i(j['failed']),
        pending: _i(j['pending']),
      );
}

/// Problem releases (failed, pending) first, then namespace/name.
List<HelmRelease> sortReleases(Iterable<HelmRelease> rs) {
  int rank(HelmRelease r) => r.pending ? 0 : (r.failed ? 1 : 2);
  return rs.toList()
    ..sort((a, b) {
      final c = rank(a).compareTo(rank(b));
      if (c != 0) return c;
      final n = a.namespace.compareTo(b.namespace);
      return n != 0 ? n : a.name.compareTo(b.name);
    });
}

class HelmDependency {
  final String name, version, repository, condition, alias;
  final bool embedded;
  const HelmDependency({required this.name, this.version = '', this.repository = '', this.condition = '', this.alias = '', this.embedded = false});
  factory HelmDependency.fromJson(Json j) => HelmDependency(
        name: _s(j['name']),
        version: _s(j['version']),
        repository: _s(j['repository']),
        condition: _s(j['condition']),
        alias: _s(j['alias']),
        embedded: j['embedded'] == true,
      );
}

class HelmChartInfo {
  final String name, version, appVersion, description, home, icon, apiVersion, type, kubeVersion;
  final List<String> sources, keywords;
  final bool deprecated;
  final List<HelmDependency> dependencies;
  const HelmChartInfo({
    this.name = '',
    this.version = '',
    this.appVersion = '',
    this.description = '',
    this.home = '',
    this.icon = '',
    this.apiVersion = '',
    this.type = '',
    this.kubeVersion = '',
    this.sources = const [],
    this.keywords = const [],
    this.deprecated = false,
    this.dependencies = const [],
  });
  factory HelmChartInfo.fromJson(Json j) => HelmChartInfo(
        name: _s(j['name']),
        version: _s(j['version']),
        appVersion: _s(j['appVersion']),
        description: _s(j['description']),
        home: _s(j['home']),
        icon: _s(j['icon']),
        apiVersion: _s(j['apiVersion']),
        type: _s(j['type']),
        kubeVersion: _s(j['kubeVersion']),
        sources: _strings(j['sources']),
        keywords: _strings(j['keywords']),
        deprecated: j['deprecated'] == true,
        dependencies: [for (final d in (j['dependencies'] as List? ?? const [])) HelmDependency.fromJson(Map<String, dynamic>.from(d))],
      );
}

class HelmHook {
  final String name, kind, group, path, phase, manifest;
  final List<String> events, deletePolicies;
  final int weight;
  final DateTime? startedAt, completedAt;
  const HelmHook({
    required this.name,
    required this.kind,
    this.group = '',
    this.path = '',
    this.phase = '',
    this.manifest = '',
    this.events = const [],
    this.deletePolicies = const [],
    this.weight = 0,
    this.startedAt,
    this.completedAt,
  });
  factory HelmHook.fromJson(Json j) => HelmHook(
        name: _s(j['name']),
        kind: _s(j['kind']),
        group: _s(j['group']),
        path: _s(j['path']),
        phase: _s(j['phase']),
        manifest: _s(j['manifest']),
        events: _strings(j['events']),
        deletePolicies: _strings(j['deletePolicies']),
        weight: _i(j['weight']),
        startedAt: DateTime.tryParse(_s(j['startedAt'])),
        completedAt: DateTime.tryParse(_s(j['completedAt'])),
      );
}

/// A release stuck in pending-install/upgrade/rollback, and the remedy.
class HelmStuck {
  final String status;
  final int revision;

  /// Last good revision to roll back to; 0 = none (uninstall instead).
  final int rollbackTo;
  final String remedy;
  const HelmStuck({required this.status, required this.revision, required this.rollbackTo, required this.remedy});
  factory HelmStuck.fromJson(Json j) =>
      HelmStuck(status: _s(j['status']), revision: _i(j['revision']), rollbackTo: _i(j['rollbackTo']), remedy: _s(j['remedy']));
}

class HelmReleaseDetail {
  final HelmRelease release;
  final int latestRevision;
  final DateTime? firstDeployed, lastDeployed;
  final String notes, values, computedValues, manifest;
  final HelmChartInfo chart;
  final List<HelmHook> hooks;
  final List<ObjectRef> resources;
  final HelmStuck? stuck;

  /// Why upgrading from the stored chart isn't possible (empty = it is).
  final String upgradeBlocked;
  const HelmReleaseDetail({
    required this.release,
    required this.latestRevision,
    this.firstDeployed,
    this.lastDeployed,
    this.notes = '',
    this.values = '',
    this.computedValues = '',
    this.manifest = '',
    this.chart = const HelmChartInfo(),
    this.hooks = const [],
    this.resources = const [],
    this.stuck,
    this.upgradeBlocked = '',
  });

  factory HelmReleaseDetail.fromJson(Json j) => HelmReleaseDetail(
        release: HelmRelease.fromJson(j),
        latestRevision: _i(j['latestRevision']),
        firstDeployed: DateTime.tryParse(_s(j['firstDeployed'])),
        lastDeployed: DateTime.tryParse(_s(j['lastDeployed'])),
        notes: _s(j['notes']),
        values: _s(j['values']),
        computedValues: _s(j['computedValues']),
        manifest: _s(j['manifest']),
        chart: HelmChartInfo.fromJson(Map<String, dynamic>.from(j['chartInfo'] ?? const {})),
        hooks: [for (final h in (j['hooks'] as List? ?? const [])) HelmHook.fromJson(Map<String, dynamic>.from(h))],
        resources: [
          for (final r in (j['resources'] as List? ?? const []))
            ObjectRef(group: _s(r['group']), kind: _s(r['kind']), name: _s(r['name']), namespace: (r['namespace'] as String?)?.isEmpty == true ? null : r['namespace'] as String?),
        ],
        stuck: j['stuck'] is Map ? HelmStuck.fromJson(Map<String, dynamic>.from(j['stuck'])) : null,
        upgradeBlocked: _s(j['upgradeBlocked']),
      );

  bool get isLatest => release.revision == latestRevision;
}

class HelmRevisionText {
  final int revision;
  final String status, chart, manifest, values;
  const HelmRevisionText({required this.revision, this.status = '', this.chart = '', this.manifest = '', this.values = ''});
  factory HelmRevisionText.fromJson(Json j) =>
      HelmRevisionText(revision: _i(j['revision']), status: _s(j['status']), chart: _s(j['chart']), manifest: _s(j['manifest']), values: _s(j['values']));
}

class HelmDiff {
  final HelmRevisionText from, to;
  const HelmDiff(this.from, this.to);
  factory HelmDiff.fromJson(Json j) =>
      HelmDiff(HelmRevisionText.fromJson(Map<String, dynamic>.from(j['from'] ?? const {})), HelmRevisionText.fromJson(Map<String, dynamic>.from(j['to'] ?? const {})));
}

/// Result of a mutation (rollback, uninstall, upgrade, install).
class HelmResult {
  final String message;
  final bool dryRun;
  final String context;
  final HelmRelease? release;
  final String manifest, currentManifest, notes;
  const HelmResult({required this.message, this.dryRun = false, this.context = '', this.release, this.manifest = '', this.currentManifest = '', this.notes = ''});
  factory HelmResult.fromJson(Json j) => HelmResult(
        message: _s(j['message']),
        dryRun: j['dryRun'] == true,
        context: _s(j['context']),
        release: j['release'] is Map ? HelmRelease.fromJson(Map<String, dynamic>.from(j['release'])) : null,
        manifest: _s(j['manifest']),
        currentManifest: _s(j['currentManifest']),
        notes: _s(j['notes']),
      );
}

class HelmChartVersion {
  final String version, appVersion, description;
  final DateTime? created;
  final bool deprecated, prerelease;
  const HelmChartVersion({required this.version, this.appVersion = '', this.description = '', this.created, this.deprecated = false, this.prerelease = false});
  factory HelmChartVersion.fromJson(Json j) => HelmChartVersion(
        version: _s(j['version']),
        appVersion: _s(j['appVersion']),
        description: _s(j['description']),
        created: DateTime.tryParse(_s(j['created'])),
        deprecated: j['deprecated'] == true,
        prerelease: j['prerelease'] == true,
      );
}

/// Thin client for `/api/helm/*`. Subclass it in tests to serve fixtures.
class HelmApi {
  final Uri base;
  final http.Client _http;

  HelmApi(ApiClient api, {http.Client? httpClient})
      : base = api.base,
        _http = httpClient ?? http.Client();

  Uri _uri(String path, [Map<String, String?> query = const {}]) {
    final q = <String, String>{
      for (final e in query.entries)
        if (e.value != null && e.value!.isNotEmpty) e.key: e.value!,
    };
    return base.replace(path: '/api/helm/$path', queryParameters: q.isEmpty ? null : q);
  }

  Future<Json> _get(String path, [Map<String, String?> query = const {}]) async => _decode(await _http.get(_uri(path, query)));

  Future<Json> _post(String path, Json body) async =>
      _decode(await _http.post(_uri(path), headers: {'Content-Type': 'application/json'}, body: jsonEncode(body)));

  Json _decode(http.Response res) {
    if (res.statusCode >= 400) {
      var msg = res.body;
      String? reason;
      try {
        final j = jsonDecode(res.body) as Map;
        msg = '${j['error'] ?? msg}';
        reason = j['reason'] as String?;
      } catch (_) {}
      throw ApiException(res.statusCode, msg, reason: reason);
    }
    return Map<String, dynamic>.from(jsonDecode(res.body) as Map);
  }

  /// Latest revision of every release; [namespace] null = all namespaces.
  Future<HelmReleaseList> releases({String? namespace}) async => HelmReleaseList.fromJson(await _get('releases', {'namespace': namespace}));

  /// One revision (null = latest) with values, manifest, hooks and resources.
  Future<HelmReleaseDetail> release(String namespace, String name, {int? revision}) async =>
      HelmReleaseDetail.fromJson(await _get('release', {'namespace': namespace, 'name': name, 'revision': revision?.toString()}));

  /// All stored revisions, newest first.
  Future<List<HelmRelease>> history(String namespace, String name) async {
    final j = await _get('history', {'namespace': namespace, 'name': name});
    return [for (final r in (j['history'] as List? ?? const [])) HelmRelease.fromJson(Map<String, dynamic>.from(r))];
  }

  /// Manifests and user values of two revisions ([to] null = latest).
  Future<HelmDiff> diff(String namespace, String name, {required int from, int? to}) async =>
      HelmDiff.fromJson(await _get('diff', {'namespace': namespace, 'name': name, 'from': '$from', 'to': to?.toString()}));

  Future<HelmResult> rollback(String namespace, String name, int revision, {bool dryRun = false, bool wait = false, int? timeoutSeconds}) async =>
      HelmResult.fromJson(await _post('rollback', {
        'namespace': namespace,
        'name': name,
        'revision': revision,
        'dryRun': dryRun,
        'wait': wait,
        'timeoutSeconds': ?timeoutSeconds,
      }));

  Future<HelmResult> uninstall(String namespace, String name, {bool keepHistory = false, bool dryRun = false}) async =>
      HelmResult.fromJson(await _post('uninstall', {'namespace': namespace, 'name': name, 'keepHistory': keepHistory, 'dryRun': dryRun}));

  /// Re-renders the release's stored chart with new user [values] (YAML).
  Future<HelmResult> upgrade(String namespace, String name, String values, {bool reuseValues = false, bool dryRun = false}) async =>
      HelmResult.fromJson(await _post('upgrade', {'namespace': namespace, 'name': name, 'values': values, 'reuseValues': reuseValues, 'dryRun': dryRun}));

  /// Installs [chart] from an https repo URL or an `oci://` reference.
  Future<HelmResult> install({
    required String namespace,
    required String releaseName,
    required String repo,
    required String chart,
    String? version,
    String values = '',
    bool createNamespace = true,
    bool wait = false,
    int? timeoutSeconds,
    bool dryRun = false,
  }) async =>
      HelmResult.fromJson(await _post('install', {
        'namespace': namespace,
        'releaseName': releaseName,
        'repo': repo,
        'chart': chart,
        'version': ?version,
        'values': values,
        'createNamespace': createNamespace,
        'wait': wait,
        'timeoutSeconds': ?timeoutSeconds,
        'dryRun': dryRun,
      }));

  /// Available chart versions, newest first.
  Future<List<HelmChartVersion>> chartVersions(String repo, String chart) async {
    final j = await _get('chart-versions', {'repo': repo, 'chart': chart});
    return [for (final v in (j['versions'] as List? ?? const [])) HelmChartVersion.fromJson(Map<String, dynamic>.from(v))];
  }
}
