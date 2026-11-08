/// Shared pieces of the Kyverno panels: reading PolicyReports (both the
/// per-namespace shape with `results[].resources[]` and the newer
/// per-resource shape with `scope`), matching results to objects, and the
/// results list.
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../pod/pod_widgets.dart';

const kyvernoGroup = 'kyverno.io';
const reportGroup = 'wgpolicyk8s.io';

/// How many results a list shows before "and N more".
const resultLimit = 50;

/// One entry of a report's `results`, for one resource.
class PolicyResult {
  final String policy;
  final String rule;

  /// pass, fail, warn, error or skip.
  final String result;
  final String severity;
  final String message;

  /// Kyverno's `source` ("kyverno", "KyvernoValidatingPolicy", …).
  final String source;
  final ObjectRef? resource;
  final String resourceUid;
  final String report;
  const PolicyResult({
    required this.policy,
    required this.rule,
    required this.result,
    this.severity = '',
    this.message = '',
    this.source = '',
    this.resource,
    this.resourceUid = '',
    this.report = '',
  });

  /// The policy object this result names: `ns/name` is a namespaced Policy,
  /// a plain name a ClusterPolicy (or a 1.14+ policy, per [source]).
  ObjectRef get policyRef {
    final i = policy.indexOf('/');
    if (i > 0) return ObjectRef(group: kyvernoGroup, kind: 'Policy', namespace: policy.substring(0, i), name: policy.substring(i + 1));
    final s = source.replaceFirst('Kyverno', '');
    if (s.endsWith('ValidatingPolicy') || s.endsWith('MutatingPolicy') || s.endsWith('GeneratingPolicy')) {
      return ObjectRef(group: 'policies.kyverno.io', kind: s, name: policy);
    }
    return ObjectRef(group: kyvernoGroup, kind: 'ClusterPolicy', name: policy);
  }

  String get policyLabel => policy.contains('/') ? policy.substring(policy.indexOf('/') + 1) : policy;
}

/// Order of results in lists: failures first.
int resultRank(String r) => switch (r) { 'fail' => 0, 'error' => 1, 'warn' => 2, 'skip' => 3, _ => 4 };

Severity resultSeverity(String r) => switch (r) {
      'fail' || 'error' => Severity.error,
      'warn' => Severity.warn,
      'pass' => Severity.ok,
      _ => Severity.neutral,
    };

/// Failures first, then by policy and rule.
List<PolicyResult> sortResults(Iterable<PolicyResult> rs) => rs.toList()
  ..sort((a, b) {
    final c = resultRank(a.result).compareTo(resultRank(b.result));
    if (c != 0) return c;
    final p = a.policy.compareTo(b.policy);
    return p != 0 ? p : a.rule.compareTo(b.rule);
  });

/// A report's results, one per resource: the `scope` for per-resource
/// reports, else the entry's `resources`.
List<PolicyResult> flattenReport(Json report) {
  final ns = dig<String>(report, ['metadata', 'namespace']);
  final name = dig<String>(report, ['metadata', 'name']) ?? '';
  final scope = asMap(report['scope']);
  (ObjectRef, String)? res(Json m) => m['kind'] == null || m['name'] == null
      ? null
      : (ObjectRef.fromOwnerRef(m, namespace: m['namespace'] as String? ?? ns), '${m['uid'] ?? ''}');
  final scopeRes = res(scope);
  final out = <PolicyResult>[];
  for (final r in asMapList(report['results'])) {
    PolicyResult one((ObjectRef, String)? target) => PolicyResult(
          policy: '${r['policy'] ?? ''}',
          rule: '${r['rule'] ?? ''}',
          result: '${r['result'] ?? ''}',
          severity: '${r['severity'] ?? ''}',
          message: '${r['message'] ?? ''}',
          source: '${r['source'] ?? ''}',
          resource: target?.$1,
          resourceUid: target?.$2 ?? '',
          report: name,
        );
    final resources = [for (final m in asMapList(r['resources'])) ?res(m)];
    if (resources.isEmpty) {
      out.add(one(scopeRes));
    } else {
      for (final t in resources) {
        out.add(one(t));
      }
    }
  }
  return out;
}

/// [flattenReport] over several reports.
List<PolicyResult> flattenReports(List<Json> reports) => [for (final r in reports) ...flattenReport(r)];

/// Results across [reports] that mention the object: reports owned by it or
/// scoped to it, and entries naming it (by uid, else kind/name/namespace).
List<PolicyResult> resultsForObject(List<Json> reports, {required String uid, required String kind, required String name, String? namespace}) {
  final out = <PolicyResult>[];
  for (final rep in reports) {
    final owned = uid.isNotEmpty && asMapList(dig(rep, ['metadata', 'ownerReferences'])).any((o) => o['uid'] == uid);
    for (final r in flattenReport(rep)) {
      final t = r.resource;
      final byUid = uid.isNotEmpty && r.resourceUid.isNotEmpty;
      final match = owned ||
          (byUid
              ? r.resourceUid == uid
              : t != null && t.kind == kind && t.name == name && (t.namespace ?? '') == (namespace ?? ''));
      if (match) out.add(r);
    }
  }
  return sortResults(out);
}

final _cache = <(ApiClient, String, String, String), (DateTime, Future<List<Json>>)>{};

/// The cluster's `policyreports` (of [namespace], or all namespaces) or
/// `clusterpolicyreports`: one list per namespace, kept for 30 s. Empty when
/// the kind isn't served.
Future<List<Json>> cachedReports(ApiClient api, AppState app, String resource, {String? namespace}) {
  final t = app.typeForResource(reportGroup, resource);
  if (t == null) return Future.value(const []);
  final key = (api, app.currentContext, resource, namespace ?? '');
  final hit = _cache[key];
  if (hit != null && DateTime.now().difference(hit.$1) < const Duration(seconds: 30)) return hit.$2;
  final f = api.items(t.ref, namespace: t.namespaced ? namespace : null);
  _cache[key] = (DateTime.now(), f);
  f.catchError((Object _) {
    _cache.remove(key);
    return <Json>[];
  });
  return f;
}

/// Every report in the cluster (namespaced and cluster-scoped).
Future<List<Json>> allReports(ApiClient api, AppState app) async =>
    [for (final l in await Future.wait([cachedReports(api, app, 'policyreports'), cachedReports(api, app, 'clusterpolicyreports')])) ...l];

/// Counts per result, as small chips.
class ResultCounts extends StatelessWidget {
  final Iterable<PolicyResult> results;
  const ResultCounts(this.results, {super.key});

  @override
  Widget build(BuildContext context) {
    final n = <String, int>{};
    for (final r in results) {
      n[r.result] = (n[r.result] ?? 0) + 1;
    }
    final keys = n.keys.toList()..sort((a, b) => resultRank(a).compareTo(resultRank(b)));
    return InlineWrap([for (final k in keys) _CountBadge(k, n[k]!)]);
  }
}

class _CountBadge extends StatelessWidget {
  final String result;
  final int count;
  const _CountBadge(this.result, this.count);

  @override
  Widget build(BuildContext context) => StatusBadge('$count $result', severity: resultSeverity(result));
}

/// Results as rows: result, policy (link) and rule, the message, and the
/// resource (link) unless [showResource] is false. At most [limit] rows.
class ResultsList extends StatelessWidget {
  final List<PolicyResult> results;
  final bool showPolicy;
  final bool showResource;
  final int limit;
  const ResultsList(this.results, {super.key, this.showPolicy = true, this.showResource = true, this.limit = resultLimit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = results.take(limit).toList();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final r in shown)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            InlineWrap([
              StatusBadge(r.result, dense: true, severity: resultSeverity(r.result)),
              if (showPolicy) ResourceLink(r.policyRef, label: r.policyLabel),
              if (r.rule.isNotEmpty) Text(showPolicy ? '/ ${r.rule}' : r.rule, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              if (r.severity.isNotEmpty) Chipish(text: r.severity),
              if (showResource && r.resource != null) ResourceLink(r.resource!, label: '${r.resource!.kind}/${r.resource!.name}'),
            ]),
            if (r.message.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Text(r.message, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              ),
          ]),
        ),
      if (results.length > shown.length)
        Padding(padding: const EdgeInsets.only(top: 4), child: Hint('and ${results.length - shown.length} more')),
    ]);
  }
}

/// Compact YAML-like text for rule bodies (maps, lists, scalars).
String compactYaml(Object? v, [int indent = 0]) {
  final pad = '  ' * indent;
  if (v is Map) {
    if (v.isEmpty) return '{}';
    return v.entries.map((e) {
      final x = e.value;
      final nested = (x is Map && x.isNotEmpty) || (x is List && x.isNotEmpty);
      return nested ? '$pad${e.key}:\n${compactYaml(x, indent + 1)}' : '$pad${e.key}: ${compactYaml(x)}';
    }).join('\n');
  }
  if (v is List) {
    if (v.isEmpty) return '[]';
    return v.map((x) {
      if (x is Map && x.isNotEmpty) {
        final lines = compactYaml(x, indent + 1).split('\n');
        return '$pad- ${lines.first.trimLeft()}${lines.length > 1 ? '\n${lines.skip(1).join('\n')}' : ''}';
      }
      return '$pad- ${compactYaml(x)}';
    }).join('\n');
  }
  return v == null ? 'null' : '$v';
}
