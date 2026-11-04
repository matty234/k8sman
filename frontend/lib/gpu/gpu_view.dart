/// The GPUs page (MainView.gpus): every NVIDIA GPU node with allocation,
/// live DCGM device stats, the pods holding GPUs, and problems worth acting
/// on (idle allocated GPUs, unhealthy devices, unmonitored nodes).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../metrics/quantity.dart';
import '../panels/cluster/widgets.dart';
import '../prometheus/prom_api.dart';
import '../state/app_state.dart';
import '../state/poller.dart';
import '../state/startup_gate.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'gpu_api.dart';
import 'gpu_widgets.dart';

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
                : LayoutBuilder(builder: (context, box) {
                    final cols = (box.maxWidth / 460).floor().clamp(1, 4);
                    final w = (box.maxWidth - 24 - (cols - 1) * 12) / cols;
                    final pending = inv.pods.where((p) => p.node == null && p.phase == 'Pending').toList();
                    return SingleChildScrollView(
                      padding: const EdgeInsets.all(12),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        _Summary(inv),
                        if (inv.issues.isNotEmpty) ...[const SizedBox(height: 10), _Issues(inv.issues)],
                        const SizedBox(height: 12),
                        Wrap(spacing: 12, runSpacing: 12, children: [
                          for (final n in inv.nodes) SizedBox(width: w, child: _NodeCard(n, inv: inv, spark: _spark)),
                        ]),
                        if (pending.isNotEmpty) ...[const SizedBox(height: 16), _Pending(pending)],
                      ]),
                    );
                  }),
      ),
    ]);
  }
}

class _Summary extends StatelessWidget {
  final GpuInventory inv;
  const _Summary(this.inv);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = inv.summary;
    final small = theme.textTheme.bodySmall;
    final note = switch (inv.monitoring) {
      GpuMonitoring.dcgm => 'Live stats from DCGM via ${inv.prometheus ?? 'Prometheus'}${inv.attribution || inv.summary.allocated == 0 ? '' : ' · devices not attributed to pods'}',
      GpuMonitoring.noExporter => 'No DCGM exporter metrics in Prometheus: allocation only',
      GpuMonitoring.noPrometheus => 'No Prometheus: allocation only',
      GpuMonitoring.error => 'GPU metrics unavailable: ${inv.errors['prometheus'] ?? 'query failed'}',
      GpuMonitoring.skipped => '',
    };
    return Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text(
        [
          '${s.allocated} of ${s.allocatable} allocated',
          if (s.avgUtil != null) '${formatPercent(s.avgUtil)} average utilisation now',
        ].join(' · '),
        style: small,
      ),
      if (s.idle > 0) StatusBadge('${s.idle} idle allocated', severity: Severity.warn, dense: true),
      if (s.unhealthy > 0)
        StatusBadge('${s.unhealthy} unhealthy', severity: inv.issues.any((i) => i.severity == 'critical') ? Severity.error : Severity.warn, dense: true),
      if (s.unmonitored > 0 && inv.monitoring == GpuMonitoring.dcgm) StatusBadge('${s.unmonitored} node${s.unmonitored == 1 ? '' : 's'} unmonitored', severity: Severity.warn, dense: true),
      if (s.pendingPods > 0) StatusBadge('${s.pendingPods} pod${s.pendingPods == 1 ? '' : 's'} waiting', severity: Severity.warn, dense: true),
      if (note.isNotEmpty) Text(note, style: small?.copyWith(color: theme.hintColor)),
    ]);
  }
}

class _Issues extends StatelessWidget {
  final List<GpuIssue> issues;
  const _Issues(this.issues);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final i in issues)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(
              i.level == Severity.error ? Icons.error_outline : (i.level == Severity.warn ? Icons.warning_amber : Icons.info_outline),
              size: 15,
              color: severityColor(context, i.level),
            ),
            const SizedBox(width: 6),
            Expanded(child: Text(i.message, style: theme.textTheme.bodySmall)),
          ]),
        ),
    ]);
  }
}

class _NodeCard extends StatelessWidget {
  final GpuNode n;
  final GpuInventory inv;
  final Map<String, List<double>> spark;
  const _NodeCard(this.n, {required this.inv, required this.spark});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final app = context.watch<AppState>();
    final type = app.typeFor('', 'Node');
    final selected = app.detail?.type == type && app.detail?.name == n.name;
    final problem = !n.ready || n.devices.any((d) => d.health.isNotEmpty);
    final border = problem
        ? severityColor(context, Severity.error).withValues(alpha: 0.6)
        : selected
            ? theme.colorScheme.primary
            : theme.colorScheme.outlineVariant.withValues(alpha: 0.5);
    final info = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: border)),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: type == null ? null : () => app.openDetail(DetailTarget(type: type, name: n.name)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Icon(Icons.memory, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(child: Text(n.name, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600))),
              if (!n.ready) const StatusBadge('NotReady', dense: true),
              if (n.unschedulable) ...[const SizedBox(width: 4), const StatusBadge('Cordoned', severity: Severity.warn, dense: true)],
              if (!n.monitored && inv.monitoring == GpuMonitoring.dcgm) ...[
                const SizedBox(width: 4),
                const Tooltip(
                  message: 'No DCGM exporter metrics map to this node, so there are no live GPU stats',
                  child: StatusBadge('No exporter', severity: Severity.warn, dense: true),
                ),
              ],
            ]),
            const SizedBox(height: 2),
            Text(gpuNodeLine(n), overflow: TextOverflow.ellipsis, style: info),
            const SizedBox(height: 6),
            UsageBar(
              label: 'Allocated',
              labelWidth: 84,
              used: n.allocated.toDouble(),
              total: n.allocatable.toDouble(),
              usedText: '${n.allocated}',
              totalText: '${n.allocatable}${n.capacity > n.allocatable ? ' (of ${n.capacity})' : ''}',
            ),
            for (final r in n.resources.where((r) => r.name != 'nvidia.com/gpu' && r.capacity > 0))
              UsageBar(
                label: r.name.replaceFirst('nvidia.com/', ''),
                labelWidth: 84,
                used: r.allocated.toDouble(),
                total: r.allocatable.toDouble(),
                usedText: '${r.allocated}',
                totalText: '${r.allocatable}',
              ),
            if (n.idleAllocated > 0)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(children: [
                  Icon(Icons.hourglass_empty, size: 14, color: severityColor(context, Severity.warn)),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${n.idleAllocated} allocated GPU${n.idleAllocated == 1 ? '' : 's'} idle for the last hour',
                      style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.warn)),
                    ),
                  ),
                ]),
              ),
            if (n.devices.isNotEmpty) ...[
              const SizedBox(height: 4),
              const Divider(height: 8),
              for (final d in n.devices) GpuDeviceTile(d, history: d.uuid == null ? null : spark[d.uuid]),
            ] else if (inv.monitoring != GpuMonitoring.skipped) ...[
              const SizedBox(height: 6),
              Text(
                n.count > 0 ? '${n.count} × ${n.productName} · no live stats' : 'No live stats',
                style: info,
              ),
            ],
            const Divider(height: 14),
            if (n.pods.isEmpty)
              Text('No pods hold GPUs here', style: info)
            else
              Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Text('Held by', style: info),
                for (final p in n.pods) _PodChip(p, pod: inv.pod(p.namespace, p.name)),
              ]),
          ]),
        ),
      ),
    );
  }
}

class _PodChip extends StatelessWidget {
  final GpuPodRef ref;
  final GpuPod? pod;
  const _PodChip(this.ref, {this.pod});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = pod;
    // The name may wrap: the Wrap gives each chip at most the card's width,
    // and long pod names would otherwise run past its edge.
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: GpuPodLink(namespace: ref.namespace, name: ref.name)),
      const SizedBox(width: 4),
      Text(
        [
          ref.gpus == 1 ? '1 GPU' : '${ref.gpus} GPUs',
          if (p?.util != null) '${formatPercent(p!.util)} busy',
        ].join(' · '),
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
      ),
      if (p?.idle == true) ...[const SizedBox(width: 4), const StatusBadge('Idle', severity: Severity.warn, dense: true)],
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

/// Shows [child] (the nav's GPUs item) only when the current cluster has
/// NVIDIA GPU nodes, or while the GPUs page is open.
class GpuNavGate extends StatelessWidget {
  final Widget child;
  const GpuNavGate({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    if (app.view == MainView.gpus) return child;
    final ApiClient api;
    try {
      api = context.read<ApiClient>();
    } catch (_) {
      return const SizedBox.shrink(); // no backend in this tree (tests)
    }
    return FutureBuilder<bool>(
      key: ValueKey(app.currentContext),
      future: _check(api, app.currentContext),
      builder: (context, snap) => snap.data == true ? child : const SizedBox.shrink(),
    );
  }

  static final Map<(ApiClient, String), Future<bool>> _checks = {};

  /// Asked once the first table has painted (see StartupGate), so the
  /// check doesn't compete with startup.
  static Future<bool> _check(ApiClient api, String contextName) =>
      _checks[(api, contextName)] ??= StartupGate.ready.then((_) => GpuApi.of(api).hasGpus(contextName));
}
