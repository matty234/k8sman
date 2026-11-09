/// PVC storage usage: Prometheus (`kubelet_volume_stats_*`) first, else the
/// kubelet Summary API. Kubelets only report mounted volumes, so an unbound
/// or idle claim has no usage, and says so.
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../prometheus/metric_history_chart.dart' show promQuote;
import '../prometheus/prom_api.dart';
import '../state/poller.dart';
import '../ui/theme.dart';
import '../ui/widgets/editorial.dart' show HairlineBar;
import '../util/k8s.dart';
import 'cache.dart';
import 'quantity.dart';
import '../state/namespace_scope.dart';

enum UsageSource { prometheus, kubelet }

/// One claim's filesystem usage (bytes, inodes).
class PvcUsage {
  final double? used;
  final double? capacity;
  final double? available;
  final double? inodes;
  final double? inodesUsed;
  final UsageSource source;

  /// Days until full at the recent growth rate (Prometheus only; null when
  /// not growing).
  final double? daysToFull;
  const PvcUsage({this.used, this.capacity, this.available, this.inodes, this.inodesUsed, required this.source, this.daysToFull});

  double? get frac => fraction(used, capacity);
  double? get inodeFrac => fraction(inodesUsed, inodes);
}

/// PVC thresholds: amber from 80% full, red from 90%.
Severity pvcSeverity(double? frac) => thresholdSeverity(frac, warn: 0.8);

String _sel(String? namespace, String? claim) =>
    [if (namespace != null) 'namespace="${promQuote(namespace)}"', if (claim != null) 'persistentvolumeclaim="${promQuote(claim)}"'].join(',');

/// Claim usage from Prometheus keyed `namespace/claim`, or null when there
/// is no Prometheus or it has no kubelet volume stats for the selection.
/// [detail] adds the days-to-full trend (meant for one claim).
Future<Map<String, PvcUsage>?> promPvcUsage(ApiClient api, {String? namespace, String? claim, bool detail = false}) async {
  final prom = PromApi.of(api);
  if (!await prom.hasPrometheus()) return null;
  final sel = _sel(namespace, claim);
  const by = 'max by (namespace, persistentvolumeclaim)';
  String q(String m) => '$by (kubelet_volume_stats_$m{$sel})';
  try {
    const metrics = ['used_bytes', 'capacity_bytes', 'available_bytes', 'inodes', 'inodes_used'];
    final results = await Future.wait([
      for (final m in metrics) prom.query(q(m)),
      // Growth over the last 6h, in bytes/s.
      if (detail) prom.query('$by (deriv(kubelet_volume_stats_used_bytes{$sel}[6h]))'),
    ]);
    final values = <String, Map<String, double>>{};
    for (final (i, r) in results.indexed) {
      final name = i < metrics.length ? metrics[i] : 'deriv';
      for (final s in r.series) {
        if (s.points.isEmpty) continue;
        (values['${s.metric['namespace']}/${s.metric['persistentvolumeclaim']}'] ??= {})[name] = s.points.last.$2;
      }
    }
    final out = <String, PvcUsage>{};
    for (final MapEntry(:key, value: v) in values.entries) {
      if (v['used_bytes'] == null) continue;
      final avail = v['available_bytes'];
      final growth = v['deriv'];
      out[key] = PvcUsage(
        used: v['used_bytes'],
        capacity: v['capacity_bytes'],
        available: avail,
        inodes: v['inodes'],
        inodesUsed: v['inodes_used'],
        source: UsageSource.prometheus,
        daysToFull: avail != null && growth != null && growth > 0 ? avail / (growth * 86400) : null,
      );
    }
    return out.isEmpty ? null : out;
  } catch (_) {
    return null;
  }
}

/// Every claim's usage in [namespace] (null = all), merged per claim by the
/// backend: Prometheus where it has the claim, kubelet stats for the rest.
class VolumesUsage {
  final Map<String, PvcUsage> byClaim;

  /// Prometheus had any kubelet volume stats.
  final bool prometheus;
  final bool kubelet;
  final String? kubeletMessage;
  const VolumesUsage({this.byClaim = const {}, this.prometheus = false, this.kubelet = false, this.kubeletMessage});

  static Future<VolumesUsage> load(ApiClient api, {String? namespace}) async {
    final j = await api.metrics('volumes', namespaceQuery(namespace));
    double? n(dynamic v) => (v as num?)?.toDouble();
    return VolumesUsage(
      byClaim: {
        for (final i in asMapList(j['items']))
          '${i['namespace']}/${i['claim']}': PvcUsage(
            used: n(i['usedBytes']),
            capacity: n(i['capacityBytes']),
            available: n(i['availableBytes']),
            inodes: n(i['inodes']),
            inodesUsed: n(i['inodesUsed']),
            source: i['source'] == 'prometheus' ? UsageSource.prometheus : UsageSource.kubelet,
          ),
      },
      prometheus: j['prometheus'] == true,
      kubelet: j['kubelet'] == 'available',
      kubeletMessage: j['kubeletMessage'] as String?,
    );
  }
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

/// What the panel knows about a claim's usage.
sealed class PvcUsageState {
  const PvcUsageState();
}

class PvcUsageLoading extends PvcUsageState {
  const PvcUsageLoading();
}

class PvcUsageKnown extends PvcUsageState {
  final PvcUsage usage;
  const PvcUsageKnown(this.usage);
}

/// No kubelet reports it: unbound, or not mounted by a running pod.
class PvcUsageNotMounted extends PvcUsageState {
  final bool bound;
  const PvcUsageNotMounted({this.bound = true});
}

/// Mounted, but neither source could say (no Prometheus, no permission...).
class PvcUsageUnavailable extends PvcUsageState {
  final String? reason;

  /// The kubelet answered but has no stats for this volume type.
  final bool noStats;
  const PvcUsageUnavailable([this.reason, this.noStats = false]);
}

/// A slim used/capacity bar: neutral below 80%, amber from 80%, red from 90%.
class PvcBar extends StatelessWidget {
  final double? frac;
  final double height;
  const PvcBar(this.frac, {super.key, this.height = 8});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final sev = pvcSeverity(frac);
    final fill = sev == Severity.neutral ? theme.colorScheme.onSurface.withValues(alpha: 0.42) : severityColor(context, sev);
    final f = (frac ?? 0).clamp(0.0, 1.0);
    return HairlineBar(
      frac: f == 0 ? 0 : f.clamp(0.01, 1.0),
      color: fill,
      height: height,
      radius: height / 2.5,
      track: theme.colorScheme.surfaceContainerHighest,
    );
  }
}

/// The usage block of the PVC panel for a resolved [state].
class PvcUsageView extends StatelessWidget {
  final PvcUsageState state;
  const PvcUsageView(this.state, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    Widget note(IconData icon, String text) => Row(children: [
      Icon(icon, size: 13, color: theme.hintColor),
      const SizedBox(width: 6),
      Expanded(child: Text(text, style: hint)),
    ]);
    switch (state) {
      case PvcUsageLoading():
        return SizedBox(height: 20, child: Align(alignment: Alignment.centerLeft, child: Text('Loading usage…', style: hint)));
      case PvcUsageNotMounted(:final bound):
        return note(
          Icons.link_off,
          bound
              ? 'Not mounted, usage unknown. Kubelets only report volumes mounted by a running pod.'
              : 'Not bound, usage unknown.',
        );
      case PvcUsageUnavailable(:final reason, :final noStats):
        return Tooltip(
          message: reason ?? '',
          child: note(
            Icons.query_stats,
            noStats
                ? 'Usage unknown: the kubelet reports no filesystem stats for this volume type (e.g. hostPath-backed local volumes).'
                : 'Usage unavailable: needs Prometheus with kubelet metrics, or access to kubelet stats (nodes/proxy).',
          ),
        );
      case PvcUsageKnown(:final usage):
        final u = usage;
        final frac = u.frac;
        final sev = pvcSeverity(frac);
        final mono = monoStyle(context, size: 11.5);
        final details = [
          if (u.available != null) '${formatBytes(u.available!)} free',
          if (u.inodes != null && u.inodesUsed != null && u.inodes! > 0)
            'inodes ${formatPercent(u.inodeFrac)} (${_count(u.inodesUsed!)} of ${_count(u.inodes!)})',
          if (u.daysToFull != null && u.daysToFull! <= 30) _fullIn(u.daysToFull!),
          u.source == UsageSource.prometheus ? 'via Prometheus' : 'via kubelet',
        ];
        final inodeSev = pvcSeverity(u.inodeFrac);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            Expanded(child: PvcBar(frac)),
            const SizedBox(width: 10),
            Text('${u.used == null ? '—' : formatBytes(u.used!)} of ${u.capacity == null ? '—' : formatBytes(u.capacity!)}', style: mono),
            SizedBox(
              width: 44,
              child: Text(
                formatPercent(frac),
                textAlign: TextAlign.right,
                style: mono.copyWith(fontWeight: FontWeight.w600, color: sev == Severity.neutral ? null : severityColor(context, sev)),
              ),
            ),
          ]),
          const SizedBox(height: 4),
          Text(details.join(' · '), style: hint),
          if (inodeSev != Severity.neutral && pvcSeverity(frac) == Severity.neutral)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text('Inodes are ${formatPercent(u.inodeFrac)} used: many small files can fill a volume before its bytes do.',
                  style: hint?.copyWith(color: severityColor(context, inodeSev))),
            ),
        ]);
    }
  }

  static String _count(double v) => v >= 1e6 ? '${(v / 1e6).toStringAsFixed(1)}M' : (v >= 1e4 ? '${(v / 1e3).round()}k' : '${v.round()}');

  static String _fullIn(double days) {
    if (days < 1) return 'full in ~${(days * 24).ceil()}h at the 6h trend';
    return 'full in ~${days.round()} day${days.round() == 1 ? '' : 's'} at the 6h trend';
  }
}

/// Loads and polls one claim's usage (Prometheus, then the kubelets of the
/// nodes running [mountNodes]). An empty [mountNodes] means no running pod
/// mounts the claim.
class PvcUsageSection extends StatefulWidget {
  final ApiClient api;
  final String namespace;
  final String claim;
  final bool bound;

  /// Loads the nodes of running pods that mount the claim.
  final Future<Set<String>> Function() mountNodes;
  const PvcUsageSection({super.key, required this.api, required this.namespace, required this.claim, required this.bound, required this.mountNodes});

  @override
  State<PvcUsageSection> createState() => _PvcUsageSectionState();
}

class _PvcUsageSectionState extends State<PvcUsageSection> with PollingState {
  PvcUsageState _state = const PvcUsageLoading();

  @override
  void initState() {
    super.initState();
    _load();
    poll(const Duration(seconds: 30), () async {
      await _load();
      return true;
    });
  }

  @override
  void didUpdateWidget(PvcUsageSection old) {
    super.didUpdateWidget(old);
    if (old.bound != widget.bound) _load();
  }

  Future<void> _load() async {
    final s = await resolvePvcUsage(widget.api, namespace: widget.namespace, claim: widget.claim, bound: widget.bound, mountNodes: widget.mountNodes);
    if (mounted) setState(() => _state = s);
  }

  @override
  Widget build(BuildContext context) => PvcUsageView(_state);
}

/// Prometheus first; else the kubelets of the mounting pods' nodes.
Future<PvcUsageState> resolvePvcUsage(
  ApiClient api, {
  required String namespace,
  required String claim,
  required bool bound,
  required Future<Set<String>> Function() mountNodes,
}) async {
  if (!bound) return const PvcUsageNotMounted(bound: false);
  final key = '$namespace/$claim';
  final prom = await promPvcUsage(api, namespace: namespace, claim: claim, detail: true);
  if (prom?[key] != null) return PvcUsageKnown(prom![key]!);
  Set<String> nodes;
  try {
    nodes = await mountNodes();
  } catch (e) {
    return PvcUsageUnavailable('$e');
  }
  if (nodes.isEmpty) return const PvcUsageNotMounted();
  final summary = await MetricsCache.of(api).summary(namespace, nodes: nodes);
  if (!summary.available) return PvcUsageUnavailable(summary.message);
  final v = summary.volumesByClaim[key];
  if (v == null) {
    // Mounted, but the kubelet reports no stats for this volume type
    // (e.g. hostPath-backed local volumes).
    return const PvcUsageUnavailable(null, true);
  }
  return PvcUsageKnown(PvcUsage(used: v.used, capacity: v.capacity, available: v.available, inodes: v.inodes, inodesUsed: v.inodesUsed, source: UsageSource.kubelet));
}
