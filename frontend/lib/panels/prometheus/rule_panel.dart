import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../prometheus/prom_api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'common.dart';
import '../../ui/widgets/atoms.dart';

/// PrometheusRule: groups and rules from the spec, with live state
/// (inactive / pending / firing, health, lastError) from Prometheus.
class PrometheusRulePanel extends ResourcePanel {
  const PrometheusRulePanel();

  @override
  Set<String> get kinds => {'monitoring.coreos.com/PrometheusRule'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) => [
        CoreSection('rules', _RuleGroups(key: ValueKey(ctx.uid), ctx: ctx, resourceVersion: '${ctx.metadata['resourceVersion']}')),
      ];
}

class _RuleGroups extends StatefulWidget {
  final PanelContext ctx;
  final String resourceVersion;
  const _RuleGroups({super.key, required this.ctx, required this.resourceVersion});

  @override
  State<_RuleGroups> createState() => _RuleGroupsState();
}

class _RuleGroupsState extends State<_RuleGroups> {
  late Future<RulesData> _live;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    _live = PromApi.of(widget.ctx.api).rules(namespace: widget.ctx.namespace, name: widget.ctx.name);
  }

  @override
  void didUpdateWidget(covariant _RuleGroups old) {
    super.didUpdateWidget(old);
    // The operator reloads Prometheus shortly after a change; refetch then.
    if (old.resourceVersion != widget.resourceVersion) setState(_fetch);
  }

  @override
  Widget build(BuildContext context) {
    final groups = asMapList(widget.ctx.spec['groups']);
    return FutureBuilder<RulesData>(
      future: _live,
      builder: (context, snap) {
        final live = snap.data;
        final loading = snap.connectionState != ConnectionState.done;
        final rules = [for (final g in groups) ...asMapList(g['rules'])];
        final alerts = rules.where((r) => r['alert'] != null).length;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DetailSection(
            title: 'Live state',
            icon: Icons.monitor_heart_outlined,
            trailing: IconButton(
              tooltip: 'Refresh',
              visualDensity: VisualDensity.compact,
              iconSize: 15,
              onPressed: loading ? null : () => setState(_fetch),
              icon: const Icon(Icons.refresh),
            ),
            child: _Summary(groups: groups.length, alerts: alerts, records: rules.length - alerts, live: live, loading: loading, error: snap.error, ctx: widget.ctx),
          ),
          for (final g in groups)
            DetailSection(
              title: '${g['name'] ?? 'group'}',
              icon: Icons.rule_folder_outlined,
              trailing: HintText([
                '${asMapList(g['rules']).length} rule${asMapList(g['rules']).length == 1 ? '' : 's'}',
                if (g['interval'] != null) 'every ${g['interval']}',
              ].join(' · ')),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                for (final (i, r) in asMapList(g['rules']).indexed) ...[
                  if (i > 0) Divider(height: 1, color: AppColors.of(context).separator),
                  RuleCard(rule: r, live: live?.find('${g['name']}', '${r['alert'] ?? r['record']}')),
                ],
              ]),
            ),
        ]);
      },
    );
  }
}

class _Summary extends StatelessWidget {
  final int groups, alerts, records;
  final RulesData? live;
  final bool loading;
  final Object? error;
  final PanelContext ctx;
  const _Summary({required this.groups, required this.alerts, required this.records, required this.live, required this.loading, required this.error, required this.ctx});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = live;
    final counts = Text(
      '$groups group${groups == 1 ? '' : 's'} · $alerts alert${alerts == 1 ? '' : 's'} · $records recording rule${records == 1 ? '' : 's'}',
      style: theme.textTheme.bodySmall,
    );
    if (error != null) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [counts, const SizedBox(height: 6), LiveStateMessage(error!)]);
    if (l == null) return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [counts, const SizedBox(height: 6), const HintText('Loading live state…')]);
    final loaded = l.groups.isNotEmpty;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      counts,
      const SizedBox(height: 6),
      if (!loaded)
        HintText('Not loaded by ${l.prometheus?.name ?? 'Prometheus'} (check its ruleSelector and ruleNamespaceSelector).')
      else
        Wrap(spacing: 14, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _Count('firing', l.firing, l.firing > 0 ? severityColor(context, Severity.error) : null),
          _Count('pending', l.pending, l.pending > 0 ? severityColor(context, Severity.warn) : null),
          _Count('inactive', l.inactive, null),
          if (l.errors > 0) _Count('with errors', l.errors, severityColor(context, Severity.error)),
          HintText('on ${l.prometheus?.name ?? 'Prometheus'}'),
          if (l.firing + l.pending > 0) OpenAlertsButton(ctx.app),
        ]),
    ]);
  }
}

class _Count extends StatelessWidget {
  final String label;
  final int n;
  final Color? color;
  const _Count(this.label, this.n, this.color);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text.rich(TextSpan(children: [
      TextSpan(text: '$n', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: color)),
      TextSpan(text: ' $label', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
    ]));
  }
}

/// One rule: name, type, live state, expression, for, labels, annotations.
class RuleCard extends StatelessWidget {
  final Json rule;
  final RuleState? live;
  const RuleCard({super.key, required this.rule, this.live});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isAlert = rule['alert'] != null;
    final name = '${rule['alert'] ?? rule['record'] ?? ''}';
    final labels = asMap(rule['labels']);
    final annotations = asMap(rule['annotations']);
    final l = live;
    final firingCount = l?.alerts.where((a) => a['state'] == 'firing').length ?? 0;
    final pendingCount = l?.alerts.where((a) => a['state'] == 'pending').length ?? 0;
    final stateText = switch (l?.state) {
      'firing' => firingCount > 1 ? 'Firing ×$firingCount' : 'Firing',
      'pending' => pendingCount > 1 ? 'Pending ×$pendingCount' : 'Pending',
      'inactive' => 'Inactive',
      _ => null,
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Icon(isAlert ? Icons.notifications_none : Icons.functions, size: 15, color: theme.hintColor),
          Text(name, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          HintText(isAlert ? 'alert' : 'record'),
          if (isAlert && stateText != null) StatusBadge(stateText, dense: true, severity: ruleStateBadge(l?.state, '${labels['severity'] ?? ''}')),
          if (l != null && l.health == 'err') StatusBadge('Error', dense: true, severity: Severity.error),
          if (!isAlert && l != null && l.health == 'ok') StatusBadge('OK', dense: true, severity: Severity.ok),
        ]),
        const SizedBox(height: 6),
        CodeBlock('${rule['expr'] ?? ''}'.trim()),
        if (l?.lastError != null) ...[
          const SizedBox(height: 4),
          InlineMessage(l!.lastError!, isError: true),
        ],
        if (isAlert || labels.isNotEmpty || annotations.isNotEmpty) ...[
          const SizedBox(height: 6),
          KeyValueTable([
            if (rule['for'] != null) ('For', '${rule['for']}'),
            if (rule['keep_firing_for'] != null) ('Keep firing for', '${rule['keep_firing_for']}'),
            if (labels.isNotEmpty) ('Labels', LabelChips(labels)),
            for (final e in annotations.entries)
              (
                e.key,
                e.key == 'runbook_url' && '${e.value}'.startsWith('http')
                    ? _UrlLink('${e.value}')
                    : Text('${e.value}', style: theme.textTheme.bodySmall),
              ),
          ], keyWidth: 110),
        ],
      ]),
    );
  }
}

class _UrlLink extends StatelessWidget {
  final String url;
  const _UrlLink(this.url);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Hoverable(
      onTap: () => openUrl(url),
      builder: (h) => Text(url,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary, decoration: h ? TextDecoration.underline : null)),
    );
  }
}
