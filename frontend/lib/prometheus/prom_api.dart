/// Client and models for the Prometheus stack endpoints (`/api/prom/*`):
/// discovered instances, Alertmanager alerts and silences, rule and target
/// state, and PromQL queries. See docs/PROMETHEUS.md.
library;

import 'package:http/http.dart' as http;

import '../api/backend_http.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../util/k8s.dart';

/// Talks to `/api/prom/*` on the backend behind an [ApiClient], reusing its
/// base URL. Tests subclass it (or set [debugOverride]) to serve canned JSON.
class PromApi {
  final ApiClient api;
  final BackendHttp _http;
  PromApi(this.api, {http.Client? httpClient}) : _http = BackendHttp(api, '/api/prom/', httpClient: httpClient);

  /// Tests: replaces the instance [PromApi.of] hands out.
  static PromApi Function(ApiClient api)? debugOverride;

  static final Expando<PromApi> _byClient = Expando('PromApi');

  /// The shared instance for [api] (one per backend connection, so the
  /// availability check below is cached across panels).
  static PromApi of(ApiClient api) => debugOverride?.call(api) ?? (_byClient[api] ??= PromApi(api));

  Future<dynamic> getJson(String path, [Map<String, String?> query = const {}]) async => jsonBody(await _http.get(path, query));

  Future<dynamic> send(String method, String path, {Map<String, String?> query = const {}, Object? body}) async =>
      jsonBody(await _http.send(method, path, query: query, body: body));

  // ---- endpoints ----

  Future<PromStatus> status({bool refresh = false}) async =>
      PromStatus.fromJson(asMap(await getJson('status', {'refresh': refresh ? 'true' : null})));

  /// [instance] selects the Alertmanager (`namespace/name`), null = default.
  Future<AlertsData> alerts({String? instance}) async => AlertsData.fromJson(asMap(await getJson('alerts', {'instance': instance})));

  Future<List<Silence>> silences({String? instance}) async =>
      [for (final s in asMapList(asMap(await getJson('silences', {'instance': instance}))['silences'])) Silence.fromJson(s)];

  /// Creates a silence; returns its id.
  Future<String> createSilence(SilenceDraft draft, {String? instance}) async =>
      '${asMap(await send('POST', 'silences', query: {'instance': instance}, body: draft.toJson()))['silenceID'] ?? ''}';

  Future<void> expireSilence(String id, {String? instance}) => send('DELETE', 'silences/${Uri.encodeComponent(id)}', query: {'instance': instance});

  /// Rule groups, optionally only those of PrometheusRule [namespace]/[name].
  Future<RulesData> rules({String? namespace, String? name, String? instance}) async =>
      RulesData.fromJson(asMap(await getJson('rules', {'namespace': namespace, 'name': name, 'instance': instance})));

  /// Scrape pools, optionally only those of one monitor ([kind] =
  /// ServiceMonitor / PodMonitor).
  Future<TargetsData> targets({String? kind, String? namespace, String? name, String? instance}) async =>
      TargetsData.fromJson(asMap(await getJson('targets', {'kind': kind, 'namespace': namespace, 'name': name, 'instance': instance})));

  Future<QueryData> query(String query, {String? instance}) async => QueryData.fromJson(asMap(await getJson('query', {'query': query, 'instance': instance})));

  Future<QueryData> queryRange(String query, {required DateTime start, DateTime? end, Duration? step, String? instance}) async =>
      QueryData.fromJson(asMap(await getJson('query_range', {
        'query': query,
        'start': _unix(start),
        'end': end == null ? null : _unix(end),
        'step': step == null ? null : '${step.inSeconds}',
        'instance': instance,
      })));

  static String _unix(DateTime t) => (t.millisecondsSinceEpoch / 1000).toStringAsFixed(3);

  // ---- cached availability (history charts) ----

  Future<PromStatus>? _statusFuture;
  DateTime? _statusAt;

  /// Discovery, cached for a minute (failures too), and shared by everything
  /// that asks: the Prometheus module's `detect`, the alerts badge and the
  /// charts' availability check make one request between them.
  Future<PromStatus> discover() {
    final at = _statusAt;
    if (_statusFuture == null || at == null || DateTime.now().difference(at) > const Duration(minutes: 1)) {
      _statusAt = DateTime.now();
      _statusFuture = status();
    }
    return _statusFuture!;
  }

  /// [discover], or null when the backend has no Prometheus endpoints or
  /// the request failed.
  Future<PromStatus?> cachedStatus() => discover().then<PromStatus?>((s) => s, onError: (_) => null);

  /// True when a reachable Prometheus exists (charts hide otherwise).
  Future<bool> hasPrometheus() async => _knownHasPrometheus = (await cachedStatus())?.defaultPrometheus?.reachable ?? false;

  /// What the last [hasPrometheus] answered (null before the first), so a
  /// view can reserve the right space before asking again.
  bool? get knownHasPrometheus => _knownHasPrometheus;
  bool? _knownHasPrometheus;
}

// ---------------------------------------------------------------------------
// Models
// ---------------------------------------------------------------------------

class PromInstance {
  final String id;
  final String kind;
  final String namespace;
  final String name;
  final String source;
  final String service;
  final String port;
  final String version;
  final bool reachable;
  final String? error;
  final bool isDefault;
  final int? replicas;
  final int? available;
  final String? externalUrl;

  const PromInstance({
    required this.id,
    required this.kind,
    required this.namespace,
    required this.name,
    this.source = 'crd',
    this.service = '',
    this.port = '',
    this.version = '',
    this.reachable = false,
    this.error,
    this.isDefault = false,
    this.replicas,
    this.available,
    this.externalUrl,
  });

  factory PromInstance.fromJson(Json j) => PromInstance(
        id: '${j['id'] ?? ''}',
        kind: '${j['kind'] ?? ''}',
        namespace: '${j['namespace'] ?? ''}',
        name: '${j['name'] ?? ''}',
        source: '${j['source'] ?? ''}',
        service: '${j['service'] ?? ''}',
        port: '${j['port'] ?? ''}',
        version: '${j['version'] ?? ''}',
        reachable: j['reachable'] == true,
        error: j['error'] as String?,
        isDefault: j['default'] == true,
        replicas: (j['replicas'] as num?)?.toInt(),
        available: (j['availableReplicas'] as num?)?.toInt(),
        externalUrl: j['externalUrl'] as String?,
      );

  static PromInstance? maybe(dynamic j) => j is Map ? PromInstance.fromJson(Map<String, dynamic>.from(j)) : null;
}

class PromStatus {
  final List<PromInstance> prometheus;
  final List<PromInstance> alertmanager;
  final bool operatorCRDs;
  const PromStatus({this.prometheus = const [], this.alertmanager = const [], this.operatorCRDs = false});

  factory PromStatus.fromJson(Json j) => PromStatus(
        prometheus: [for (final i in asMapList(j['prometheus'])) PromInstance.fromJson(i)],
        alertmanager: [for (final i in asMapList(j['alertmanager'])) PromInstance.fromJson(i)],
        operatorCRDs: j['operatorCRDs'] == true,
      );

  PromInstance? get defaultPrometheus => prometheus.where((i) => i.isDefault).firstOrNull ?? prometheus.firstOrNull;
  PromInstance? get defaultAlertmanager => alertmanager.where((i) => i.isDefault).firstOrNull ?? alertmanager.firstOrNull;
}

/// Alert severities, most severe first. `none` is plumbing (Watchdog).
enum AlertSeverity {
  critical,
  warning,
  info,
  none;

  static AlertSeverity parse(String? s) => switch (s?.toLowerCase()) {
        'critical' || 'error' || 'page' => critical,
        'warning' || 'warn' => warning,
        'none' => none,
        _ => info,
      };

  Severity get badge => switch (this) {
        critical => Severity.error,
        warning => Severity.warn,
        info => Severity.info,
        none => Severity.neutral,
      };
}

enum AlertState {
  firing,
  pending,
  silenced,
  inhibited;

  static AlertState parse(String? s) => switch (s) {
        'pending' => pending,
        'silenced' => silenced,
        'inhibited' => inhibited,
        _ => firing,
      };
}

class PromAlert {
  final String fingerprint;
  final String alertname;
  final AlertState state;
  final String severityLabel;
  final Map<String, String> labels;
  final Map<String, String> annotations;
  final String? startsAt;
  final String? endsAt;
  final String? generatorURL;
  final List<String> silencedBy;
  final List<String> inhibitedBy;
  final String source;
  final String? value;
  final ObjectRef? target;

  const PromAlert({
    required this.fingerprint,
    required this.alertname,
    required this.state,
    this.severityLabel = '',
    this.labels = const {},
    this.annotations = const {},
    this.startsAt,
    this.endsAt,
    this.generatorURL,
    this.silencedBy = const [],
    this.inhibitedBy = const [],
    this.source = 'alertmanager',
    this.value,
    this.target,
  });

  factory PromAlert.fromJson(Json j) => PromAlert(
        fingerprint: '${j['fingerprint'] ?? ''}',
        alertname: '${j['alertname'] ?? ''}',
        state: AlertState.parse(j['state'] as String?),
        severityLabel: '${j['severity'] ?? ''}',
        labels: _strMap(j['labels']),
        annotations: _strMap(j['annotations']),
        startsAt: j['startsAt'] as String?,
        endsAt: j['endsAt'] as String?,
        generatorURL: (j['generatorURL'] as String?)?.isEmpty == true ? null : j['generatorURL'] as String?,
        silencedBy: List<String>.from(j['silencedBy'] ?? const []),
        inhibitedBy: List<String>.from(j['inhibitedBy'] ?? const []),
        source: '${j['source'] ?? ''}',
        value: j['value'] as String?,
        target: refFromJson(j['target']),
      );

  AlertSeverity get severity => AlertSeverity.parse(severityLabel);
  String? get namespace => labels['namespace'];
  String? get summary => _nonEmpty(annotations['summary']);
  String? get description => _nonEmpty(annotations['description']) ?? _nonEmpty(annotations['message']);
  String? get runbookUrl => _nonEmpty(annotations['runbook_url']);
}

class AlertGroup {
  final String alertname;
  final String severityLabel;
  final AlertState state;
  final Map<String, int> counts;
  final String? summary;
  final List<PromAlert> alerts;
  const AlertGroup({required this.alertname, required this.severityLabel, required this.state, this.counts = const {}, this.summary, this.alerts = const []});

  factory AlertGroup.fromJson(Json j) => AlertGroup(
        alertname: '${j['alertname'] ?? ''}',
        severityLabel: '${j['severity'] ?? ''}',
        state: AlertState.parse(j['state'] as String?),
        counts: {for (final e in asMap(j['counts']).entries) e.key: (e.value as num).toInt()},
        summary: j['summary'] as String?,
        alerts: [for (final a in asMapList(j['alerts'])) PromAlert.fromJson(a)],
      );

  AlertSeverity get severity => AlertSeverity.parse(severityLabel);
}

class AlertSummary {
  final int firing, pending, silenced, inhibited, critical;
  const AlertSummary({this.firing = 0, this.pending = 0, this.silenced = 0, this.inhibited = 0, this.critical = 0});
  factory AlertSummary.fromJson(Json j) => AlertSummary(
        firing: (j['firing'] as num?)?.toInt() ?? 0,
        pending: (j['pending'] as num?)?.toInt() ?? 0,
        silenced: (j['silenced'] as num?)?.toInt() ?? 0,
        inhibited: (j['inhibited'] as num?)?.toInt() ?? 0,
        critical: (j['critical'] as num?)?.toInt() ?? 0,
      );
}

class AlertsData {
  final PromInstance? alertmanager;
  final PromInstance? prometheus;
  final AlertSummary summary;
  final List<AlertGroup> groups;
  final Map<String, String> errors;
  const AlertsData({this.alertmanager, this.prometheus, this.summary = const AlertSummary(), this.groups = const [], this.errors = const {}});

  factory AlertsData.fromJson(Json j) => AlertsData(
        alertmanager: PromInstance.maybe(j['alertmanager']),
        prometheus: PromInstance.maybe(j['prometheus']),
        summary: AlertSummary.fromJson(asMap(j['summary'])),
        groups: [for (final g in asMapList(j['groups'])) AlertGroup.fromJson(g)],
        errors: {for (final e in asMap(j['errors']).entries) e.key: '${e.value}'},
      );

  /// Neither Alertmanager nor Prometheus was found, and the search itself
  /// worked (see [discoveryError]).
  bool get stackMissing => alertmanager == null && prometheus == null && discoveryError == null;

  /// Why the search for Prometheus and Alertmanager failed (e.g. the cluster
  /// API was unreachable): they may well be installed.
  String? get discoveryError => errors['discovery'];
}

class SilenceMatcher {
  final String name;
  final String value;
  final bool isRegex;
  final bool isEqual;
  const SilenceMatcher({required this.name, required this.value, this.isRegex = false, this.isEqual = true});

  factory SilenceMatcher.fromJson(Json j) =>
      SilenceMatcher(name: '${j['name'] ?? ''}', value: '${j['value'] ?? ''}', isRegex: j['isRegex'] == true, isEqual: j['isEqual'] != false);

  Json toJson() => {'name': name, 'value': value, 'isRegex': isRegex, 'isEqual': isEqual};

  String get op => isRegex ? (isEqual ? '=~' : '!~') : (isEqual ? '=' : '!=');

  @override
  String toString() => '$name$op"$value"';

  /// Does this matcher match [labels]?
  bool matches(Map<String, String> labels) {
    final v = labels[name] ?? '';
    final hit = isRegex ? (RegExp('^(?:$value)\$').hasMatch(v)) : v == value;
    return isEqual ? hit : !hit;
  }
}

class Silence {
  final String id;
  final String state;
  final List<SilenceMatcher> matchers;
  final String? startsAt;
  final String? endsAt;
  final String createdBy;
  final String comment;
  const Silence({required this.id, required this.state, this.matchers = const [], this.startsAt, this.endsAt, this.createdBy = '', this.comment = ''});

  factory Silence.fromJson(Json j) => Silence(
        id: '${j['id'] ?? ''}',
        state: '${j['state'] ?? ''}',
        matchers: [for (final m in asMapList(j['matchers'])) SilenceMatcher.fromJson(m)],
        startsAt: j['startsAt'] as String?,
        endsAt: j['endsAt'] as String?,
        createdBy: '${j['createdBy'] ?? ''}',
        comment: '${j['comment'] ?? ''}',
      );

  bool get active => state == 'active';
  bool get pending => state == 'pending';

  /// Time until the silence ends (null if unknown or ended).
  Duration? remaining(DateTime now) {
    final e = parseTime(endsAt);
    if (e == null) return null;
    final d = e.difference(now);
    return d.isNegative ? null : d;
  }

  bool matches(Map<String, String> labels) => matchers.isNotEmpty && matchers.every((m) => m.matches(labels));
}

class SilenceDraft {
  final List<SilenceMatcher> matchers;
  final String duration;
  final String comment;
  const SilenceDraft({required this.matchers, required this.duration, required this.comment});
  Json toJson() => {'matchers': [for (final m in matchers) m.toJson()], 'duration': duration, 'comment': comment, 'createdBy': 'k8sman'};
}

// ---- rules ----

class RuleState {
  final String type; // alerting | recording
  final String name;
  final String query;
  final double duration;
  final Map<String, String> labels;
  final Map<String, String> annotations;
  final String? state; // inactive | pending | firing
  final String health; // ok | err | unknown
  final String? lastError;
  final String? lastEvaluation;
  final List<Json> alerts;
  const RuleState({
    required this.type,
    required this.name,
    this.query = '',
    this.duration = 0,
    this.labels = const {},
    this.annotations = const {},
    this.state,
    this.health = 'unknown',
    this.lastError,
    this.lastEvaluation,
    this.alerts = const [],
  });

  factory RuleState.fromJson(Json j) => RuleState(
        type: '${j['type'] ?? ''}',
        name: '${j['name'] ?? ''}',
        query: '${j['query'] ?? ''}',
        duration: (j['duration'] as num?)?.toDouble() ?? 0,
        labels: _strMap(j['labels']),
        annotations: _strMap(j['annotations']),
        state: j['state'] as String?,
        health: '${j['health'] ?? 'unknown'}',
        lastError: _nonEmpty(j['lastError'] as String?),
        lastEvaluation: j['lastEvaluation'] as String?,
        alerts: asMapList(j['alerts']),
      );
}

class RuleGroupState {
  final String name;
  final String file;
  final double interval;
  final ({String namespace, String name})? source;
  final List<RuleState> rules;
  const RuleGroupState({required this.name, this.file = '', this.interval = 0, this.source, this.rules = const []});

  factory RuleGroupState.fromJson(Json j) {
    final s = asMap(j['source']);
    return RuleGroupState(
      name: '${j['name'] ?? ''}',
      file: '${j['file'] ?? ''}',
      interval: (j['interval'] as num?)?.toDouble() ?? 0,
      source: s.isEmpty ? null : (namespace: '${s['namespace']}', name: '${s['name']}'),
      rules: [for (final r in asMapList(j['rules'])) RuleState.fromJson(r)],
    );
  }
}

class RulesData {
  final PromInstance? prometheus;
  final List<RuleGroupState> groups;
  final int firing, pending, inactive, errors;
  const RulesData({this.prometheus, this.groups = const [], this.firing = 0, this.pending = 0, this.inactive = 0, this.errors = 0});

  factory RulesData.fromJson(Json j) {
    final c = asMap(j['counts']);
    int n(String k) => (c[k] as num?)?.toInt() ?? 0;
    return RulesData(
      prometheus: PromInstance.maybe(j['prometheus']),
      groups: [for (final g in asMapList(j['groups'])) RuleGroupState.fromJson(g)],
      firing: n('firing'),
      pending: n('pending'),
      inactive: n('inactive'),
      errors: n('errors'),
    );
  }

  /// Live state of a rule by group and rule name (alert or record).
  RuleState? find(String group, String name) {
    for (final g in groups) {
      if (g.name != group) continue;
      for (final r in g.rules) {
        if (r.name == name) return r;
      }
    }
    return null;
  }
}

// ---- targets ----

class ScrapeTarget {
  final String scrapeUrl;
  final String health;
  final String? lastError;
  final String? lastScrape;
  final double lastScrapeDuration;
  final Map<String, String> labels;
  final ObjectRef? target;
  const ScrapeTarget({required this.scrapeUrl, required this.health, this.lastError, this.lastScrape, this.lastScrapeDuration = 0, this.labels = const {}, this.target});

  factory ScrapeTarget.fromJson(Json j) => ScrapeTarget(
        scrapeUrl: '${j['scrapeUrl'] ?? ''}',
        health: '${j['health'] ?? 'unknown'}',
        lastError: _nonEmpty(j['lastError'] as String?),
        lastScrape: j['lastScrape'] as String?,
        lastScrapeDuration: (j['lastScrapeDuration'] as num?)?.toDouble() ?? 0,
        labels: _strMap(j['labels']),
        target: refFromJson(j['target']),
      );
}

class TargetPool {
  final String scrapePool;
  final int? endpoint;
  final int up, down, unknown;
  final List<ScrapeTarget> targets;
  const TargetPool({required this.scrapePool, this.endpoint, this.up = 0, this.down = 0, this.unknown = 0, this.targets = const []});

  factory TargetPool.fromJson(Json j) => TargetPool(
        scrapePool: '${j['scrapePool'] ?? ''}',
        endpoint: (dig<num>(j, ['monitor', 'endpoint']))?.toInt(),
        up: (j['up'] as num?)?.toInt() ?? 0,
        down: (j['down'] as num?)?.toInt() ?? 0,
        unknown: (j['unknown'] as num?)?.toInt() ?? 0,
        targets: [for (final t in asMapList(j['targets'])) ScrapeTarget.fromJson(t)],
      );
}

class TargetsData {
  final PromInstance? prometheus;
  final int up, down, unknown;
  final List<TargetPool> pools;
  const TargetsData({this.prometheus, this.up = 0, this.down = 0, this.unknown = 0, this.pools = const []});

  factory TargetsData.fromJson(Json j) => TargetsData(
        prometheus: PromInstance.maybe(j['prometheus']),
        up: (j['up'] as num?)?.toInt() ?? 0,
        down: (j['down'] as num?)?.toInt() ?? 0,
        unknown: (j['unknown'] as num?)?.toInt() ?? 0,
        pools: [for (final p in asMapList(j['pools'])) TargetPool.fromJson(p)],
      );
}

// ---- queries ----

class MetricSeries {
  final Map<String, String> metric;

  /// (time, value) pairs; NaN/Inf values are dropped.
  final List<(DateTime, double)> points;
  const MetricSeries(this.metric, this.points);
}

class QueryData {
  final String resultType;
  final List<MetricSeries> series;
  final bool truncated;
  final List<String> warnings;
  const QueryData({this.resultType = 'matrix', this.series = const [], this.truncated = false, this.warnings = const []});

  factory QueryData.fromJson(Json j) {
    final out = <MetricSeries>[];
    (DateTime, double)? point(dynamic p) {
      if (p is! List || p.length < 2) return null;
      final v = double.tryParse('${p[1]}');
      if (v == null || v.isNaN || v.isInfinite) return null;
      return (DateTime.fromMillisecondsSinceEpoch(((p[0] as num) * 1000).round()), v);
    }

    for (final s in asMapList(j['result'])) {
      final pts = <(DateTime, double)>[];
      if (s['values'] is List) {
        for (final p in s['values'] as List) {
          final x = point(p);
          if (x != null) pts.add(x);
        }
      } else {
        final x = point(s['value']);
        if (x != null) pts.add(x);
      }
      out.add(MetricSeries(_strMap(s['metric']), pts));
    }
    return QueryData(
      resultType: '${j['resultType'] ?? ''}',
      series: out,
      truncated: j['truncated'] == true,
      warnings: List<String>.from(j['warnings'] ?? const []),
    );
  }
}

// ---- helpers ----

Map<String, String> _strMap(dynamic m) => {for (final e in asMap(m).entries) e.key: '${e.value}'};

String? _nonEmpty(String? s) => s == null || s.trim().isEmpty ? null : s;

ObjectRef? refFromJson(dynamic j) {
  if (j is! Map || j['name'] == null || j['kind'] == null) return null;
  final ns = j['namespace'] as String?;
  return ObjectRef(group: '${j['group'] ?? ''}', kind: '${j['kind']}', name: '${j['name']}', namespace: ns == null || ns.isEmpty ? null : ns);
}
