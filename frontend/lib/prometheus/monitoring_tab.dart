/// The inspector's Monitoring tab for Pods, Services and workloads: is the
/// object scraped, by which ServiceMonitor / PodMonitor / scrape config,
/// and if not, why (the monitors that come close and the check that
/// fails); then the alerts about it and the rules that seem to apply.
/// Added by the Prometheus module (lib/modules/prometheus_module.dart);
/// data from `/api/prom/scrape` and `/api/prom/applies`.
library;

import 'package:flutter/material.dart';

import '../api/models.dart';
import '../panels/panel.dart';
import '../panels/prometheus/common.dart' show LiveStateMessage, UpDownCounts, healthColor, ruleStateBadge;
import '../ui/alerts/alerts_widgets.dart' show AlertInstanceRow;
import '../ui/inspector/inspector.dart';
import '../ui/theme.dart';
import '../ui/widgets/atoms.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'prom_api.dart';

/// Kinds (`group/Kind`) with a Monitoring tab.
const monitoringTabKinds = {'/Pod', '/Service', 'apps/Deployment', 'apps/StatefulSet', 'apps/DaemonSet', 'apps/ReplicaSet', 'batch/Job'};

/// The Monitoring tab for [ctx]'s object.
PanelTab monitoringTab(PanelContext ctx) => PanelTab(
      label: 'Monitoring',
      builder: (context, ctx) => MonitoringTabView(key: ValueKey('monitoring-${ctx.uid}'), ctx: ctx),
    );

String _key(PanelContext ctx, String what) =>
    'prom-$what|${identityHashCode(ctx.api)}|${ctx.app.currentContext}|${ctx.type.kind}|${ctx.namespace}|${ctx.name}';

/// Targets shown per scrape pool before "+N more".
const _perPool = 12;

class MonitoringTabView extends StatelessWidget {
  final PanelContext ctx;
  const MonitoringTabView({super.key, required this.ctx});

  void _refresh() {
    SharedFetch.invalidate(_key(ctx, 'scrape'));
    SharedFetch.invalidate(_key(ctx, 'applies'));
  }

  @override
  Widget build(BuildContext context) {
    final prom = PromApi.of(ctx.api);
    final kind = ctx.type.kind;
    final ns = ctx.namespace ?? '';
    return SelectionArea(
      child: SingleChildScrollView(
        key: PageStorageKey('monitoring-${ctx.uid}'),
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SharedFetchBuilder<ObjectScrape>(
            fetchKey: _key(ctx, 'scrape'),
            fetch: () => prom.scrape(kind: kind, namespace: ns, name: ctx.name),
            builder: (context, snap) {
              if (snap.hasError && snap.data == null) {
                return InspectorSection(id: 'monitoring-scrape', title: 'Scraping', child: LiveStateMessage(snap.error!));
              }
              final d = snap.data;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                InspectorSection(
                  id: 'monitoring-scrape',
                  title: 'Scraping',
                  trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (d != null && d.scraped) UpDownCounts(up: d.up, down: d.down, unknown: d.unknown),
                    IconButton(
                      tooltip: 'Refresh',
                      visualDensity: VisualDensity.compact,
                      iconSize: 15,
                      onPressed: d == null ? null : _refresh,
                      icon: const Icon(Icons.refresh),
                    ),
                  ]),
                  child: d == null ? const SectionSpinner(size: 14, strokeWidth: 1.5) : ScrapeStatusView(data: d, kind: kind),
                ),
                if (d != null && (d.monitors.isNotEmpty || d.dropped.isNotEmpty))
                  InspectorSection(
                    id: 'monitoring-monitors',
                    title: d.scraped ? 'Monitors' : 'Why it isn\'t scraped',
                    child: MonitorChecksView(data: d),
                  ),
              ]);
            },
          ),
          SharedFetchBuilder<ObjectApplies>(
            fetchKey: _key(ctx, 'applies'),
            fetch: () => prom.applies(kind: kind, namespace: ns, name: ctx.name),
            builder: (context, snap) {
              if (snap.hasError && snap.data == null) {
                // The scrape section already says why (no Prometheus, an error).
                return const SizedBox.shrink();
              }
              final d = snap.data;
              return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                InspectorSection(
                  id: 'monitoring-alerts',
                  title: 'Alerts',
                  trailing: d == null || d.alerts.isEmpty ? null : SectionSummary('${d.alerts.length}'),
                  child: d == null ? const SectionSpinner(size: 14, strokeWidth: 1.5) : _Alerts(data: d, kind: kind),
                ),
                InspectorSection(
                  id: 'monitoring-rules',
                  title: 'Rules that may apply',
                  trailing: d == null || d.rules.isEmpty ? null : SectionSummary('${d.rulesTotal}'),
                  child: d == null ? const SectionSpinner(size: 14, strokeWidth: 1.5) : _Rules(data: d, kind: kind),
                ),
              ]);
            },
          ),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Scraping
// ---------------------------------------------------------------------------

/// Scraped: the targets by scrape pool, each under the config that made it.
/// Not scraped: a badge and the reasons found.
class ScrapeStatusView extends StatelessWidget {
  final ObjectScrape data;
  final String kind;
  const ScrapeStatusView({super.key, required this.data, required this.kind});

  @override
  Widget build(BuildContext context) {
    final d = data;
    final noun = kind.toLowerCase();
    final promError = d.errors['prometheus'];
    final scope = [
      if (kind != 'Pod' && kind != 'Service') '${d.pods} pod${d.pods == 1 ? '' : 's'}',
      if (d.services.isNotEmpty) 'behind ${d.services.length == 1 ? 'Service' : 'Services'} ${d.services.join(', ')}',
    ].join(' · ');
    if (!d.scraped) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          StatusBadge(promError != null ? 'Unknown' : 'Not scraped', dense: true, severity: promError != null ? Severity.neutral : Severity.warn),
          if (promError == null && d.prometheus != null) HintText('${d.prometheus!.name} has no target for this $noun'),
          if (scope.isNotEmpty) HintText(scope),
        ]),
        if (promError != null) ...[
          const SizedBox(height: 6),
          InlineMessage(promError.startsWith('no Prometheus') ? 'Needs a reachable Prometheus; none was found.' : 'Prometheus: $promError', icon: Icons.cloud_off_outlined),
        ],
        for (final h in d.hints)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(Icons.info_outline, size: 13, color: Theme.of(context).hintColor)),
              const SizedBox(width: 6),
              Expanded(child: Text(h, style: Theme.of(context).textTheme.bodySmall)),
            ]),
          ),
      ]);
    }
    // Group by scrape pool, keeping the backend's order (down first).
    final pools = <String, List<ScrapeTarget>>{};
    for (final t in d.targets) {
      pools.putIfAbsent(t.scrapePool, () => []).add(t);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        StatusBadge(d.down > 0 ? 'Scraped · ${d.down} down' : 'Scraped', dense: true, severity: d.down > 0 ? Severity.error : Severity.ok),
        HintText('${d.total} target${d.total == 1 ? '' : 's'} in ${pools.length} scrape pool${pools.length == 1 ? '' : 's'}'),
        if (scope.isNotEmpty) HintText(scope),
      ]),
      for (final e in pools.entries) _PoolBlock(pool: e.key, targets: e.value),
      if (d.targets.length < d.total) Padding(padding: const EdgeInsets.only(top: 6), child: HintText('Showing ${d.targets.length} of ${d.total} targets.')),
    ]);
  }
}

class _PoolBlock extends StatelessWidget {
  final String pool;
  final List<ScrapeTarget> targets;
  const _PoolBlock({required this.pool, required this.targets});

  @override
  Widget build(BuildContext context) {
    final first = targets.first;
    final m = first.monitor;
    final shown = targets.take(_perPool).toList();
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (m != null)
            ResourceLink(m.ref, label: '${m.kind} ${m.namespace}/${m.name}')
          else
            Text('Scrape config', style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
          if (first.job != null) HintText('job ${first.job}', mono: true),
          if (m != null && m.kind != 'ScrapeConfig' && m.kind != 'Probe') HintText('endpoint ${m.endpoint}'),
          if (first.scrapeInterval != null) HintText('every ${first.scrapeInterval}'),
        ]),
        Padding(padding: const EdgeInsets.only(top: 1), child: HintText(pool, mono: true, size: 10.5)),
        for (final t in shown) _TargetRow(t),
        if (targets.length > shown.length) HintText('+${targets.length - shown.length} more'),
      ]),
    );
  }
}

class _TargetRow extends StatelessWidget {
  final ScrapeTarget target;
  const _TargetRow(this.target);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final t = target;
    final last = parseTime(t.lastScrape);
    return Padding(
      padding: const EdgeInsets.only(top: 5, left: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 5),
          child: Tooltip(
            message: t.health,
            child: Container(width: 7, height: 7, decoration: BoxDecoration(color: healthColor(context, t.health), shape: BoxShape.circle)),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.scrapeUrl, maxLines: 2, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5)),
            Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
              Text(t.health, style: theme.textTheme.bodySmall?.copyWith(color: healthColor(context, t.health), fontWeight: FontWeight.w600)),
              if (t.labels['pod'] != null && t.target?.kind == 'Pod') HintText(t.labels['pod']!),
              if (last != null && last.year > 1) AgeText(t.lastScrape, suffix: ' ago', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              if (t.lastScrapeDuration > 0) HintText('took ${(t.lastScrapeDuration * 1000).toStringAsFixed(t.lastScrapeDuration < 0.01 ? 1 : 0)} ms'),
            ]),
            if (t.lastError != null)
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Text(t.lastError!, style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.error))),
              ),
          ]),
        ),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Monitors (why / why not)
// ---------------------------------------------------------------------------

/// The ServiceMonitors / PodMonitors that match the object or come close,
/// each with its checks, and the pools that found it but dropped it.
class MonitorChecksView extends StatelessWidget {
  final ObjectScrape data;
  const MonitorChecksView({super.key, required this.data});

  static const _checkLabels = {'namespace': 'Namespace', 'selector': 'Selector', 'port': 'Port', 'prometheus': 'Prometheus'};

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sep = AppColors.of(context).separator;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, m) in data.monitors.indexed) ...[
        if (i > 0) Divider(height: 14, color: sep),
        Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          ResourceLink(m.monitor.ref, label: '${m.monitor.kind} ${m.monitor.namespace}/${m.monitor.name}'),
          StatusBadge(
            m.scraping ? 'Scraping' : (m.matches ? 'Matches' : 'Doesn\'t match'),
            dense: true,
            severity: m.scraping ? Severity.ok : (m.matches ? Severity.info : Severity.warn),
          ),
          if (m.via != null) ...[const HintText('via'), ResourceLink(m.via!, label: 'Service ${m.via!.name}')],
        ]),
        // A monitor that scrapes needs no explanation; one that doesn't shows every check.
        if (!m.scraping)
          for (final c in m.checks)
            Padding(
              padding: const EdgeInsets.only(top: 3, left: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(c.ok ? Icons.check : Icons.close, size: 13, color: severityColor(context, c.ok ? Severity.ok : Severity.error)),
                const SizedBox(width: 6),
                SizedBox(width: 74, child: Text(_checkLabels[c.name] ?? c.name, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
                Expanded(child: Text(c.detail, style: theme.textTheme.bodySmall)),
              ]),
            ),
      ],
      if (data.dropped.isNotEmpty) ...[
        if (data.monitors.isNotEmpty) Divider(height: 14, color: sep),
        const HintText('Found by service discovery, then dropped by relabelling (often a port name the monitor doesn\'t list):'),
        for (final p in data.dropped)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (p.monitor != null) ResourceLink(p.monitor!.ref, label: '${p.monitor!.kind} ${p.monitor!.namespace}/${p.monitor!.name}') else HintText(p.scrapePool, mono: true),
              if (p.ports.isNotEmpty) HintText('offered port${p.ports.length == 1 ? '' : 's'} ${p.ports.join(', ')}'),
              if (p.services.isNotEmpty) HintText('Service ${p.services.join(', ')}'),
            ]),
          ),
      ],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Alerts and rules
// ---------------------------------------------------------------------------

class _Alerts extends StatelessWidget {
  final ObjectApplies data;
  final String kind;
  const _Alerts({required this.data, required this.kind});

  @override
  Widget build(BuildContext context) {
    final err = data.errors.entries.where((e) => e.key.startsWith('alerts.')).map((e) => e.value).firstOrNull;
    if (data.alerts.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        HintText('No firing or pending alerts about this ${kind.toLowerCase()}.'),
        if (err != null) Padding(padding: const EdgeInsets.only(top: 4), child: HintText(err)),
      ]);
    }
    final sep = AppColors.of(context).separator;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, a) in data.alerts.indexed) ...[
        if (i > 0) Divider(height: 1, color: sep),
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 2),
          child: Text(a.alertname, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
        ),
        AlertInstanceRow(alert: a),
      ],
    ]);
  }
}

class _Rules extends StatelessWidget {
  final ObjectApplies data;
  final String kind;
  const _Rules({required this.data, required this.kind});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final err = data.errors['rules'] ?? data.errors['prometheus'];
    final jobs = data.jobs.isEmpty ? '' : ' (job${data.jobs.length == 1 ? '' : 's'} ${data.jobs.map((j) => '"$j"').join(', ')})';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      HintText('A best guess: rules with an alert for this ${kind.toLowerCase()}, or whose expression or labels mention its job$jobs, namespace or name.'),
      if (err != null) Padding(padding: const EdgeInsets.only(top: 6), child: HintText(err)),
      if (err == null && data.rules.isEmpty) const Padding(padding: EdgeInsets.only(top: 6), child: HintText('None found.')),
      for (final r in data.rules)
        Padding(
          padding: const EdgeInsets.only(top: 9),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
              if (r.rule.type == 'alerting')
                StatusBadge(_state(r.rule.state), dense: true, severity: ruleStateBadge(r.rule.state, r.rule.labels['severity']))
              else
                const StatusBadge('Record', dense: true, severity: Severity.neutral),
              Text(r.rule.name, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
              if (r.source != null)
                ResourceLink(
                  ObjectRef(group: 'monitoring.coreos.com', kind: 'PrometheusRule', namespace: r.source!.namespace, name: r.source!.name),
                  label: 'PrometheusRule ${r.source!.namespace}/${r.source!.name}',
                )
              else
                HintText('group ${r.group}'),
            ]),
            const SizedBox(height: 3),
            Wrap(spacing: 4, runSpacing: 3, children: [for (final why in r.reasons) Chipish(text: why)]),
            const SizedBox(height: 3),
            Text(r.rule.query, maxLines: 3, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11, color: theme.hintColor)),
          ]),
        ),
      if (data.rules.length < data.rulesTotal) Padding(padding: const EdgeInsets.only(top: 6), child: HintText('Showing ${data.rules.length} of ${data.rulesTotal}.')),
    ]);
  }

  static String _state(String? s) => switch (s) {
        'firing' => 'Firing',
        'pending' => 'Pending',
        _ => 'Inactive',
      };
}
