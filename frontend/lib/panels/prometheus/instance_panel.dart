import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../prometheus/prom_api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'common.dart';
import '../../ui/widgets/atoms.dart';

/// Prometheus and Alertmanager custom resources: version, replicas,
/// retention, storage, selectors, alerting, conditions, and live status.
class PromInstancePanel extends ResourcePanel {
  const PromInstancePanel();

  @override
  Set<String> get kinds => {'monitoring.coreos.com/Prometheus', 'monitoring.coreos.com/Alertmanager'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final isProm = ctx.type.kind == 'Prometheus';
    final spec = ctx.spec;
    final conds = ctx.status['conditions'];
    return [
      DetailSection(
        title: 'Overview',
        icon: isProm ? Icons.query_stats : Icons.notifications_none,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KeyValueTable([
            ('Version', '${spec['version'] ?? 'operator default'}'),
            ('Replicas', _replicas(ctx)),
            if (spec['shards'] != null) ('Shards', '${spec['shards']}'),
            ('Retention', '${spec['retention'] ?? (isProm ? '24h (default)' : '120h (default)')}'),
            if (spec['retentionSize'] != null) ('Retention size', '${spec['retentionSize']}'),
            ('Storage', _storage(spec)),
            if (isProm && spec['scrapeInterval'] != null) ('Scrape interval', '${spec['scrapeInterval']}'),
            if (isProm && spec['evaluationInterval'] != null) ('Evaluation', 'every ${spec['evaluationInterval']}'),
            if (spec['externalUrl'] != null) ('External URL', '${spec['externalUrl']}'),
            if (spec['routePrefix'] != null) ('Route prefix', '${spec['routePrefix']}'),
            if (spec['serviceAccountName'] != null)
              ('Service account', ResourceLink(ObjectRef(kind: 'ServiceAccount', name: '${spec['serviceAccountName']}', namespace: ctx.namespace), label: '${spec['serviceAccountName']}')),
            ('Resources', _resources(spec)),
          ], keyWidth: 120),
          const SizedBox(height: 6),
          _LiveStatus(key: ValueKey(ctx.uid), ctx: ctx),
        ]),
      ),
      if (isProm)
        DetailSection(
          title: 'Selects',
          icon: Icons.filter_alt_outlined,
          child: KeyValueTable([
            ('Rules', _sel(spec, 'ruleSelector', 'ruleNamespaceSelector')),
            ('ServiceMonitors', _sel(spec, 'serviceMonitorSelector', 'serviceMonitorNamespaceSelector')),
            ('PodMonitors', _sel(spec, 'podMonitorSelector', 'podMonitorNamespaceSelector')),
            ('Probes', _sel(spec, 'probeSelector', 'probeNamespaceSelector')),
            if (spec.containsKey('scrapeConfigSelector')) ('ScrapeConfigs', _sel(spec, 'scrapeConfigSelector', 'scrapeConfigNamespaceSelector')),
          ], keyWidth: 120),
        )
      else
        DetailSection(
          title: 'Configuration',
          icon: Icons.tune,
          child: KeyValueTable([
            ('AlertmanagerConfigs', _sel(spec, 'alertmanagerConfigSelector', 'alertmanagerConfigNamespaceSelector')),
            if (spec['configSecret'] != null)
              ('Config secret', ResourceLink(ObjectRef(kind: 'Secret', name: '${spec['configSecret']}', namespace: ctx.namespace), label: '${spec['configSecret']}')),
          ], keyWidth: 140),
        ),
      if (isProm && asMapList(dig(spec, ['alerting', 'alertmanagers'])).isNotEmpty)
        DetailSection(
          title: 'Sends alerts to',
          icon: Icons.send_outlined,
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (final a in asMapList(dig(spec, ['alerting', 'alertmanagers'])))
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Wrap(spacing: 6, runSpacing: 2, children: [
                  ResourceLink(ObjectRef(kind: 'Service', name: '${a['name']}', namespace: '${a['namespace'] ?? ctx.namespace}'),
                      label: '${a['namespace'] ?? ctx.namespace}/${a['name']}'),
                  HintText('port ${a['port'] ?? '?'}${a['pathPrefix'] != null ? ' · ${a['pathPrefix']}' : ''}'),
                ]),
              ),
          ]),
        ),
      if (conds is List && conds.isNotEmpty) DetailSection(title: 'Conditions', icon: Icons.fact_check_outlined, child: ConditionsTable(conds)),
    ];
  }

  static Widget _replicas(PanelContext ctx) {
    final want = (ctx.spec['replicas'] as num?)?.toInt() ?? 1;
    final avail = (ctx.status['availableReplicas'] as num?)?.toInt() ?? 0;
    return StatusBadge('$avail/$want available', dense: true, severity: avail >= want ? Severity.ok : (avail == 0 ? Severity.error : Severity.warn));
  }

  static String _storage(Json spec) {
    final st = asMap(spec['storage']);
    final vct = asMap(st['volumeClaimTemplate']);
    if (vct.isNotEmpty) {
      final size = dig(vct, ['spec', 'resources', 'requests', 'storage']);
      final sc = dig(vct, ['spec', 'storageClassName']);
      return 'PVC ${size ?? ''}${sc != null ? ' ($sc)' : ''}'.trim();
    }
    if (st['emptyDir'] != null) return 'emptyDir${dig(st, ['emptyDir', 'sizeLimit']) != null ? ' (${dig(st, ['emptyDir', 'sizeLimit'])})' : ''}';
    return 'emptyDir (not persisted)';
  }

  static String _resources(Json spec) {
    final r = asMap(spec['resources']);
    final req = asMap(r['requests']), lim = asMap(r['limits']);
    final parts = [
      if (req.isNotEmpty) 'requests ${req.entries.map((e) => '${e.key} ${e.value}').join(', ')}',
      if (lim.isNotEmpty) 'limits ${lim.entries.map((e) => '${e.key} ${e.value}').join(', ')}',
    ];
    return parts.isEmpty ? 'none set' : parts.join(' · ');
  }

  static Widget _sel(Json spec, String sel, String nsSel) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SelectorView(spec[sel], emptyText: 'all', missingText: 'none'),
        if (spec.containsKey(sel) && spec[sel] != null)
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Row(children: [
              const HintText('in '),
              Flexible(child: SelectorView(spec[nsSel], emptyText: 'all namespaces', missingText: 'its own namespace')),
            ]),
          ),
      ]);
}

/// Reachability and running version from discovery, plus a link to Alerts.
class _LiveStatus extends StatefulWidget {
  final PanelContext ctx;
  const _LiveStatus({super.key, required this.ctx});

  @override
  State<_LiveStatus> createState() => _LiveStatusState();
}

class _LiveStatusState extends State<_LiveStatus> {
  late final Future<PromStatus> _status = PromApi.of(widget.ctx.api).status();

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final isProm = ctx.type.kind == 'Prometheus';
    return FutureBuilder<PromStatus>(
      future: _status,
      builder: (context, snap) {
        if (snap.hasError) return LiveStateMessage(snap.error!);
        final s = snap.data;
        if (s == null) return const HintText('Checking…');
        final id = '${ctx.namespace}/${ctx.name}';
        final inst = (isProm ? s.prometheus : s.alertmanager).where((i) => i.id == id).firstOrNull;
        if (inst == null) return const HintText('Not discovered by k8sman.');
        return Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          StatusBadge(inst.reachable ? 'Reachable' : 'Unreachable', dense: true, severity: inst.reachable ? Severity.ok : Severity.error),
          if (inst.reachable && inst.version.isNotEmpty) HintText('running ${inst.version}'),
          HintText('via ${inst.service}:${inst.port}'),
          if (inst.isDefault) const HintText('default'),
          if (!inst.reachable && inst.error != null) Text(inst.error!, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.error))),
          OpenAlertsButton(ctx.app),
        ]);
      },
    );
  }
}
