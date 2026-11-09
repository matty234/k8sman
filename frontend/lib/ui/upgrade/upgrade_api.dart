/// Typed access to the backend's `GET /api/upgrade` (the Upgrade readiness
/// module): what stands between the cluster and a newer Kubernetes minor.
/// Ignore rules live in the module's settings (`{"ignores": [...]}`) in the
/// Security page's rule shape, so its ignore dialog applies.
library;

import '../../api/backend_http.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../util/json.dart';
import '../../util/k8s.dart';
import '../security/security_api.dart';

enum UpgradeSeverity {
  blocker,
  warning,
  info;

  static UpgradeSeverity parse(Object? v) => switch (v) {
        'blocker' => blocker,
        'warning' => warning,
        _ => info,
      };

  String get label => switch (this) {
        blocker => 'Blocker',
        warning => 'Warning',
        info => 'Info',
      };

  /// The app's severity scale (colours, bars, marks).
  Severity get badge => switch (this) {
        blocker => Severity.error,
        warning => Severity.warn,
        info => Severity.info,
      };
}

class UpgradeFinding {
  final String id;
  final String check;
  final UpgradeSeverity severity;
  final String title;
  final String detail;
  final String why;
  final String action;
  final String? namespace;
  final List<ObjectRef> objects;
  final String? docs;

  /// A kubectl command line without `kubectl` (the page adds the context).
  final List<String> kubectl;

  const UpgradeFinding({
    required this.id,
    required this.check,
    required this.severity,
    required this.title,
    this.detail = '',
    this.why = '',
    this.action = '',
    this.namespace,
    this.objects = const [],
    this.docs,
    this.kubectl = const [],
  });

  factory UpgradeFinding.fromJson(Json j) => UpgradeFinding(
        id: asStr(j['id']),
        check: asStr(j['check']),
        severity: UpgradeSeverity.parse(j['severity']),
        title: asStr(j['title']),
        detail: asStr(j['detail']),
        why: asStr(j['why']),
        action: asStr(j['action']),
        namespace: asStr(j['namespace']).isEmpty ? null : asStr(j['namespace']),
        objects: [for (final o in asMapList(j['objects'])) refFromJson(o)],
        docs: asStr(j['docs']).isEmpty ? null : asStr(j['docs']),
        kubectl: [for (final a in (j['kubectl'] as List? ?? const [])) '$a'],
      );

  /// As a Security finding, for the shared ignore dialog and rule matching.
  SecFinding get asSecFinding => SecFinding(
        id: id,
        check: check,
        severity: switch (severity) {
          UpgradeSeverity.blocker => SecSeverity.critical,
          UpgradeSeverity.warning => SecSeverity.medium,
          UpgradeSeverity.info => SecSeverity.info,
        },
        category: check,
        title: title,
        detail: detail,
        remediation: action,
        namespace: namespace,
        objects: objects,
      );
}

/// How one check went: `clear`, `findings`, `pending`, `unavailable` (not
/// allowed to read what it needs) or `error`.
class UpgradeCheck {
  final String id;
  final String title;
  final String state;
  final Map<UpgradeSeverity, int> counts;

  /// What it says when it found nothing.
  final String clear;

  /// What it couldn't look at ("Couldn't check Helm releases: not allowed").
  final List<String> notes;
  const UpgradeCheck({required this.id, required this.title, required this.state, this.counts = const {}, this.clear = '', this.notes = const []});

  factory UpgradeCheck.fromJson(Json j) => UpgradeCheck(
        id: asStr(j['id']),
        title: asStr(j['title']),
        state: asStr(j['state']),
        counts: {for (final e in asMap(j['counts']).entries) UpgradeSeverity.parse(e.key): asInt(e.value)},
        clear: asStr(j['clear']),
        notes: [for (final n in (j['notes'] as List? ?? const [])) '$n'],
      );

  bool get pending => state == 'pending';
  bool get isClear => state == 'clear';
  bool get unavailable => state == 'unavailable' || state == 'error';
  int count(UpgradeSeverity s) => counts[s] ?? 0;
}

class UpgradeIgnored {
  final UpgradeFinding finding;
  final SecIgnoreRule rule;
  const UpgradeIgnored(this.finding, this.rule);
}

class UpgradeData {
  final String serverVersion;
  final String current;
  final String target;
  final List<String> targets;
  final List<String> steps;
  final List<UpgradeCheck> checks;
  final List<UpgradeFinding> findings;
  final List<UpgradeIgnored> ignored;
  final Map<UpgradeSeverity, int> counts;
  final int nodes;
  final List<String> pending;
  final String generatedAt;

  const UpgradeData({
    required this.serverVersion,
    required this.current,
    required this.target,
    this.targets = const [],
    this.steps = const [],
    this.checks = const [],
    this.findings = const [],
    this.ignored = const [],
    this.counts = const {},
    this.nodes = 0,
    this.pending = const [],
    this.generatedAt = '',
  });

  factory UpgradeData.fromJson(Json j) => UpgradeData(
        serverVersion: asStr(j['serverVersion']),
        current: asStr(j['current']),
        target: asStr(j['target']),
        targets: [for (final t in (j['targets'] as List? ?? const [])) '$t'],
        steps: [for (final t in (j['steps'] as List? ?? const [])) '$t'],
        checks: [for (final c in asMapList(j['checks'])) UpgradeCheck.fromJson(c)],
        findings: [for (final f in asMapList(j['findings'])) UpgradeFinding.fromJson(f)],
        ignored: [
          for (final f in asMapList(j['ignored'])) UpgradeIgnored(UpgradeFinding.fromJson(f), SecIgnoreRule.fromJson(asMap(f['rule']))),
        ],
        counts: {for (final e in asMap(j['counts']).entries) UpgradeSeverity.parse(e.key): asInt(e.value)},
        nodes: asInt(j['nodes']),
        pending: [for (final p in (j['pending'] as List? ?? const [])) '$p'],
        generatedAt: asStr(j['generatedAt']),
      );

  int count(UpgradeSeverity s) => counts[s] ?? 0;
  bool get checking => checks.any((c) => c.pending);
}

class UpgradeApi {
  final ApiClient api;
  final BackendHttp _http;
  UpgradeApi(this.api) : _http = BackendHttp(api, '/api/');

  static final _of = PerApi(UpgradeApi.new);
  static set debugOverride(UpgradeApi Function(ApiClient api)? f) => _of.debugOverride = f;
  static UpgradeApi of(ApiClient api) => _of(api);

  /// The findings for [target] ("1.33"; null = the next minor).
  Future<UpgradeData> fetch({String? target}) async => UpgradeData.fromJson(jsonObjectBody(await _http.get('upgrade', {'target': target})));

  static const _module = 'upgrade';

  Future<List<SecIgnoreRule>> ignores() async {
    final s = await api.getModuleSettings(_module);
    return [for (final r in asMapList(s['ignores'])) SecIgnoreRule.fromJson(r)];
  }

  Future<void> _setIgnores(List<SecIgnoreRule> rules) => api.putModuleSettings(_module, {
        if (rules.isNotEmpty) 'ignores': [for (final r in rules) r.toJson()],
      });

  Future<void> addIgnores(List<SecIgnoreRule> rules) async => _setIgnores([...await ignores(), ...rules]);

  /// Removes every rule that contributes to ignoring [f].
  Future<void> unignore(UpgradeFinding f) async => _setIgnores([for (final r in await ignores()) if (!r.relevantTo(f.asSecFinding)) r]);
}
