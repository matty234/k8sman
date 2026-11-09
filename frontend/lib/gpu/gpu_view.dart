/// The GPUs page (GpusModule, lib/modules): every NVIDIA GPU node with allocation,
/// live DCGM device stats, the pods holding GPUs, and problems worth acting
/// on (idle allocated GPUs, unhealthy devices, unmonitored nodes).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../metrics/quantity.dart';
import '../prometheus/prom_api.dart';
import '../state/poller.dart';
import '../ui/widgets/common.dart';
import '../ui/widgets/editorial.dart';
import '../util/k8s.dart';
import 'gpu_api.dart';
import 'gpu_table.dart';
import 'gpu_widgets.dart' show GpuPodLink;

class GpusView extends StatefulWidget {
  const GpusView({super.key});

  @override
  State<GpusView> createState() => _GpusViewState();
}

class _GpusViewState extends State<GpusView> with PollingState {
  GpuInventory? _inv;
  String? _error;
  DateTime? _updated;

  /// UUID → utilisation over the last hour (0..1), for sparklines.
  Map<String, List<double>> _spark = const {};

  GpuSort _sort = GpuSort.name;
  bool _ascending = true;

  /// Nodes the user expanded / collapsed; the rest follow [_openByDefault].
  final _toggled = <String, bool>{};
  static const _openByDefault = 8;

  ApiClient get _api => context.read<ApiClient>();

  @override
  void initState() {
    super.initState();
    _refresh();
    poll(const Duration(seconds: 15), () async {
      await _refresh();
      return _error == null;
    });
  }

  Future<void> _refresh({bool force = false}) async {
    try {
      final inv = await GpuApi.of(_api).inventory(refresh: force);
      if (!mounted) return;
      setState(() {
        _inv = inv;
        _error = null;
        _updated = DateTime.now();
      });
      _loadSparklines(inv);
    } catch (e) {
      if (mounted) setState(() => _error = e is ApiException ? e.message : '$e');
    }
  }

  /// One range query for every device's last hour; failures just leave
  /// the sparklines out.
  Future<void> _loadSparklines(GpuInventory inv) async {
    final uuids = {for (final n in inv.nodes) for (final d in n.devices) if (d.uuid != null) d.uuid!};
    if (!inv.live || uuids.isEmpty) return;
    try {
      final end = DateTime.now();
      final data = await PromApi.of(_api).queryRange(
        'max by (UUID) (DCGM_FI_DEV_GPU_UTIL{UUID=~"${uuids.join('|')}"}) / 100',
        start: end.subtract(const Duration(hours: 1)),
        end: end,
        step: const Duration(minutes: 1),
      );
      if (!mounted) return;
      setState(() => _spark = {for (final s in data.series) if (s.metric['UUID'] != null) s.metric['UUID']!: [for (final p in s.points) p.$2]});
    } catch (_) {}
  }

  void _sortBy(GpuSort s) => setState(() {
        if (_sort == s) {
          _ascending = !_ascending;
        } else {
          _sort = s;
          _ascending = s == GpuSort.name;
        }
      });

  bool _isOpen(GpuInventory inv, GpuNode n) => _toggled[n.name] ?? inv.nodes.length <= _openByDefault;

  Widget _table(GpuInventory inv) {
    final pending = inv.pods.where((p) => p.node == null && p.phase == 'Pending').toList();
    return LayoutBuilder(builder: (context, box) {
      final layout = GpuLayout.forWidth(box.maxWidth);
      // Flattened rows: nodes, plus their devices while expanded.
      final items = <Object>[];
      for (final n in sortGpuNodes(inv.nodes, _sort, _ascending)) {
        items.add(n);
        if (!_isOpen(inv, n)) continue;
        if (n.devices.isNotEmpty) {
          items.addAll(n.devices);
        } else if (n.count > 0) {
          items.add(GpuNoStats(n));
        }
      }
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _Summary(inv),
            if (inv.issues.isNotEmpty) EditorialSection(title: 'Needs attention', top: 16, collapsible: false, trailing: Text('${inv.issues.length}'), child: _Issues(inv.issues)),
          ]),
        ),
        GpuHeaderRow(layout: layout, sort: _sort, ascending: _ascending, onSort: _sortBy),
        Expanded(
          child: ListView.builder(
            padding: const EdgeInsets.only(bottom: 12),
            itemCount: items.length + (pending.isEmpty ? 0 : 1),
            itemBuilder: (context, i) {
              if (i == items.length) return Padding(padding: const EdgeInsets.fromLTRB(12, 16, 12, 0), child: _Pending(pending));
              final it = items[i];
              if (it is GpuNode) {
                return GpuNodeRow(it, key: ValueKey('node:${it.name}'), inv: inv, layout: layout, expanded: _isOpen(inv, it), onToggle: () => setState(() => _toggled[it.name] = !_isOpen(inv, it)));
              }
              if (it is GpuDevice) {
                return GpuDeviceRow(it, key: ValueKey('dev:${it.node}/${it.uuid ?? it.gpu}'), layout: layout, history: it.uuid == null ? null : _spark[it.uuid]);
              }
              return GpuNoStatsRow((it as GpuNoStats).node, key: ValueKey('nostats:${it.node.name}'));
            },
          ),
        ),
      ]);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final inv = _inv;
    final s = inv?.summary;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      PageHeader(
        title: 'GPUs',
        subtitle: s == null ? null : Text('${s.capacity} GPU${s.capacity == 1 ? '' : 's'} on ${s.nodes} node${s.nodes == 1 ? '' : 's'}'),
        actions: [
          if (_updated != null) AgeText(_updated!.toUtc().toIso8601String(), suffix: ' ago'),
          IconButton(tooltip: 'Refresh', iconSize: 18, icon: const Icon(Icons.refresh), onPressed: () => _refresh(force: true)),
        ],
      ),
      const Divider(),
      if (_error != null) Padding(padding: const EdgeInsets.fromLTRB(16, 8, 16, 0), child: InlineMessage(_error!, isError: true)),
      Expanded(
        child: inv == null
            ? (_error == null ? const Center(child: CircularProgressIndicator()) : const SizedBox.shrink())
            : !inv.hasGpus
                ? Center(child: Text('No nodes with NVIDIA GPUs', style: TextStyle(color: theme.hintColor)))
                : _table(inv),
      ),
    ]);
  }
}

/// Allocation and health at a glance: large figures divided by hairlines,
/// coloured only when something needs a look, with where the live stats
/// come from under them.
class _Summary extends StatelessWidget {
  final GpuInventory inv;
  const _Summary(this.inv);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = inv.summary;
    final note = switch (inv.monitoring) {
      GpuMonitoring.dcgm => 'Live stats from DCGM via ${inv.prometheus ?? 'Prometheus'}${inv.attribution || inv.summary.allocated == 0 ? '' : ' · devices not attributed to pods'}',
      GpuMonitoring.noExporter => 'No DCGM exporter metrics in Prometheus: allocation only',
      GpuMonitoring.noPrometheus => 'No Prometheus: allocation only',
      GpuMonitoring.error => 'GPU metrics unavailable: ${inv.errors['prometheus'] ?? 'query failed'}',
      GpuMonitoring.skipped => '',
    };
    final util = s.avgUtil;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      StatStrip(minCell: 116, maxCell: 180, items: [
        StatItem('allocated', '${s.allocated}', of: '/ ${s.allocatable}'),
        if (util != null) StatItem('utilisation now', formatPercent(util), tooltip: 'Average across monitored GPUs'),
        if (s.idle > 0) StatItem('idle allocated', '${s.idle}', tone: Severity.warn),
        if (s.unhealthy > 0) StatItem('unhealthy', '${s.unhealthy}', tone: inv.issues.any((i) => i.severity == 'critical') ? Severity.error : Severity.warn),
        if (s.unmonitored > 0 && inv.monitoring == GpuMonitoring.dcgm) StatItem('unmonitored', '${s.unmonitored}', tone: Severity.warn, tooltip: 'Nodes with GPUs but no DCGM exporter metrics'),
        if (s.pendingPods > 0) StatItem(s.pendingPods == 1 ? 'pod waiting' : 'pods waiting', '${s.pendingPods}', tone: Severity.warn),
      ]),
      if (note.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Text(note, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ),
    ]);
  }
}

/// What needs a look, one line each behind a small severity bar.
class _Issues extends StatelessWidget {
  final List<GpuIssue> issues;
  const _Issues(this.issues);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final i in issues)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 2), child: SeverityBar(severity: i.level)),
            const SizedBox(width: 10),
            Expanded(child: Text(i.message, style: theme.textTheme.bodySmall?.copyWith(fontSize: 12.5))),
          ]),
        ),
    ]);
  }
}

class _Pending extends StatelessWidget {
  final List<GpuPod> pods;
  const _Pending(this.pods);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DetailSection(
      title: 'Waiting for GPUs',
      icon: Icons.schedule,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final p in pods)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              SizedBox(width: 260, child: GpuPodLink(namespace: p.namespace, name: p.name)),
              SizedBox(width: 80, child: Text(p.request, style: theme.textTheme.bodySmall)),
              Expanded(child: Text(p.unschedulable ?? 'Pending', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
            ]),
          ),
      ]),
    );
  }
}
