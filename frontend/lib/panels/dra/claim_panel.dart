import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import '../pod/pod_widgets.dart';
import 'dra_common.dart';

/// ResourceClaim: what was asked for, what was allocated, who uses it.
class ResourceClaimPanel extends ResourcePanel {
  const ResourceClaimPanel();

  @override
  Set<String> get kinds => {'$draGroup/ResourceClaim'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final allocation = asMap(ctx.status['allocation']);
    final results = asMapList(dig(allocation, ['devices', 'results']));
    final reserved = asMapList(ctx.status['reservedFor']);
    final deviceStatus = asMapList(ctx.status['devices']);
    final nodes = allocationNodes(allocation);
    final state = allocation.isEmpty ? 'Pending' : (reserved.isEmpty ? 'Allocated' : 'Reserved: ${reserved.length}');
    return [
      DetailSection(
        title: 'Claim',
        icon: Icons.memory,
        trailing: StatusBadge(state, dense: true),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (allocation.isEmpty) const Hint('Not allocated yet: the scheduler allocates devices when a pod using this claim is scheduled.'),
          KeyValueTable([
            ('Node', nodes.isEmpty ? null : InlineWrap([for (final n in nodes) ResourceLink(draNodeRef(n), label: n)])),
            ('Allocated', allocation['allocationTimestamp'] == null ? null : Text('${allocation['allocationTimestamp']}', style: Theme.of(context).textTheme.bodySmall)),
          ], keyWidth: 100),
          _Origin(key: ValueKey('origin-${ctx.uid}'), ctx: ctx),
        ]),
      ),
      DetailSection(
        title: 'Requests',
        icon: Icons.fact_check_outlined,
        trailing: Hint('${draRequests(asMap(ctx.spec['devices'])).length}'),
        child: DraRequestList(draRequests(asMap(ctx.spec['devices']))),
      ),
      if (results.isNotEmpty)
        DetailSection(
          title: 'Allocation',
          icon: Icons.developer_board,
          trailing: Hint('${results.length} device${results.length == 1 ? '' : 's'}'),
          child: _Results(results),
        ),
      if (reserved.isNotEmpty || allocation.isNotEmpty)
        DetailSection(
          title: 'Reserved for',
          icon: Icons.link,
          trailing: Hint('${reserved.length}'),
          child: reserved.isEmpty
              ? const Hint('No consumers: the claim is allocated but no pod holds it.')
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final c in reserved) Padding(padding: const EdgeInsets.only(bottom: 3), child: _Consumer(c, ctx.namespace)),
                ]),
        ),
      if (deviceStatus.isNotEmpty)
        DetailSection(title: 'Device status', icon: Icons.monitor_heart_outlined, child: _DeviceStatus(deviceStatus)),
    ];
  }
}

class _Results extends StatelessWidget {
  final List<Json> results;
  const _Results(this.results);

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).hintColor);
    Widget head(String t) => Padding(padding: const EdgeInsets.only(bottom: 3), child: Text(t, style: hint));
    Widget cell(Widget w) => Padding(padding: const EdgeInsets.only(bottom: 4, right: 8), child: w);
    return Table(
      columnWidths: const {0: FlexColumnWidth(1.2), 1: FlexColumnWidth(1.4), 2: FlexColumnWidth(1.4), 3: FlexColumnWidth(1.2)},
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        TableRow(children: [head('Request'), head('Device'), head('Driver'), head('Pool')]),
        for (final r in results)
          TableRow(children: [
            cell(InlineWrap([MonoValue('${r['request'] ?? ''}', size: 11), if (r['adminAccess'] == true) const Chipish(text: 'admin', color: Colors.orange)])),
            cell(MonoValue('${r['device'] ?? ''}', size: 11)),
            cell(MonoValue('${r['driver'] ?? ''}', size: 11)),
            cell(MonoValue('${r['pool'] ?? ''}', size: 11)),
          ]),
      ],
    );
  }
}

/// One `status.reservedFor` entry: pods link to the Pod.
class _Consumer extends StatelessWidget {
  final Json c;
  final String? namespace;
  const _Consumer(this.c, this.namespace);

  @override
  Widget build(BuildContext context) {
    final resource = '${c['resource'] ?? ''}';
    final name = '${c['name'] ?? ''}';
    if (resource == 'pods' && (c['apiGroup'] ?? '') == '') {
      return ResourceLink(ObjectRef(kind: 'Pod', name: name, namespace: namespace), label: 'Pod/$name');
    }
    return Text('$resource/$name', style: Theme.of(context).textTheme.bodySmall);
  }
}

class _DeviceStatus extends StatelessWidget {
  final List<Json> devices;
  const _DeviceStatus(this.devices);

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final d in devices)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              InlineWrap([
                MonoValue('${d['device'] ?? ''}', size: 11),
                Hint('${d['driver'] ?? ''} / ${d['pool'] ?? ''}'),
                for (final ip in (dig<List>(d, ['networkData', 'ips']) ?? const [])) Chipish(text: '$ip'),
                if (dig<String>(d, ['networkData', 'hardwareAddress']) case final mac?) Chipish(text: mac),
              ]),
              if (asMapList(d['conditions']).isNotEmpty) ConditionsTable(asMapList(d['conditions'])),
            ]),
          ),
      ]);
}

/// For a claim a pod's template generated: the owning Pod and the template.
/// The template name lives in the Pod's spec, so the Pod is read once.
class _Origin extends StatefulWidget {
  final PanelContext ctx;
  const _Origin({super.key, required this.ctx});

  @override
  State<_Origin> createState() => _OriginState();
}

class _OriginState extends State<_Origin> {
  late final ObjectRef? _owner = ownerRefs(widget.ctx.object).where((o) => o.kind == 'Pod').firstOrNull;
  late final Future<Json?>? _pod = _owner == null
      ? null
      : widget.ctx.api
          .object(const ResourceRef(resource: 'pods'), namespace: widget.ctx.namespace, name: _owner.name)
          .then<Json?>((p) => p)
          .catchError((_) => null);

  @override
  Widget build(BuildContext context) {
    final owner = _owner;
    if (owner == null) return const SizedBox.shrink();
    final ns = widget.ctx.namespace;
    final podName = owner.name;
    final claimName = dig<String>(widget.ctx.metadata, ['annotations', 'resource.kubernetes.io/pod-claim-name']);
    return FutureBuilder<Json?>(
      future: _pod,
      builder: (context, snap) {
        final entry = asMapList(dig(snap.data, ['spec', 'resourceClaims'])).where((e) => e['name'] == claimName).firstOrNull;
        final template = entry?['resourceClaimTemplateName'] as String?;
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: KeyValueTable([
            ('Created for', ResourceLink(ObjectRef(kind: 'Pod', name: podName, namespace: ns), label: 'Pod/$podName')),
            ('Pod claim', claimName == null ? null : MonoValue(claimName, size: 11)),
            ('Template', template == null ? null : ResourceLink(resourceClaimTemplateRef(template, ns), label: template)),
          ], keyWidth: 100),
        );
      },
    );
  }
}
