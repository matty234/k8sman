import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../prometheus/prom_api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'common.dart';
import 'selected_by.dart';
import '../../ui/widgets/atoms.dart';

/// ServiceMonitor / PodMonitor: what it selects (linked), its endpoints,
/// and live scrape-target health from Prometheus.
class MonitorPanel extends ResourcePanel {
  const MonitorPanel();

  @override
  Set<String> get kinds => {'monitoring.coreos.com/ServiceMonitor', 'monitoring.coreos.com/PodMonitor'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final isPod = ctx.type.kind == 'PodMonitor';
    final endpoints = asMapList(ctx.spec[isPod ? 'podMetricsEndpoints' : 'endpoints']);
    return [
      CoreSection('selects', DetailSection(
        title: 'Selects',
        icon: Icons.filter_alt_outlined,
        child: _Selects(key: ValueKey('sel-${ctx.uid}'), ctx: ctx, isPod: isPod),
      )),
      CoreSection('selected-by', DetailSection(
        title: 'Picked up by',
        icon: Icons.manage_search,
        child: SelectedByView(key: ValueKey('selby-${ctx.uid}'), ctx: ctx),
      )),
      CoreSection('targets', _LiveTargets(key: ValueKey('live-${ctx.uid}'), ctx: ctx, endpoints: endpoints, isPod: isPod)),
    ];
  }
}

/// Namespaces a monitor looks in: `any`, `matchNames`, or its own.
List<String?> monitorNamespaces(PanelContext ctx) {
  final ns = asMap(ctx.spec['namespaceSelector']);
  if (ns['any'] == true) return [null];
  final names = (ns['matchNames'] as List?)?.map((e) => '$e').toList() ?? const [];
  return names.isEmpty ? [ctx.namespace] : names;
}

class _Selects extends StatefulWidget {
  final PanelContext ctx;
  final bool isPod;
  const _Selects({super.key, required this.ctx, required this.isPod});

  @override
  State<_Selects> createState() => _SelectsState();
}

class _SelectsState extends State<_Selects> {
  late final Future<List<Json>> _matches;

  @override
  void initState() {
    super.initState();
    final sel = selectorToString(widget.ctx.spec['selector']);
    final ref = ResourceRef(resource: widget.isPod ? 'pods' : 'services');
    _matches = Future.wait([
      for (final ns in monitorNamespaces(widget.ctx)) widget.ctx.api.items(ref, namespace: ns, labelSelector: sel.isEmpty ? null : sel),
    ]).then((l) => [for (final x in l) ...x]);
  }

  @override
  Widget build(BuildContext context) {
    final ctx = widget.ctx;
    final nsSel = asMap(ctx.spec['namespaceSelector']);
    final namespaces = nsSel['any'] == true
        ? 'any namespace'
        : ((nsSel['matchNames'] as List?)?.isNotEmpty ?? false)
            ? (nsSel['matchNames'] as List).join(', ')
            : '${ctx.namespace} (own namespace)';
    final kind = widget.isPod ? 'Pod' : 'Service';
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      KeyValueTable([
        ('${kind}s with', SelectorView(ctx.spec['selector'], emptyText: 'any labels')),
        ('In', namespaces),
        if (ctx.spec['jobLabel'] != null) ('Job label', '${ctx.spec['jobLabel']}'),
      ], keyWidth: 100),
      const SizedBox(height: 6),
      AsyncSection<List<Json>>(
        future: _matches,
        builder: (context, items) {
          if (items.isEmpty) return HintText('No ${kind.toLowerCase()}s match, so nothing is scraped.');
          final shown = items.take(30).toList();
          return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            HintText('${items.length} matching ${kind.toLowerCase()}${items.length == 1 ? '' : 's'}'),
            const SizedBox(height: 4),
            Wrap(spacing: 12, runSpacing: 4, children: [
              for (final o in shown)
                ResourceLink(
                  ObjectRef(kind: kind, name: '${dig(o, ['metadata', 'name'])}', namespace: dig<String>(o, ['metadata', 'namespace'])),
                  label: dig<String>(o, ['metadata', 'namespace']) == ctx.namespace
                      ? '${dig(o, ['metadata', 'name'])}'
                      : '${dig(o, ['metadata', 'namespace'])}/${dig(o, ['metadata', 'name'])}',
                ),
              if (items.length > shown.length) HintText('+${items.length - shown.length} more'),
            ]),
          ]);
        },
      ),
    ]);
  }
}

class _LiveTargets extends StatefulWidget {
  final PanelContext ctx;
  final List<Json> endpoints;
  final bool isPod;
  const _LiveTargets({super.key, required this.ctx, required this.endpoints, required this.isPod});

  @override
  State<_LiveTargets> createState() => _LiveTargetsState();
}

class _LiveTargetsState extends State<_LiveTargets> {
  late Future<TargetsData> _live;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    _live = PromApi.of(widget.ctx.api).targets(kind: widget.ctx.type.kind, namespace: widget.ctx.namespace, name: widget.ctx.name);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<TargetsData>(
      future: _live,
      builder: (context, snap) {
        final live = snap.data;
        final loading = snap.connectionState != ConnectionState.done;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DetailSection(
            title: 'Endpoints',
            icon: Icons.settings_ethernet,
            trailing: HintText('${widget.endpoints.length}'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (widget.endpoints.isEmpty) const HintText('No endpoints'),
              for (final (i, e) in widget.endpoints.indexed) ...[
                if (i > 0) Divider(height: 1, color: AppColors.of(context).separator),
                _EndpointRow(index: i, endpoint: e, pool: live?.pools.where((p) => p.endpoint == i).firstOrNull, loaded: live != null),
              ],
            ]),
          ),
          DetailSection(
            title: 'Scrape targets',
            icon: Icons.track_changes,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (live != null) UpDownCounts(up: live.up, down: live.down, unknown: live.unknown),
              IconButton(
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
                iconSize: 15,
                onPressed: loading ? null : () => setState(_fetch),
                icon: const Icon(Icons.refresh),
              ),
            ]),
            child: snap.hasError
                ? LiveStateMessage(snap.error!)
                : live == null
                    ? const HintText('Loading…')
                    : live.pools.isEmpty
                        ? HintText('${live.prometheus?.name ?? 'Prometheus'} has no targets from this ${widget.ctx.type.kind} '
                            '(check its ${widget.isPod ? 'podMonitorSelector' : 'serviceMonitorSelector'} and namespace selector).')
                        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            for (final p in live.pools)
                              for (final t in p.targets.take(50)) ScrapeTargetRow(t),
                            if (live.pools.any((p) => p.targets.length > 50)) HintText('Showing the first 50 targets per endpoint.', style: theme.textTheme.bodySmall),
                          ]),
          ),
        ]);
      },
    );
  }
}

class _EndpointRow extends StatelessWidget {
  final int index;
  final Json endpoint;
  final TargetPool? pool;
  final bool loaded;
  const _EndpointRow({required this.index, required this.endpoint, required this.pool, required this.loaded});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final e = endpoint;
    final port = e['port'] ?? e['targetPort'] ?? e['portNumber'] ?? '?';
    final path = e['path'] ?? '/metrics';
    final scheme = e['scheme'] ?? 'http';
    final p = pool;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('$scheme · $port$path', style: monoStyle(context, size: 12)),
            const SizedBox(height: 2),
            Wrap(spacing: 10, runSpacing: 2, children: [
              HintText('every ${e['interval'] ?? 'default interval'}'),
              if (e['scrapeTimeout'] != null) HintText('timeout ${e['scrapeTimeout']}'),
              if (e['honorLabels'] == true) const HintText('honorLabels'),
              if (asMapList(e['relabelings']).isNotEmpty) HintText('${asMapList(e['relabelings']).length} relabelings'),
              if (asMapList(e['metricRelabelings']).isNotEmpty) HintText('${asMapList(e['metricRelabelings']).length} metric relabelings'),
            ]),
          ]),
        ),
        const SizedBox(width: 8),
        if (p != null)
          UpDownCounts(up: p.up, down: p.down, unknown: p.unknown)
        else if (loaded)
          Text('no targets', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
      ]),
    );
  }
}
