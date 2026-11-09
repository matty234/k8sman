import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'kyverno_common.dart';
import '../../ui/widgets/atoms.dart';

/// ClusterPolicy and Policy: rules, status, and the results the policy
/// produced in cached PolicyReports.
class KyvernoPolicyPanel extends ResourcePanel {
  const KyvernoPolicyPanel();

  @override
  Set<String> get kinds => {'$kyvernoGroup/ClusterPolicy', '$kyvernoGroup/Policy'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final rules = asMapList(ctx.spec['rules']);
    final conds = ctx.status['conditions'];
    final action = ctx.spec['validationFailureAction'] ?? {for (final r in rules) ?dig<String>(r, ['validate', 'failureAction'])}.join(', ');
    return [
      DetailSection(
        title: 'Policy',
        icon: Icons.policy_outlined,
        card: true,
        child: KeyValueTable([
          ('Action', '$action'),
          ('Background', ctx.spec['background'] == false ? 'off' : 'on'),
          ('Admission', ctx.spec['admission'] == false ? 'off' : 'on'),
          ('Rules', '${rules.length}'),
        ], keyWidth: 100),
      ),
      DetailSection(
        title: 'Rules',
        icon: Icons.rule,
        trailing: HintText('${rules.length}'),
        child: rules.isEmpty
            ? const HintText('No rules')
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final r in rules) Padding(padding: const EdgeInsets.only(bottom: 10), child: _Rule(r)),
              ]),
      ),
      if (conds is List && conds.isNotEmpty || ctx.status['ready'] != null)
        DetailSection(
          title: 'Status',
          icon: Icons.checklist,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (ctx.status['ready'] != null) KeyValueTable([('Ready', '${ctx.status['ready']}')], keyWidth: 100),
            if (conds is List && conds.isNotEmpty) ConditionsTable(conds),
            if (dig<Object>(ctx.status, ['rulecount']) case final Map rc when rc.isNotEmpty)
              KeyValueTable([for (final e in rc.entries) ('${e.key} rules', '${e.value}')], keyWidth: 100),
          ]),
        ),
      PolicyResultsSection(key: ValueKey('results-${ctx.uid}'), ctx: ctx),
    ];
  }
}

String _rulePurpose(Json rule) {
  for (final k in const ['validate', 'mutate', 'generate', 'verifyImages']) {
    if (rule[k] != null) return k;
  }
  return 'other';
}

/// "kinds: Pod · namespaces: a, b" for one `resources` filter.
String _filter(Json f) {
  final res = asMap(f['resources']);
  String list(String k) => [for (final x in (res[k] as List? ?? const [])) '$x'].join(', ');
  final parts = <String>[
    for (final (label, key) in const [('kinds', 'kinds'), ('names', 'names'), ('namespaces', 'namespaces'), ('operations', 'operations')])
      if (list(key).isNotEmpty) '$label: ${list(key)}',
    if (asMap(dig<Object>(res, ['selector', 'matchLabels'])).isNotEmpty)
      'selector: ${asMap(dig<Object>(res, ['selector', 'matchLabels'])).entries.map((e) => '${e.key}=${e.value}').join(',')}',
    if (asMap(dig<Object>(res, ['namespaceSelector', 'matchLabels'])).isNotEmpty)
      'ns selector: ${asMap(dig<Object>(res, ['namespaceSelector', 'matchLabels'])).entries.map((e) => '${e.key}=${e.value}').join(',')}',
    if (asMapList(f['subjects']).isNotEmpty) 'subjects: ${asMapList(f['subjects']).map((s) => '${s['name']}').join(', ')}',
    if ((f['roles'] as List? ?? const []).isNotEmpty) 'roles: ${(f['roles'] as List).join(', ')}',
    if ((f['clusterRoles'] as List? ?? const []).isNotEmpty) 'clusterRoles: ${(f['clusterRoles'] as List).join(', ')}',
  ];
  return parts.join(' · ');
}

/// A `match` or `exclude` block as lines: `any` entries are alternatives,
/// `all` entries are combined.
List<String> matchLines(Json block) {
  final out = <String>[];
  final any = asMapList(block['any']);
  final all = asMapList(block['all']);
  for (final f in any) {
    out.add('${out.isEmpty ? '' : 'or '}${_filter(f)}');
  }
  for (final f in all) {
    out.add('${out.isEmpty ? '' : 'and '}${_filter(f)}');
  }
  if (block['resources'] != null || block['subjects'] != null) out.add(_filter(block));
  return [for (final l in out) if (l.trim().isNotEmpty && l.trim() != 'or' && l.trim() != 'and') l];
}

class _Rule extends StatelessWidget {
  final Json rule;
  const _Rule(this.rule);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final purpose = _rulePurpose(rule);
    final match = matchLines(asMap(rule['match']));
    final exclude = matchLines(asMap(rule['exclude']));
    final body = purpose == 'other' ? null : rule[purpose];
    Json? detail;
    if (body is Map) {
      detail = {
        for (final e in body.entries)
          if (e.key != 'message') '${e.key}': e.value,
      };
    } else if (body is List) {
      detail = {purpose: body};
    }
    final message = body is Map ? body['message'] : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InlineWrap([
        Text('${rule['name'] ?? ''}', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
        Chipish(text: purpose),
      ]),
      if (match.isNotEmpty) _line(context, 'match', match.join('\n')),
      if (exclude.isNotEmpty) _line(context, 'exclude', exclude.join('\n')),
      if (asMap(rule['preconditions']).isNotEmpty) _line(context, 'preconditions', compactYaml(rule['preconditions'])),
      if (message != null) _line(context, 'message', '$message'),
      if (detail != null && detail.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: CodeBlock(compactYaml(detail))),
    ]);
  }

  Widget _line(BuildContext context, String label, String text) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 78, child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
      ]),
    );
  }
}

/// What a policy produced in the cached PolicyReports: pass/fail counts and
/// the failing resources.
class PolicyResultsSection extends StatelessWidget {
  final PanelContext ctx;
  const PolicyResultsSection({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) {
    if (ctx.app.typeForResource(reportGroup, 'policyreports') == null && ctx.app.typeForResource(reportGroup, 'clusterpolicyreports') == null) {
      return const SizedBox.shrink();
    }
    final ns = ctx.namespace;
    final key = ns == null ? ctx.name : '$ns/${ctx.name}';
    return NetFetch<List<PolicyResult>>(
      fetchKey: key,
      load: () async => [
        for (final r in flattenReports(await allReports(ctx.api, ctx.app)))
          if (r.policy == key || (ns != null && r.policy == ctx.name && r.resource?.namespace == ns)) r,
      ],
      builder: (context, snap, reload) {
        final all = snap.data;
        return DetailSection(
          title: 'Results',
          icon: Icons.fact_check_outlined,
          trailing: RefreshButton(reload),
          child: snap.connectionState != ConnectionState.done
              ? SectionSpinner()
              : snap.hasError
                  ? HintText('Could not read policy reports: ${snap.error}')
                  : all!.isEmpty
                      ? const HintText('No results in the cached policy reports')
                      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          ResultCounts(all),
                          const SizedBox(height: 6),
                          ResultsList(sortResults(all).where((r) => r.result != 'pass').toList(), showPolicy: false),
                        ]),
        );
      },
    );
  }
}
