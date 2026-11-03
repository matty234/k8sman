import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'common.dart';

class StorageClassPanel extends ResourcePanel {
  const StorageClassPanel();

  @override
  Set<String> get kinds => {'storage.k8s.io/StorageClass'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final o = ctx.object;
    final params = asMap(o['parameters']);
    final topo = asMapList(o['allowedTopologies']);
    final isDefault = isDefaultClass(o);
    return [
      DetailSection(
        title: 'Storage class',
        icon: Icons.category_outlined,
        trailing: isDefault ? const StatusBadge('default', severity: Severity.info, dense: true) : null,
        child: _ClassBody(object: o),
      ),
      DetailSection(
        title: 'Usage',
        icon: Icons.pie_chart_outline,
        child: StorageClassUsage(key: ValueKey('usage-${ctx.uid}'), api: ctx.api, className: ctx.name),
      ),
      DetailSection(
        title: 'Parameters',
        icon: Icons.tune,
        trailing: params.isEmpty ? null : CountPill('${params.length}'),
        child: ParamsTable(params, emptyText: 'No parameters (provisioner defaults apply)'),
      ),
      if (topo.isNotEmpty)
        DetailSection(
          title: 'Allowed topologies',
          icon: Icons.public,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Builder(builder: (context) {
              final theme = Theme.of(context);
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('Volumes are only provisioned in:', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              );
            }),
            NodeSelectorView([
              for (final t in topo)
                {
                  'matchExpressions': [
                    for (final e in asMapList(t['matchLabelExpressions'])) {'key': e['key'], 'operator': 'In', 'values': e['values']},
                  ],
                },
            ]),
          ]),
        ),
    ];
  }
}

class _ClassBody extends StatelessWidget {
  final Json object;
  const _ClassBody({required this.object});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final provisioner = object['provisioner'] as String? ?? '';
    final policy = object['reclaimPolicy'] as String? ?? 'Delete';
    final mode = object['volumeBindingMode'] as String? ?? 'Immediate';
    final expand = object['allowVolumeExpansion'] == true;
    final mountOptions = [for (final m in (object['mountOptions'] as List? ?? const [])) '$m'];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      MonoValue(provisioner),
      if (provisioner == 'kubernetes.io/no-provisioner')
        const Callout(severity: Severity.info, text: 'No dynamic provisioning: PVs for this class must be created manually.'),
      const SizedBox(height: 6),
      KeyValueTable([
        (
          'Default class',
          isDefaultClass(object)
              ? ValueWithHint(const StatusBadge('yes', severity: Severity.ok, dense: true), hint: 'used by claims without storageClassName')
              : Text('no', style: hint),
        ),
        (
          'Reclaim policy',
          ValueWithHint(StatusBadge(policy, severity: policy == 'Delete' ? Severity.warn : Severity.ok, dense: true),
              hint: policy == 'Delete' ? 'data deleted with the claim' : 'volumes kept after the claim is deleted'),
        ),
        (
          'Binding mode',
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(mode, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
            Text(bindingModeExplanation(mode), style: hint),
          ]),
        ),
        (
          'Volume expansion',
          ValueWithHint(StatusBadge(expand ? 'allowed' : 'not allowed', severity: expand ? Severity.ok : Severity.neutral, dense: true),
              hint: expand ? 'grow claims by editing spec.resources.requests' : 'claims cannot be resized'),
        ),
        (
          'Mount options',
          mountOptions.isEmpty ? null : Wrap(spacing: 4, runSpacing: 4, children: [for (final m in mountOptions) Chipish(text: m, copyValue: m)]),
        ),
      ], keyWidth: 120),
    ]);
  }
}

class _Usage {
  final List<Json> pvcs;
  final List<Json> pvs;
  _Usage(this.pvcs, this.pvs);
}

/// PVCs (all namespaces) and PVs that use this class.
class StorageClassUsage extends StatelessWidget {
  final ApiClient api;
  final String className;
  const StorageClassUsage({super.key, required this.api, required this.className});

  static int _phaseRank(String p) => switch (p) { 'Lost' => 0, 'Pending' => 1, 'Failed' => 0, 'Released' => 2, _ => 3 };

  @override
  Widget build(BuildContext context) {
    return FetchOnce<_Usage>(
      deps: className,
      fetch: () async {
        final res = await Future.wait([api.items(pvcResource), api.items(pvResource)]);
        bool match(Json o) => dig<String>(o, ['spec', 'storageClassName']) == className;
        String phase(Json o) => dig<String>(o, ['status', 'phase']) ?? '';
        String key(Json o) => '${dig<String>(o, ['metadata', 'namespace']) ?? ''}/${dig<String>(o, ['metadata', 'name'])}';
        int cmp(Json a, Json b) {
          final r = _phaseRank(phase(a)).compareTo(_phaseRank(phase(b)));
          return r != 0 ? r : key(a).compareTo(key(b));
        }

        return _Usage(res[0].where(match).toList()..sort(cmp), res[1].where(match).toList()..sort(cmp));
      },
      builder: (context, u) {
        final theme = Theme.of(context);
        final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
        final total = u.pvcs.fold<double>(0, (s, c) => s + (parseBytes(dig(c, ['spec', 'resources', 'requests', 'storage'])) ?? 0));
        final pending = u.pvcs.where((c) => dig<String>(c, ['status', 'phase']) == 'Pending').length;
        final released = u.pvs.where((p) => dig<String>(p, ['status', 'phase']) == 'Released').length;
        Widget stat(String v, String label, {Severity? sev}) => Padding(
              padding: const EdgeInsets.only(right: 20),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(v, style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600, color: sev == null ? null : severityColor(context, sev))),
                Text(label, style: hint),
              ]),
            );
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Wrap(children: [
            stat('${u.pvcs.length}', 'claims'),
            stat(total == 0 ? '0' : formatBytes(total), 'requested'),
            stat('${u.pvs.length}', 'volumes'),
            if (pending > 0) stat('$pending', 'pending', sev: Severity.warn),
            if (released > 0) stat('$released', 'released PVs', sev: Severity.warn),
          ]),
          if (u.pvcs.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Claims', style: hint),
            for (final c in u.pvcs) _ClaimRow(c),
          ],
          if (u.pvs.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Volumes', style: hint),
            for (final p in u.pvs) _VolumeRow(p),
          ],
          if (u.pvcs.isEmpty && u.pvs.isEmpty)
            const Padding(padding: EdgeInsets.only(top: 6), child: InlineMessage('No claims or volumes use this class.')),
        ]);
      },
    );
  }
}

class _ClaimRow extends StatelessWidget {
  final Json pvc;
  const _ClaimRow(this.pvc);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ns = dig<String>(pvc, ['metadata', 'namespace']);
    final name = dig<String>(pvc, ['metadata', 'name']) ?? '';
    final phase = dig<String>(pvc, ['status', 'phase']) ?? 'Unknown';
    final cap = dig<dynamic>(pvc, ['status', 'capacity', 'storage']) ?? dig<dynamic>(pvc, ['spec', 'resources', 'requests', 'storage']);
    final modes = [for (final m in (dig<List>(pvc, ['spec', 'accessModes']) ?? const [])) accessModeShort('$m')];
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        SizedBox(width: 72, child: Align(alignment: Alignment.centerLeft, child: StatusBadge(phase, dense: true))),
        Expanded(child: ResourceLink(pvcRef(name, ns), label: '${ns ?? ''}/$name')),
        Text(modes.join(','), style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        const SizedBox(width: 10),
        SizedBox(width: 56, child: Text(cap == null ? '' : '$cap', textAlign: TextAlign.right, style: monoStyle(context, size: 11.5))),
      ]),
    );
  }
}

class _VolumeRow extends StatelessWidget {
  final Json pv;
  const _VolumeRow(this.pv);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = dig<String>(pv, ['metadata', 'name']) ?? '';
    final phase = dig<String>(pv, ['status', 'phase']) ?? 'Unknown';
    final cap = dig<dynamic>(pv, ['spec', 'capacity', 'storage']);
    final claim = asMap(dig(pv, ['spec', 'claimRef']));
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(children: [
        SizedBox(width: 72, child: Align(alignment: Alignment.centerLeft, child: StatusBadge(phase, dense: true))),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            ResourceLink(pvRef(name), label: name),
            if (claim['name'] != null)
              Text('bound to ${claim['namespace'] ?? ''}/${claim['name']}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ]),
        ),
        SizedBox(width: 56, child: Text(cap == null ? '' : '$cap', textAlign: TextAlign.right, style: monoStyle(context, size: 11.5))),
      ]),
    );
  }
}
