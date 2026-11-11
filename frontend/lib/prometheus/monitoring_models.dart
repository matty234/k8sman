/// Models for an object's monitoring (`/api/prom/scrape`, `/api/prom/applies`),
/// Alertmanager's running config (`/api/prom/alertmanager`) and what the
/// operator's custom resources select (`/api/prom/selection`,
/// `/api/prom/selectedby`). Exported by prom_api.dart.
library;

import '../api/models.dart';
import '../util/k8s.dart';
import 'prom_api.dart';

typedef SourceRef = ({String namespace, String name});

Map<String, String> _strMap(dynamic m) => {for (final e in asMap(m).entries) e.key: '${e.value}'};
List<String> _strs(dynamic l) => [for (final x in (l is List ? l : const [])) '$x'];
String? _nonEmpty(dynamic s) => s is String && s.trim().isNotEmpty ? s : null;
int _int(dynamic n) => (n as num?)?.toInt() ?? 0;
SourceRef? _source(dynamic j) {
  final s = asMap(j);
  return s.isEmpty ? null : (namespace: '${s['namespace']}', name: '${s['name']}');
}

// ---- an object's monitoring ----

/// One condition of a monitor picking up an object.
class MonitorCheckItem {
  final String name; // namespace | selector | port | prometheus
  final bool ok;
  final String detail;
  const MonitorCheckItem(this.name, this.ok, this.detail);
}

/// How a ServiceMonitor / PodMonitor relates to an object: it matches, or
/// comes close and some checks fail.
class MonitorCheck {
  final MonitorRef monitor;
  final ObjectRef? via;
  final bool matches;
  final bool scraping;
  final List<MonitorCheckItem> checks;
  const MonitorCheck({required this.monitor, this.via, this.matches = false, this.scraping = false, this.checks = const []});

  factory MonitorCheck.fromJson(Json j) => MonitorCheck(
        monitor: MonitorRef.maybe(j)!,
        via: refFromJson(j['via']),
        matches: j['matches'] == true,
        scraping: j['scraping'] == true,
        checks: [for (final c in asMapList(j['checks'])) MonitorCheckItem('${c['name'] ?? ''}', c['ok'] == true, '${c['detail'] ?? ''}')],
      );

  List<MonitorCheckItem> get failing => [for (final c in checks) if (!c.ok) c];
}

/// A scrape pool whose discovery found the object but whose relabelling
/// dropped it.
class DroppedPool {
  final String scrapePool;
  final MonitorRef? monitor;
  final List<String> ports;
  final List<String> services;
  final int count;
  const DroppedPool({required this.scrapePool, this.monitor, this.ports = const [], this.services = const [], this.count = 0});

  factory DroppedPool.fromJson(Json j) => DroppedPool(
        scrapePool: '${j['scrapePool'] ?? ''}',
        monitor: MonitorRef.maybe(j['monitor']),
        ports: _strs(j['ports']),
        services: _strs(j['services']),
        count: _int(j['count']),
      );
}

/// Is an object scraped, by what, and if not why.
class ObjectScrape {
  final PromInstance? prometheus;
  final int pods;
  final List<String> services;
  final int up, down, unknown, total;

  /// Down first; at most 200 of [total].
  final List<ScrapeTarget> targets;
  final List<String> jobs;
  final List<DroppedPool> dropped;
  final List<MonitorCheck> monitors;
  final List<String> hints;
  final Map<String, String> errors;
  const ObjectScrape({
    this.prometheus,
    this.pods = 0,
    this.services = const [],
    this.up = 0,
    this.down = 0,
    this.unknown = 0,
    this.total = 0,
    this.targets = const [],
    this.jobs = const [],
    this.dropped = const [],
    this.monitors = const [],
    this.hints = const [],
    this.errors = const {},
  });

  factory ObjectScrape.fromJson(Json j) => ObjectScrape(
        prometheus: PromInstance.maybe(j['prometheus']),
        pods: _int(j['pods']),
        services: _strs(j['services']),
        up: _int(j['up']),
        down: _int(j['down']),
        unknown: _int(j['unknown']),
        total: _int(j['total']),
        targets: [for (final t in asMapList(j['targets'])) ScrapeTarget.fromJson(t)],
        jobs: _strs(j['jobs']),
        dropped: [for (final d in asMapList(j['dropped'])) DroppedPool.fromJson(d)],
        monitors: [for (final m in asMapList(j['monitors'])) if (m['kind'] != null) MonitorCheck.fromJson(m)],
        hints: _strs(j['hints']),
        errors: _strMap(j['errors']),
      );

  bool get scraped => total > 0;
}

/// A rule that (heuristically) concerns an object, and why.
class RuleMatch {
  final String group;
  final String file;
  final SourceRef? source;
  final RuleState rule;
  final int activeAlerts;
  final List<String> reasons;
  const RuleMatch({required this.group, this.file = '', this.source, required this.rule, this.activeAlerts = 0, this.reasons = const []});

  factory RuleMatch.fromJson(Json j) => RuleMatch(
        group: '${j['group'] ?? ''}',
        file: '${j['file'] ?? ''}',
        source: _source(j['source']),
        rule: RuleState.fromJson(asMap(j['rule'])),
        activeAlerts: _int(j['activeAlerts']),
        reasons: _strs(j['reasons']),
      );
}

/// Alerts about an object and rules that refer to it.
class ObjectApplies {
  final List<PromAlert> alerts;
  final List<RuleMatch> rules;
  final int rulesTotal;
  final List<String> jobs;
  final Map<String, String> errors;
  const ObjectApplies({this.alerts = const [], this.rules = const [], this.rulesTotal = 0, this.jobs = const [], this.errors = const {}});

  factory ObjectApplies.fromJson(Json j) => ObjectApplies(
        alerts: [for (final a in asMapList(j['alerts'])) PromAlert.fromJson(a)],
        rules: [for (final r in asMapList(j['rules'])) RuleMatch.fromJson(r)],
        rulesTotal: _int(j['rulesTotal']),
        jobs: _strs(j['jobs']),
        errors: _strMap(j['errors']),
      );
}

// ---- Alertmanager's running config ----

class AMRoute {
  final String receiver;
  final List<String> matchers;
  final List<String> groupBy;
  final bool continues;
  final String? groupWait, groupInterval, repeatInterval;
  final List<String> muteTimeIntervals, activeTimeIntervals;

  /// The AlertmanagerConfig the route came from (receiver `<ns>/<name>/<receiver>`).
  final SourceRef? source;
  final List<AMRoute> routes;
  const AMRoute({
    this.receiver = '',
    this.matchers = const [],
    this.groupBy = const [],
    this.continues = false,
    this.groupWait,
    this.groupInterval,
    this.repeatInterval,
    this.muteTimeIntervals = const [],
    this.activeTimeIntervals = const [],
    this.source,
    this.routes = const [],
  });

  factory AMRoute.fromJson(Json j) => AMRoute(
        receiver: '${j['receiver'] ?? ''}',
        matchers: _strs(j['matchers']),
        groupBy: _strs(j['groupBy']),
        continues: j['continue'] == true,
        groupWait: _nonEmpty(j['groupWait']),
        groupInterval: _nonEmpty(j['groupInterval']),
        repeatInterval: _nonEmpty(j['repeatInterval']),
        muteTimeIntervals: _strs(j['muteTimeIntervals']),
        activeTimeIntervals: _strs(j['activeTimeIntervals']),
        source: _source(j['source']),
        routes: [for (final r in asMapList(j['routes'])) AMRoute.fromJson(r)],
      );
}

class AMReceiver {
  final String name;
  final List<(String type, int count)> integrations;
  final SourceRef? source;
  const AMReceiver({required this.name, this.integrations = const [], this.source});

  factory AMReceiver.fromJson(Json j) => AMReceiver(
        name: '${j['name'] ?? ''}',
        integrations: [for (final i in asMapList(j['integrations'])) ('${i['type']}', _int(i['count']))],
        source: _source(j['source']),
      );
}

typedef AMInhibitRule = ({List<String> source, List<String> target, List<String> equal});
typedef AMTimeInterval = ({String name, int ranges, List<String> summary});

class AMStatus {
  final PromInstance? alertmanager;
  final String version, uptime, clusterStatus;
  final int peers;
  final AMRoute? route;
  final List<AMReceiver> receivers;
  final List<AMInhibitRule> inhibitRules;
  final List<AMTimeInterval> timeIntervals;

  /// The running config as YAML, with secrets redacted by the backend.
  final String config;
  const AMStatus({
    this.alertmanager,
    this.version = '',
    this.uptime = '',
    this.clusterStatus = '',
    this.peers = 0,
    this.route,
    this.receivers = const [],
    this.inhibitRules = const [],
    this.timeIntervals = const [],
    this.config = '',
  });

  factory AMStatus.fromJson(Json j) => AMStatus(
        alertmanager: PromInstance.maybe(j['alertmanager']),
        version: '${j['version'] ?? ''}',
        uptime: '${j['uptime'] ?? ''}',
        clusterStatus: '${j['clusterStatus'] ?? ''}',
        peers: _int(j['peers']),
        route: j['route'] is Map ? AMRoute.fromJson(asMap(j['route'])) : null,
        receivers: [for (final r in asMapList(j['receivers'])) AMReceiver.fromJson(r)],
        inhibitRules: [
          for (final r in asMapList(j['inhibitRules'])) (source: _strs(r['sourceMatchers']), target: _strs(r['targetMatchers']), equal: _strs(r['equal'])),
        ],
        timeIntervals: [
          for (final t in asMapList(j['timeIntervals'])) (name: '${t['name'] ?? ''}', ranges: _int(t['ranges']), summary: _strs(t['summary'])),
        ],
        config: '${j['config'] ?? ''}',
      );
}

// ---- what the operator's custom resources select ----

class SelectedKind {
  final String kind;
  final int total, count;
  final List<ObjectRef> selected;
  final String? error;
  const SelectedKind({required this.kind, this.total = 0, this.count = 0, this.selected = const [], this.error});

  factory SelectedKind.fromJson(Json j) => SelectedKind(
        kind: '${j['kind'] ?? ''}',
        total: _int(j['total']),
        count: _int(j['count']),
        selected: [for (final r in asMapList(j['selected'])) ?refFromJson(r)],
        error: _nonEmpty(j['error']),
      );
}

class Selection {
  final List<SelectedKind> kinds;
  final PromInstance? instance;
  final bool hasTargets;
  final int up, down, unknown;
  final List<TargetPool> pools;
  const Selection({this.kinds = const [], this.instance, this.hasTargets = false, this.up = 0, this.down = 0, this.unknown = 0, this.pools = const []});

  factory Selection.fromJson(Json j) {
    final t = asMap(j['targets']);
    return Selection(
      kinds: [for (final k in asMapList(j['kinds'])) SelectedKind.fromJson(k)],
      instance: PromInstance.maybe(j['instance']),
      hasTargets: t.isNotEmpty,
      up: _int(t['up']),
      down: _int(t['down']),
      unknown: _int(t['unknown']),
      pools: [for (final p in asMapList(t['pools'])) TargetPool.fromJson(p)],
    );
  }
}

class SelectedBy {
  final String kind, namespace, name;
  final bool selected;
  final String detail;

  /// The Alertmanager's alertmanagerConfigMatcherStrategy (AlertmanagerConfigs only).
  final String? matcherStrategy;
  const SelectedBy({required this.kind, required this.namespace, required this.name, this.selected = false, this.detail = '', this.matcherStrategy});

  factory SelectedBy.fromJson(Json j) => SelectedBy(
        kind: '${j['kind'] ?? ''}',
        namespace: '${j['namespace'] ?? ''}',
        name: '${j['name'] ?? ''}',
        selected: j['selected'] == true,
        detail: '${j['detail'] ?? ''}',
        matcherStrategy: _nonEmpty(j['matcherStrategy']),
      );

  ObjectRef get ref => ObjectRef(group: 'monitoring.coreos.com', kind: kind, namespace: namespace, name: name);
}
