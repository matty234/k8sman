import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../panels/cluster/logic.dart' show podResources;
import '../ui/theme.dart';
import '../util/k8s.dart';
import 'cache.dart';
import 'metrics_api.dart';
import 'quantity.dart';
import 'widgets.dart';
import '../state/poller.dart';

/// Loads one pod's usage (shared per namespace, refreshed every 15s).
class PodUsageLoader extends StatefulWidget {
  final String namespace;
  final String name;
  final Widget Function(BuildContext context, PodUsage? usage, Object? error, bool loading) builder;
  const PodUsageLoader({super.key, required this.namespace, required this.name, required this.builder});

  @override
  State<PodUsageLoader> createState() => _PodUsageLoaderState();
}

class _PodUsageLoaderState extends State<PodUsageLoader> with PollingState {
  PodUsage? _usage;
  Object? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
    poll(const Duration(seconds: 15), () async {
      await _load();
      return _error == null;
    });
  }

  @override
  void didUpdateWidget(PodUsageLoader old) {
    super.didUpdateWidget(old);
    if (old.name != widget.name || old.namespace != widget.namespace) _load();
  }

  Future<void> _load() async {
    try {
      final u = await MetricsCache.of(context.read<ApiClient>()).pod(widget.namespace, widget.name);
      if (!mounted) return;
      setState(() {
        _usage = u;
        _error = null;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _usage = null;
        _error = e;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _usage, _error, _loading);
}

/// Requests/limits of one container spec, in millicores and bytes.
({double? cpuReq, double? cpuLim, double? memReq, double? memLim}) containerResources(Json spec) {
  final r = asMap(spec['resources']);
  final req = asMap(r['requests']), lim = asMap(r['limits']);
  return (cpuReq: parseCpuMillis(req['cpu']), cpuLim: parseCpuMillis(lim['cpu']), memReq: parseBytes(req['memory']), memLim: parseBytes(lim['memory']));
}

/// The value text for usage against a request/limit: "8m / 200m lim".
String usageAgainst(String used, {String? limit, String? request}) {
  if (limit != null) return '$used / $limit lim';
  if (request != null) return '$used / $request req';
  return used;
}

/// Per-container usage for a container card: CPU and memory meters against
/// the container's request (outlined) and limit (tick). Percentages are of
/// the limit when set (throttling / OOM risk), else of the request.
class ContainerUsageLine extends StatelessWidget {
  final Json pod;
  final String container;
  final Json spec;
  const ContainerUsageLine({super.key, required this.pod, required this.container, required this.spec});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ns = dig<String>(pod, ['metadata', 'namespace']) ?? '';
    final name = dig<String>(pod, ['metadata', 'name']) ?? '';
    return PodUsageLoader(
      namespace: ns,
      name: name,
      builder: (context, usage, error, loading) {
        final u = usage?.containers[container];
        if (u == null) {
          final why = error != null ? '$error' : (loading ? 'loading' : 'no sample yet');
          return Tooltip(
            message: why,
            child: Text(loading ? '' : '—', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          );
        }
        final r = containerResources(spec);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ResourceMeter(
              compact: true,
              label: 'CPU',
              labelWidth: 50,
              valueWidth: 150,
              used: u.cpuMillis,
              requested: r.cpuReq,
              limit: r.cpuLim,
              percentBase: r.cpuLim ?? r.cpuReq,
              percentOf: r.cpuLim != null ? 'limit' : 'request',
              valueText: usageAgainst(
                formatCpuUsage(u.cpuMillis),
                limit: r.cpuLim == null ? null : formatCpu(r.cpuLim),
                request: r.cpuReq == null ? null : formatCpu(r.cpuReq),
              ),
              format: (v) => formatCpuUsage(v),
            ),
            ResourceMeter(
              compact: true,
              label: 'Memory',
              labelWidth: 50,
              valueWidth: 150,
              used: u.memoryBytes,
              requested: r.memReq,
              limit: r.memLim,
              percentBase: r.memLim ?? r.memReq,
              percentOf: r.memLim != null ? 'limit' : 'request',
              valueText: usageAgainst(
                formatBytes(u.memoryBytes),
                limit: r.memLim == null ? null : formatBytes(r.memLim),
                request: r.memReq == null ? null : formatBytes(r.memReq),
              ),
              format: formatBytes,
            ),
          ],
        );
      },
    );
  }
}

/// Pod-total usage for the Status summary: "CPU 8m (15% of request) · Memory 7 MiB (17%)".
class PodUsageSummary extends StatelessWidget {
  final Json pod;
  const PodUsageSummary({super.key, required this.pod});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    final ns = dig<String>(pod, ['metadata', 'namespace']) ?? '';
    final name = dig<String>(pod, ['metadata', 'name']) ?? '';
    return PodUsageLoader(
      namespace: ns,
      name: name,
      builder: (context, usage, error, loading) {
        if (usage == null) {
          if (loading) return Text('…', style: hint);
          if (error != null) return MetricsUnavailableNote(error);
          final phase = dig<String>(pod, ['status', 'phase']);
          return Text(phase == 'Running' ? 'No sample yet' : 'Not running', style: hint);
        }
        final res = podResources(pod);
        InlineSpan part(String label, String value, double? frac, String base) => TextSpan(
          children: [
            TextSpan(text: '$label ', style: hint),
            TextSpan(
              text: value,
              style: monoStyle(context, size: 11.5).copyWith(fontWeight: FontWeight.w600),
            ),
            if (frac != null)
              TextSpan(
                text: ' (${formatPercent(frac)} of $base)',
                style: TextStyle(color: percentColor(context, frac) ?? theme.hintColor),
              ),
          ],
        );
        // Percentages are of limits when every container has one, else of requests.
        final containers = asMapList(dig(pod, ['spec', 'containers']));
        bool limited(String r) => containers.isNotEmpty && containers.every((c) => dig(c, ['resources', 'limits', r]) != null);
        final cpuLim = limited('cpu'), memLim = limited('memory');
        return Wrap(
          spacing: 6,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  part(
                    'CPU',
                    formatCpuUsage(usage.usage.cpuMillis),
                    fraction(usage.usage.cpuMillis, cpuLim ? res.cpuLimit : res.cpuRequest),
                    cpuLim ? 'limit' : 'request',
                  ),
                  TextSpan(text: '  ·  ', style: hint),
                  part(
                    'Memory',
                    formatBytes(usage.usage.memoryBytes),
                    fraction(usage.usage.memoryBytes, memLim ? res.memLimit : res.memRequest),
                    memLim ? 'limit' : 'request',
                  ),
                ],
              ),
              style: small,
            ),
            if (usage.timestamp != null) Text('sampled ${formatAge(parseTime(usage.timestamp))} ago', style: hint?.copyWith(fontSize: 11)),
          ],
        );
      },
    );
  }
}
