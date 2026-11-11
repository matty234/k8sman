import 'package:flutter/material.dart';

import '../../prometheus/prom_api.dart';
import '../../ui/widgets/atoms.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'common.dart';
import 'selected_by.dart';

/// Probe and ScrapeConfig: what they scrape, whether a Prometheus picks
/// them up, and their live targets.
class ScrapeSourcePanel extends ResourcePanel {
  const ScrapeSourcePanel();

  @override
  Set<String> get kinds => {'monitoring.coreos.com/Probe', 'monitoring.coreos.com/ScrapeConfig'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final isProbe = ctx.type.kind == 'Probe';
    final sd = [for (final k in spec.keys) if (k.endsWith('SDConfigs')) k.substring(0, k.length - 9)];
    final statics = isProbe
        ? (dig<List>(spec, ['targets', 'staticConfig', 'static']) ?? const []).length
        : [for (final s in asMapList(spec['staticConfigs'])) ...(s['targets'] as List? ?? const [])].length;
    return [
      CoreSection('overview', DetailSection(
        title: 'Overview',
        icon: isProbe ? Icons.radar : Icons.manage_search,
        child: KeyValueTable([
          if (isProbe) ('Module', '${spec['module'] ?? 'prober default'}'),
          if (isProbe && spec['prober'] != null) ('Prober', '${dig(spec, ['prober', 'url']) ?? ''}${dig(spec, ['prober', 'path']) ?? ''}'),
          if (statics > 0) ('Static targets', '$statics'),
          if (isProbe && dig(spec, ['targets', 'ingress']) != null) ('Targets', 'Ingresses'),
          if (sd.isNotEmpty) ('Discovery', sd.join(', ')),
          if (!isProbe && spec['metricsPath'] != null) ('Path', '${spec['metricsPath']}'),
          ('Interval', '${spec[isProbe ? 'interval' : 'scrapeInterval'] ?? 'Prometheus default'}'),
          if (spec['jobName'] != null) ('Job', '${spec['jobName']}'),
        ], keyWidth: 110),
      )),
      CoreSection('selected-by', DetailSection(
        title: 'Picked up by',
        icon: Icons.filter_alt_outlined,
        child: SelectedByView(key: ValueKey('sel-${ctx.uid}'), ctx: ctx),
      )),
      CoreSection('targets', _Targets(key: ValueKey('targets-${ctx.uid}'), ctx: ctx)),
    ];
  }
}

class _Targets extends StatefulWidget {
  final PanelContext ctx;
  const _Targets({super.key, required this.ctx});

  @override
  State<_Targets> createState() => _TargetsState();
}

class _TargetsState extends State<_Targets> {
  late final Future<TargetsData> _f = PromApi.of(widget.ctx.api).targets(kind: widget.ctx.type.kind, namespace: widget.ctx.namespace, name: widget.ctx.name);

  @override
  Widget build(BuildContext context) => FutureBuilder<TargetsData>(
        future: _f,
        builder: (context, snap) {
          final d = snap.data;
          return DetailSection(
            title: 'Scrape targets',
            icon: Icons.track_changes,
            trailing: d == null ? null : UpDownCounts(up: d.up, down: d.down, unknown: d.unknown),
            child: snap.hasError
                ? LiveStateMessage(snap.error!)
                : d == null
                    ? const HintText('Loading…')
                    : d.pools.isEmpty
                        ? const HintText('Prometheus has no targets from it.')
                        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            for (final p in d.pools)
                              for (final t in p.targets.take(50)) ScrapeTargetRow(t),
                          ]),
          );
        },
      );
}
