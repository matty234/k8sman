import 'package:flutter/material.dart';

import '../../ui/widgets/node_os_icon.dart';
import '../../api/models.dart';
import '../../gpu/gpu_sections.dart';
import '../../metrics/metrics_api.dart' show Usage;
import '../../metrics/quantity.dart' show formatPercent;
import '../../prometheus/metric_history_chart.dart';
import '../../metrics/network_usage.dart';
import '../../metrics/node_usage.dart';
import '../../ui/nodes/nodes_view.dart' show podHasProblem;
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../dra/dra_sections.dart';
import '../network/inspector_kit.dart';
import '../panel.dart';
import 'logic.dart';
import 'widgets.dart';

const _pressureTypes = ['MemoryPressure', 'DiskPressure', 'PIDPressure', 'NetworkUnavailable'];

class NodePanel extends ResourcePanel {
  const NodePanel();

  @override
  Set<String> get kinds => {'/Node'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final status = ctx.status;
    final labels = asMap(ctx.metadata['labels']);
    final conds = asMapList(status['conditions']);
    final bad = [for (final c in conds) if (c['type'] == 'Ready' ? c['status'] != 'True' : c['status'] != 'False') '${c['type']}'];
    final taints = asMapList(ctx.spec['taints']);
    final addrs = asMapList(status['addresses']);
    final info = asMap(status['nodeInfo']);
    final images = asMapList(status['images']);
    final cap = asMap(status['capacity']);
    final alloc = asMap(status['allocatable']);
    return [
      // Is this node OK? Status, pods and usage (one fetch of its pods).
      _NodeView(key: ValueKey(ctx.uid), ctx: ctx),
      gpuNodeSection(ctx),
      draNodeSection(ctx),
      // Reference detail, collapsed behind a one-line summary.
      PodSection(
        id: 'node-capacity',
        title: 'Capacity & allocatable',
        initiallyExpanded: false,
        trailing: SectionSummary([
          if (alloc['cpu'] != null) '${formatCpu(parseCpuMillis(alloc['cpu']))} cpu',
          if (alloc['memory'] != null) formatBytes(parseBytes(alloc['memory'])),
          if (alloc['pods'] != null) '${alloc['pods']} pods',
          if (cap.isEmpty && alloc.isEmpty) 'not reported',
        ].join(' · ')),
        child: _CapacityTable(status),
      ),
      PodSection(
        id: 'node-taints',
        title: 'Taints',
        initiallyExpanded: false,
        trailing: SectionSummary(taints.isEmpty ? 'none' : taints.map((t) => '${t['key']}'.split('/').last).join(' · ')),
        child: taints.isEmpty
            ? const Padding(padding: EdgeInsets.only(left: 4), child: Text('No taints: any pod can be scheduled here'))
            : Wrap(spacing: 4, runSpacing: 4, children: [for (final t in taints) _TaintChip(t)]),
      ),
      PodSection(
        id: 'node-conditions',
        title: 'Conditions',
        initiallyExpanded: false,
        trailing: SectionSummary(
          conds.isEmpty ? 'none' : (bad.isEmpty ? 'all OK' : bad.join(', ')),
          color: bad.isEmpty ? null : severityColor(context, Severity.error),
        ),
        child: ConditionsTable(status['conditions'] as List?),
      ),
      PodSection(
        id: 'node-system',
        title: 'System info',
        initiallyExpanded: false,
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          NodeOsIcon(ctx.object, size: 13),
          const SizedBox(width: 6),
          Flexible(
            child: SectionSummary([
              ?info['osImage'] as String?,
              if (info['containerRuntimeVersion'] != null) '${info['containerRuntimeVersion']}'.replaceFirst('://', ' '),
            ].join(' · ')),
          ),
        ]),
        child: _SystemInfo(ctx, labels),
      ),
      PodSection(
        id: 'node-addresses',
        title: 'Addresses',
        initiallyExpanded: false,
        trailing: SectionSummary(addrs.isEmpty ? 'none' : addrs.map((a) => '${a['address']}').join(' · ')),
        child: _Addresses(ctx),
      ),
      PodSection(
        id: 'node-images',
        title: 'Images',
        initiallyExpanded: false,
        trailing: SectionSummary(() {
          final total = images.fold<double>(0, (s, i) => s + ((i['sizeBytes'] as num?)?.toDouble() ?? 0));
          return images.isEmpty ? 'none' : '${images.length} · ${formatBytes(total)}';
        }()),
        child: _Images(images),
      ),
    ];
  }
}

/// The node's status header (with live usage when metrics answer), its
/// pods as compact rows, metrics history, live network and the allocated
/// requests and limits, from one fetch of the pods on the node.
class _NodeView extends StatefulWidget {
  final PanelContext ctx;
  const _NodeView({super.key, required this.ctx});

  @override
  State<_NodeView> createState() => _NodeViewState();
}

class _NodeViewState extends State<_NodeView> {
  late Future<List<Json>> _future = _fetch();

  PanelContext get ctx => widget.ctx;

  @override
  void didUpdateWidget(covariant _NodeView old) {
    super.didUpdateWidget(old);
    if (old.ctx.name != ctx.name) _future = _fetch();
  }

  Future<List<Json>> _fetch() => ctx.api.items(const ResourceRef(resource: 'pods'), fieldSelector: 'spec.nodeName=${ctx.name}');

  @override
  Widget build(BuildContext context) {
    final allocatable = asMap(ctx.status['allocatable']);
    return FutureBuilder<List<Json>>(
      future: _future,
      builder: (context, snap) {
        final pods = snap.data;
        final allocation = pods == null ? null : nodeAllocation(pods);
        final cpu = parseCpuMillis(allocatable['cpu']);
        final mem = parseBytes(allocatable['memory']);
        final t = allocation?.total;
        String pct(double used, double? of) => of == null || of <= 0 ? '–' : formatPercent(used / of);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          NodeUsagePoller(
            api: ctx.api,
            builder: (context, usage, error) => _NodeHeader(ctx, usage: usage?[ctx.name]?.usage, pods: pods, allocation: allocation),
          ),
          PodSection(
            id: 'node-pods',
            title: 'Pods',
            trailing: SectionSummary(pods == null ? '' : _podSummary(pods)),
            child: snap.hasError
                ? InlineMessage('${snap.error}', isError: true)
                : pods == null
                    ? const SectionSpinner()
                    : PodRows(
                        pods,
                        showNamespace: true,
                        hideTerminal: true,
                        empty: 'No running pods',
                        trailing: (p) {
                          final r = podResources(p);
                          return [
                            if (r.cpuRequest > 0 || r.memRequest > 0)
                              Tooltip(
                                message: 'requests',
                                child: Text(
                                  [if (r.cpuRequest > 0) formatCpu(r.cpuRequest), if (r.memRequest > 0) formatBytes(r.memRequest)].join(' · '),
                                  style: monoStyle(context, size: 11, color: Theme.of(context).hintColor),
                                ),
                              ),
                          ];
                        },
                      ),
          ),
          // Metrics history (hidden without Prometheus), then live network
          // from the kubelet when there is no Prometheus.
          nodeHistory(ctx),
          liveNetworkSection(ctx),
          PodSection(
            id: 'node-allocation',
            title: 'Usage & allocation',
            initiallyExpanded: false,
            trailing: SectionSummary(t == null ? '' : 'requests: cpu ${pct(t.cpuRequest, cpu)} · memory ${pct(t.memRequest, mem)}'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              NodeLiveUsage(api: ctx.api, nodeName: ctx.name, allocatable: allocatable, requests: t),
              const SizedBox(height: 12),
              if (allocation != null) _Allocation(allocation, allocatable) else if (snap.hasError) InlineMessage('${snap.error}', isError: true) else const SectionSpinner(),
            ]),
          ),
        ]);
      },
    );
  }

  static String _podSummary(List<Json> pods) {
    final active = pods.where((p) => !isTerminalPod(p)).toList();
    final problems = active.where(podHasProblem).length;
    return [plural(active.length, 'pod'), if (problems > 0) '$problems with problems'].join(' · ');
  }
}

class _NodeHeader extends StatelessWidget {
  final PanelContext ctx;
  final Usage? usage;
  final List<Json>? pods;
  final NodeAllocation? allocation;
  const _NodeHeader(this.ctx, {this.usage, this.pods, this.allocation});

  @override
  Widget build(BuildContext context) {
    final conds = asMapList(ctx.status['conditions']);
    Json? cond(String t) => conds.where((c) => c['type'] == t).firstOrNull;
    final ready = cond('Ready');
    final readyStatus = ready?['status'] as String?;
    final readyText = readyStatus == 'True' ? 'Ready' : (readyStatus == 'Unknown' ? 'Unknown' : 'NotReady');
    final cordoned = ctx.spec['unschedulable'] == true;
    final labels = asMap(ctx.metadata['labels']);
    final roles = [
      for (final k in labels.keys)
        if (k.startsWith('node-role.kubernetes.io/')) k.substring('node-role.kubernetes.io/'.length),
      if (labels['kubernetes.io/role'] is String) labels['kubernetes.io/role'] as String,
    ];
    final taints = asMapList(ctx.spec['taints']);
    final unschedTaint = taints.any((t) => t['key'] == 'node.kubernetes.io/unschedulable');
    final alloc = asMap(ctx.status['allocatable']);
    final cpu = parseCpuMillis(alloc['cpu']);
    final mem = parseBytes(alloc['memory']);
    final maxPods = double.tryParse('${alloc['pods'] ?? ''}');
    final t = allocation?.total;
    final overcommitted = t != null && ((cpu != null && t.cpuLimit > cpu) || (mem != null && t.memLimit > mem));
    final active = pods?.where((p) => !isTerminalPod(p)).toList();
    final troubled = active?.where(podHasProblem).length ?? 0;
    final version = dig<String>(ctx.status, ['nodeInfo', 'kubeletVersion']);

    final insights = <PodInsight>[
      if (readyStatus != 'True') PodInsight(readyStatus == 'Unknown' ? Severity.warn : Severity.error, 'Node is $readyText', [ready?['reason'], ready?['message']].whereType<String>().join(': ')),
      for (final p in _pressureTypes)
        if (cond(p) != null && cond(p)!['status'] != 'False')
          PodInsight(
            cond(p)!['status'] == 'True' ? Severity.error : Severity.warn,
            cond(p)!['status'] == 'True' ? p : '$p: ${cond(p)!['status'] ?? 'unknown'}',
            [cond(p)!['reason'], cond(p)!['message']].whereType<String>().join(': '),
          ),
      if (cordoned)
        PodInsight(
          Severity.warn,
          'Cordoned: SchedulingDisabled',
          'spec.unschedulable is true; no new pods will be scheduled here${unschedTaint ? ' (node.kubernetes.io/unschedulable taint set).' : '.'}',
        ),
      if (overcommitted) const PodInsight(Severity.warn, 'Overcommitted', 'The pods\' limits exceed what the node can allocate.'),
      if (troubled > 0) PodInsight(Severity.warn, troubled == 1 ? '1 pod has problems' : '$troubled pods have problems', 'See Pods below.'),
    ];

    Severity load(double f) => f >= 0.95 ? Severity.error : (f >= 0.8 ? Severity.warn : Severity.neutral);
    HeaderFigure resource(String name, double? used, double? requested, double? of, String Function(double?) f) {
      if (of == null || of <= 0) return HeaderFigure('–', name);
      if (used != null) {
        return HeaderFigure(formatPercent(used / of), '$name used',
            severity: load(used / of), tooltip: '${f(used)} of ${f(of)} allocatable${requested != null ? ' · ${f(requested)} requested' : ''}');
      }
      if (requested != null) {
        return HeaderFigure(formatPercent(requested / of), '$name req', severity: load(requested / of), tooltip: '${f(requested)} of ${f(of)} allocatable requested (no live metrics)');
      }
      return HeaderFigure('–', name);
    }

    final small = Theme.of(context).textTheme.bodySmall;
    final internalIp = asMapList(ctx.status['addresses']).where((a) => a['type'] == 'InternalIP').map((a) => '${a['address']}').firstOrNull;
    final cidrs = strList(ctx.spec['podCIDRs']).isNotEmpty ? strList(ctx.spec['podCIDRs']).join(', ') : ctx.spec['podCIDR'] as String?;
    return InspectorHeader(
      mark: worstOf(insights) ?? Severity.ok,
      headline: readyText,
      chips: [if (cordoned) const HeadlineChip('Cordoned', tooltip: 'SchedulingDisabled: no new pods will be scheduled here')],
      detail: [roles.isEmpty ? 'no role' : roles.join(', '), ?version].join(' · '),
      figures: [
        resource('cpu', usage?.cpuMillis, t?.cpuRequest, cpu, formatCpu),
        resource('mem', usage?.memoryBytes, t?.memRequest, mem, formatBytes),
        HeaderFigure(active == null ? '–' : '${active.length}', 'pods',
            of: maxPods == null ? null : '/${maxPods.toStringAsFixed(0)}',
            severity: active != null && maxPods != null && active.length >= maxPods ? Severity.warn : Severity.neutral),
      ],
      insights: insights,
      facts: KeyValueTable(keyWidth: 82, [
        ('Ready since', ready == null ? null : AgeText(ready['lastTransitionTime'], suffix: ' ago', style: small)),
        ('Heartbeat', ready == null ? null : AgeText(ready['lastHeartbeatTime'], suffix: ' ago', style: small)),
        ('Internal IP', internalIp == null ? null : Align(alignment: Alignment.centerLeft, child: Chipish(text: internalIp, copyValue: internalIp))),
        ('Pod CIDR', cidrs),
      ]),
    );
  }
}

class _TaintChip extends StatelessWidget {
  final Json taint;
  const _TaintChip(this.taint);

  @override
  Widget build(BuildContext context) {
    final effect = '${taint['effect'] ?? ''}';
    final sev = switch (effect) {
      'NoExecute' => Severity.error,
      'NoSchedule' => Severity.warn,
      _ => Severity.info,
    };
    final c = severityColor(context, sev);
    final v = taint['value'] != null && '${taint['value']}'.isNotEmpty ? '=${taint['value']}' : '';
    final text = '${taint['key']}$v:$effect';
    return Tooltip(
      message: taint['timeAdded'] != null ? 'added ${taint['timeAdded']}' : effect,
      child: Chipish(text: text, copyValue: text, color: c.withValues(alpha: 0.35)),
    );
  }
}

class _Addresses extends StatelessWidget {
  final PanelContext ctx;
  const _Addresses(this.ctx);

  @override
  Widget build(BuildContext context) {
    final addrs = asMapList(ctx.status['addresses']);
    if (addrs.isEmpty) return const InlineMessage('No addresses reported');
    return KeyValueTable([
      for (final a in addrs) ('${a['type']}', Align(alignment: Alignment.centerLeft, child: Chipish(text: '${a['address']}', copyValue: '${a['address']}'))),
    ], keyWidth: 100);
  }
}

class _CapacityTable extends StatelessWidget {
  final Json status;
  const _CapacityTable(this.status);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cap = asMap(status['capacity']);
    final alloc = asMap(status['allocatable']);
    const order = ['cpu', 'memory', 'ephemeral-storage', 'pods'];
    final keys = <String>{...order.where((k) => cap.containsKey(k) || alloc.containsKey(k)), ...cap.keys, ...alloc.keys}.toList();
    final rows = <List<Widget>>[];
    var hiddenZero = 0;
    for (final k in keys) {
      final c = parseQty(k, cap[k]);
      final a = parseQty(k, alloc[k]);
      if (k.startsWith('hugepages-') && (c ?? 0) == 0 && (a ?? 0) == 0) {
        hiddenZero++;
        continue;
      }
      final reserved = (c != null && a != null) ? c - a : null;
      rows.add([
        MonoText(k),
        MonoText(formatQty(k, c)),
        MonoText(formatQty(k, a)),
        MonoText(reserved == null || reserved == 0 ? '—' : formatQty(k, reserved), color: theme.hintColor),
      ]);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      CompactTable(
        headers: const ['RESOURCE', 'CAPACITY', 'ALLOCATABLE', 'RESERVED'],
        flex: const [4, 3, 3, 3],
        align: const [TextAlign.left, TextAlign.right, TextAlign.right, TextAlign.right],
        rows: rows,
      ),
      if (hiddenZero > 0)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('$hiddenZero hugepages sizes with 0 capacity hidden', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
        ),
    ]);
  }
}

class _SystemInfo extends StatelessWidget {
  final PanelContext ctx;
  final Json labels;
  const _SystemInfo(this.ctx, this.labels);

  @override
  Widget build(BuildContext context) {
    final info = asMap(ctx.status['nodeInfo']);
    String? l(List<String> keys) {
      for (final k in keys) {
        final v = labels[k];
        if (v is String && v.isNotEmpty) return v;
      }
      return null;
    }

    return KeyValueTable([
      ('Zone', l(['topology.kubernetes.io/zone', 'failure-domain.beta.kubernetes.io/zone'])),
      ('Region', l(['topology.kubernetes.io/region', 'failure-domain.beta.kubernetes.io/region'])),
      ('Instance type', l(['node.kubernetes.io/instance-type', 'beta.kubernetes.io/instance-type'])),
      ('OS / arch', '${l(['kubernetes.io/os', 'beta.kubernetes.io/os']) ?? info['operatingSystem'] ?? '?'} / ${l(['kubernetes.io/arch', 'beta.kubernetes.io/arch']) ?? info['architecture'] ?? '?'}'),
      ('OS image', Row(mainAxisSize: MainAxisSize.min, children: [NodeOsIcon(ctx.object, size: 14), const SizedBox(width: 6), Flexible(child: Text('${info['osImage'] ?? ''}'))])),
      ('Kernel', info['kernelVersion']),
      ('Runtime', info['containerRuntimeVersion']),
      ('Kubelet', info['kubeletVersion']),
      ('Kube-proxy', info['kubeProxyVersion']),
      ('Provider ID', ctx.spec['providerID']),
      ('Kubelet port', dig(ctx.status, ['daemonEndpoints', 'kubeletEndpoint', 'Port'])?.toString()),
      ('Machine ID', info['machineID']),
    ], keyWidth: 100);
  }
}

class _Images extends StatelessWidget {
  final List<Json> images;
  const _Images(this.images);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (images.isEmpty) return const InlineMessage('No images reported');
    final sorted = [...images]..sort((a, b) => ((b['sizeBytes'] as num?) ?? 0).compareTo((a['sizeBytes'] as num?) ?? 0));
    final total = images.fold<double>(0, (s, i) => s + ((i['sizeBytes'] as num?)?.toDouble() ?? 0));
    String nameOf(Json i) {
      final names = strList(i['names']);
      return names.firstWhere((n) => !n.contains('@sha256:'), orElse: () => names.isEmpty ? '<none>' : names.first);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text('${images.length} images, ${formatBytes(total)} total. Largest:',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
      const SizedBox(height: 4),
      for (final i in sorted.take(5))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Tooltip(message: strList(i['names']).join('\n'), child: MonoText(nameOf(i)))),
            const SizedBox(width: 8),
            MonoText(formatBytes((i['sizeBytes'] as num?)?.toDouble()), color: theme.hintColor),
          ]),
        ),
    ]);
  }
}


class _Allocation extends StatelessWidget {
  final NodeAllocation a;
  final Json allocatable;
  const _Allocation(this.a, this.allocatable);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cpu = parseCpuMillis(allocatable['cpu']);
    final mem = parseBytes(allocatable['memory']);
    final maxPods = double.tryParse('${allocatable['pods'] ?? ''}');
    final t = a.total;
    final overcommitted = (cpu != null && t.cpuLimit > cpu) || (mem != null && t.memLimit > mem);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      UsageBar(label: 'CPU requests', used: t.cpuRequest, total: cpu, usedText: formatCpu(t.cpuRequest), totalText: formatCpu(cpu)),
      UsageBar(label: 'CPU limits', used: t.cpuLimit, total: cpu, usedText: formatCpu(t.cpuLimit), totalText: formatCpu(cpu)),
      UsageBar(label: 'Memory requests', used: t.memRequest, total: mem, usedText: formatBytes(t.memRequest), totalText: formatBytes(mem)),
      UsageBar(label: 'Memory limits', used: t.memLimit, total: mem, usedText: formatBytes(t.memLimit), totalText: formatBytes(mem)),
      UsageBar(
          label: 'Pods',
          used: a.activePods.toDouble(),
          total: maxPods,
          usedText: '${a.activePods}',
          totalText: maxPods == null ? '?' : maxPods.toStringAsFixed(0)),
      const SizedBox(height: 4),
      Text(
        'Sum of effective requests/limits of ${a.activePods} non-terminated pods vs allocatable'
        '${a.terminatedPods > 0 ? ' (${a.terminatedPods} completed/failed excluded)' : ''}.'
        '${overcommitted ? ' Limits exceed allocatable: node is overcommitted.' : ''}',
        style: theme.textTheme.labelSmall?.copyWith(color: overcommitted ? severityColor(context, Severity.warn) : theme.hintColor),
      ),
    ]);
  }
}


