import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
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
    return [
      DetailSection(title: 'Node status', icon: Icons.dns_outlined, child: _StatusBlock(ctx)),
      _NodePods(key: ValueKey(ctx.uid), api: ctx.api, nodeName: ctx.name, allocatable: asMap(status['allocatable'])),
      DetailSection(
        title: 'Conditions',
        icon: Icons.fact_check_outlined,
        initiallyExpanded: false,
        child: ConditionsTable(status['conditions'] as List?),
      ),
      DetailSection(title: 'Addresses', icon: Icons.lan_outlined, child: _Addresses(ctx)),
      DetailSection(title: 'Capacity vs allocatable', icon: Icons.memory, child: _CapacityTable(status)),
      DetailSection(title: 'System info', icon: Icons.info_outline, child: _SystemInfo(ctx, labels)),
      DetailSection(
        title: 'Images',
        icon: Icons.layers_outlined,
        trailing: Text('${asMapList(status['images']).length}', style: Theme.of(context).textTheme.labelSmall),
        child: _Images(asMapList(status['images'])),
      ),
    ];
  }
}

class _StatusBlock extends StatelessWidget {
  final PanelContext ctx;
  const _StatusBlock(this.ctx);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (cordoned)
        Callout(
          severity: Severity.warn,
          icon: Icons.block,
          title: 'Cordoned: SchedulingDisabled',
          child: Text(
            'spec.unschedulable is true; no new pods will be scheduled here${unschedTaint ? '' : '.'}'
            '${unschedTaint ? ' (node.kubernetes.io/unschedulable taint set).' : ''}',
            style: theme.textTheme.bodySmall,
          ),
        ),
      if (readyStatus != 'True')
        Callout(
          severity: Severity.error,
          icon: Icons.error_outline,
          title: 'Node is $readyText',
          child: ready?['message'] != null ? Text('${ready!['message']}', style: theme.textTheme.bodySmall) : null,
        ),
      Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        StatusBadge(readyText, severity: readyStatus == 'True' ? Severity.ok : (readyStatus == 'Unknown' ? Severity.warn : Severity.error)),
        if (cordoned) const StatusBadge('SchedulingDisabled', severity: Severity.warn),
        for (final t in _pressureTypes)
          if (cond(t) != null)
            Tooltip(
              message: '${cond(t)!['reason'] ?? ''}\n${cond(t)!['message'] ?? ''}'.trim(),
              child: StatusBadge(t, dense: true, severity: _pressureSeverity(cond(t)!['status'] as String?)),
            ),
      ]),
      const SizedBox(height: 8),
      KeyValueTable([
        ('Roles', roles.isEmpty ? '<none>' : Wrap(spacing: 4, runSpacing: 4, children: [for (final r in roles) Chipish(text: r)])),
        ('Kubelet', dig<String>(ctx.status, ['nodeInfo', 'kubeletVersion'])),
        ('Ready since', ready == null ? null : AgeText(ready['lastTransitionTime'], suffix: ' ago')),
        ('Heartbeat', ready == null ? null : AgeText(ready['lastHeartbeatTime'], suffix: ' ago')),
        ('Taints', taints.isEmpty ? 'none' : Wrap(spacing: 4, runSpacing: 4, children: [for (final t in taints) _TaintChip(t)])),
        ('Pod CIDR', strList(ctx.spec['podCIDRs']).isNotEmpty ? strList(ctx.spec['podCIDRs']).join(', ') : ctx.spec['podCIDR'] as String?),
      ], keyWidth: 100),
    ]);
  }

  static Severity _pressureSeverity(String? s) => switch (s) {
        'False' => Severity.ok,
        'True' => Severity.error,
        _ => Severity.warn,
      };
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
      ('OS image', info['osImage']),
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

/// Fetches pods on the node once and renders "Allocated resources" and the
/// pod list as two sections.
class _NodePods extends StatefulWidget {
  final ApiClient api;
  final String nodeName;
  final Json allocatable;
  const _NodePods({super.key, required this.api, required this.nodeName, required this.allocatable});

  @override
  State<_NodePods> createState() => _NodePodsState();
}

class _NodePodsState extends State<_NodePods> {
  late Future<List<Json>> _future;

  @override
  void initState() {
    super.initState();
    _future = _fetch();
  }

  @override
  void didUpdateWidget(covariant _NodePods old) {
    super.didUpdateWidget(old);
    if (old.nodeName != widget.nodeName) _future = _fetch();
  }

  Future<List<Json>> _fetch() =>
      widget.api.items(const ResourceRef(resource: 'pods'), fieldSelector: 'spec.nodeName=${widget.nodeName}');

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Json>>(
      future: _future,
      builder: (context, snap) {
        Widget body(Widget Function(List<Json>) f) {
          if (snap.hasError) return InlineMessage('${snap.error}', isError: true);
          if (!snap.hasData) {
            return const Padding(
              padding: EdgeInsets.all(8),
              child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
            );
          }
          return f(snap.data!);
        }

        final pods = snap.data ?? const <Json>[];
        final active = pods.where((p) => !isTerminalPod(p)).length;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DetailSection(
            title: 'Allocated resources',
            icon: Icons.speed,
            child: body((pods) => _Allocation(nodeAllocation(pods), widget.allocatable)),
          ),
          DetailSection(
            title: 'Pods on node',
            icon: Icons.view_in_ar_outlined,
            trailing: snap.hasData ? Text('$active', style: Theme.of(context).textTheme.labelSmall) : null,
            child: body((pods) => _PodList(pods)),
          ),
        ]);
      },
    );
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

class _PodList extends StatelessWidget {
  final List<Json> pods;
  const _PodList(this.pods);

  static int _rank(String status) => switch (severityOf(status)) {
        Severity.error => 0,
        Severity.warn => 1,
        _ => 2,
      };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = pods.where((p) => !isTerminalPod(p)).toList();
    final terminal = pods.length - active.length;
    if (active.isEmpty) return InlineMessage('No running pods${terminal > 0 ? ' ($terminal completed)' : ''}');
    final rows = [for (final p in active) (p, podStatus(p), podResources(p))]
      ..sort((a, b) {
        final r = _rank(a.$2).compareTo(_rank(b.$2));
        if (r != 0) return r;
        final ns = '${dig(a.$1, ['metadata', 'namespace'])}'.compareTo('${dig(b.$1, ['metadata', 'namespace'])}');
        return ns != 0 ? ns : '${dig(a.$1, ['metadata', 'name'])}'.compareTo('${dig(b.$1, ['metadata', 'name'])}');
      });
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      CompactTable(
        headers: const ['STATUS', 'POD', 'CPU REQ', 'MEM REQ'],
        flex: const [5, 11, 3, 3],
        align: const [TextAlign.left, TextAlign.left, TextAlign.right, TextAlign.right],
        rows: [
          for (final (p, status, res) in rows)
            [
              Padding(
                padding: const EdgeInsets.only(right: 4),
                child: StatusBadge(status.length > 16 ? '${status.substring(0, 15)}…' : status, dense: true),
              ),
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                ResourceLink(ObjectRef(kind: 'Pod', name: '${dig(p, ['metadata', 'name'])}', namespace: dig<String>(p, ['metadata', 'namespace'])),
                    label: '${dig(p, ['metadata', 'name'])}'),
                Text(
                  '${dig(p, ['metadata', 'namespace'])}${podRestarts(p) > 0 ? ' · ${podRestarts(p)} restarts' : ''}',
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor),
                ),
              ]),
              MonoText(res.cpuRequest > 0 ? formatCpu(res.cpuRequest) : '—', color: res.cpuRequest > 0 ? null : theme.hintColor),
              MonoText(res.memRequest > 0 ? formatBytes(res.memRequest) : '—', color: res.memRequest > 0 ? null : theme.hintColor),
            ],
        ],
      ),
      if (terminal > 0)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('$terminal completed/failed pods not shown', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
        ),
    ]);
  }
}
