import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'logic.dart';
import 'widgets.dart';
import '../../ui/widgets/atoms.dart';

class ResourceQuotaPanel extends ResourcePanel {
  const ResourceQuotaPanel();

  @override
  Set<String> get kinds => {'/ResourceQuota'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final scopes = strList(ctx.spec['scopes']);
    final exprs = asMapList(dig(ctx.spec, ['scopeSelector', 'matchExpressions']));
    return [
      DetailSection(title: 'Usage (used / hard)', icon: Icons.data_usage, child: QuotaBars(ctx.object)),
      if (scopes.isNotEmpty || exprs.isNotEmpty)
        DetailSection(
          title: 'Scopes',
          icon: Icons.filter_alt_outlined,
          child: KeyValueTable([
            ('Scopes', scopes.isEmpty ? null : Wrap(spacing: 4, runSpacing: 4, children: [for (final s in scopes) Chipish(text: s)])),
            ('Scope selector', exprs.isEmpty
                ? null
                : Wrap(spacing: 4, runSpacing: 4, children: [
                    for (final e in exprs)
                      Chipish(text: '${e['scopeName']} ${e['operator']}${strList(e['values']).isEmpty ? '' : ' (${strList(e['values']).join(', ')})'}'),
                  ])),
          ], keyWidth: 110),
        ),
    ];
  }
}

/// used-vs-hard bars for one ResourceQuota object.
class QuotaBars extends StatelessWidget {
  final Json quota;
  const QuotaBars(this.quota, {super.key});

  @override
  Widget build(BuildContext context) {
    final hard = {...asMap(dig(quota, ['spec', 'hard'])), ...asMap(dig(quota, ['status', 'hard']))};
    final used = asMap(dig(quota, ['status', 'used']));
    if (hard.isEmpty) return const InlineMessage('No hard limits set');
    final keys = hard.keys.toList()..sort();
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final k in keys)
        () {
          final h = parseQty(k, hard[k]);
          final u = parseQty(k, used[k]) ?? 0;
          return UsageBar(
            label: k,
            labelWidth: 150,
            used: u,
            total: h,
            usedText: used.containsKey(k) ? formatQty(k, u) : '?',
            totalText: formatQty(k, h),
          );
        }(),
    ]);
  }
}

/// Per limit type (Container/Pod/PVC), a min/request/limit/max/ratio table.
class LimitRangeTables extends StatelessWidget {
  final List<Json> limits;
  const LimitRangeTables(this.limits, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (limits.isEmpty) return const InlineMessage('No limits');
    const cols = ['min', 'defaultRequest', 'default', 'max', 'maxLimitRequestRatio'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final l in limits) ...[
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Text('${l['type'] ?? '?'}', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w700)),
        ),
        () {
          final resources = <String>{for (final c in cols) ...asMap(l[c]).keys}.toList()..sort();
          return CompactTable.ruled(
            headers: const ['RESOURCE', 'MIN', 'DEF REQ', 'DEF LIMIT', 'MAX', 'RATIO'],
            flex: const [4, 3, 3, 3, 3, 2],
            align: const [TextAlign.left, TextAlign.right, TextAlign.right, TextAlign.right, TextAlign.right, TextAlign.right],
            rows: [
              for (final r in resources)
                [
                  MonoText(r, size: 11, ellipsis: true),
                  for (final c in cols)
                    () {
                      final v = asMap(l[c])[r];
                      if (v == null) return MonoText('—', color: theme.hintColor, size: 11, ellipsis: true);
                      return MonoText(c == 'maxLimitRequestRatio' ? '$v' : formatQty(r, parseQty(r, v)), size: 11, ellipsis: true);
                    }(),
                ],
            ],
          );
        }(),
      ],
    ]);
  }
}

class LimitRangePanel extends ResourcePanel {
  const LimitRangePanel();

  @override
  Set<String> get kinds => {'/LimitRange'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) => [
        DetailSection(
          title: 'Limits',
          icon: Icons.straighten,
          child: LimitRangeTables(asMapList(ctx.spec['limits'])),
        ),
      ];
}
