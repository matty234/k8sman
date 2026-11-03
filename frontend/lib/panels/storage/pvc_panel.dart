import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../metrics/volume_usage.dart';
import '../../prometheus/metric_history_chart.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'common.dart';

class PvcPanel extends ResourcePanel {
  const PvcPanel();

  @override
  Set<String> get kinds => {'/PersistentVolumeClaim'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final status = ctx.status;
    final conditions = asMapList(status['conditions']);
    return [
      DetailSection(
        title: 'Claim',
        icon: Icons.storage,
        trailing: StatusBadge(status['phase'] as String? ?? 'Unknown', dense: true),
        child: _ClaimBody(ctx: ctx),
      ),
      DetailSection(
        title: 'Usage',
        icon: Icons.data_usage,
        child: PvcUsageSection(
          key: ValueKey('usage-${ctx.uid}'),
          api: ctx.api,
          namespace: ctx.namespace ?? '',
          claim: ctx.name,
          bound: status['phase'] == 'Bound',
          mountNodes: () async => {
            for (final m in findMounts(await ctx.api.items(podResource, namespace: ctx.namespace), ctx.name))
              if (m.node != null && dig<String>(m.pod, ['status', 'phase']) == 'Running') m.node!,
          },
        ),
      ),
      pvcHistory(ctx),
      DetailSection(
        title: 'Mounted by',
        icon: Icons.link,
        child: PvcMountedBy(
          key: ValueKey('mounts-${ctx.uid}'),
          api: ctx.api,
          namespace: ctx.namespace ?? '',
          claimName: ctx.name,
          accessModes: _strings(spec['accessModes']),
        ),
      ),
      if (conditions.isNotEmpty) DetailSection(title: 'Conditions', icon: Icons.fact_check_outlined, child: ConditionsTable(conditions)),
    ];
  }
}

List<String> _strings(dynamic v) => [for (final e in (v is List ? v : const [])) '$e'];

class _ClaimBody extends StatelessWidget {
  final PanelContext ctx;
  const _ClaimBody({required this.ctx});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spec = ctx.spec;
    final status = ctx.status;
    final phase = status['phase'] as String? ?? '';
    final requested = dig<dynamic>(spec, ['resources', 'requests', 'storage']);
    final limit = dig<dynamic>(spec, ['resources', 'limits', 'storage']);
    final capacity = dig<dynamic>(status, ['capacity', 'storage']);
    final modes = _strings(status['accessModes']).isNotEmpty ? _strings(status['accessModes']) : _strings(spec['accessModes']);
    final scName = spec['storageClassName'] as String?;
    final volumeName = spec['volumeName'] as String?;
    final selectedNode = dig<String>(ctx.metadata, ['annotations', 'volume.kubernetes.io/selected-node']);
    final provisioner = dig<String>(ctx.metadata, ['annotations', 'volume.kubernetes.io/storage-provisioner']) ??
        dig<String>(ctx.metadata, ['annotations', 'volume.beta.kubernetes.io/storage-provisioner']);
    final deleting = dig<String>(ctx.metadata, ['deletionTimestamp']) != null;

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _CapacityHeadline(requested: requested, capacity: capacity, limit: limit),
      if (deleting)
        Callout(
          severity: Severity.warn,
          title: 'Terminating',
          text: (asMap(ctx.metadata)['finalizers'] as List? ?? const []).contains('kubernetes.io/pvc-protection')
              ? 'Deletion is blocked by kubernetes.io/pvc-protection until no pod uses this claim (see Mounted by).'
              : 'The claim is being deleted.',
        ),
      if (phase == 'Pending')
        _PendingExplanation(
          key: ValueKey('pending-${ctx.uid}'),
          api: ctx.api,
          storageClassName: scName,
          volumeName: volumeName,
          selectedNode: selectedNode,
          provisioner: provisioner,
        ),
      if (phase == 'Lost')
        const Callout(
          severity: Severity.error,
          title: 'Lost',
          text: 'The PersistentVolume this claim was bound to no longer exists. Data on it may be gone; the claim must be '
              'recreated (or the PV restored) before pods can use it.',
        ),
      ..._resizeCallouts(context, requested, capacity),
      const SizedBox(height: 6),
      KeyValueTable([
        ('Access modes', AccessModesView(modes)),
        ('Volume mode', ValueWithHint(Text(spec['volumeMode'] as String? ?? 'Filesystem', style: theme.textTheme.bodySmall),
            hint: (spec['volumeMode'] ?? 'Filesystem') == 'Block' ? 'raw block device, no filesystem' : 'mounted as a directory')),
        ('Storage class', _storageClassValue(context, scName)),
        ('Volume', volumeName != null && volumeName.isNotEmpty ? ResourceLink(pvRef(volumeName), label: volumeName) : null),
        ('Provisioner', provisioner != null ? MonoValue(provisioner) : null),
        ('Selected node', selectedNode != null ? ResourceLink(nodeRef(selectedNode), label: selectedNode) : null),
        ('Data source', _dataSource(context, spec['dataSourceRef'] ?? spec['dataSource'])),
        ('Selector', asMap(spec['selector']).isNotEmpty ? MonoValue(selectorToString(spec['selector'])) : null),
        ('Volume attr. class', spec['volumeAttributesClassName'] as String?),
      ], keyWidth: 120),
      _CreatedByStatefulSet(key: ValueKey('sts-${ctx.uid}'), api: ctx.api, namespace: ctx.namespace ?? '', claimName: ctx.name, owners: ownerRefs(ctx.object)),
    ]);
  }

  Widget _storageClassValue(BuildContext context, String? scName) {
    final theme = Theme.of(context);
    if (scName == null) {
      return Text('not set (default class, if any, is assigned)', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    }
    if (scName.isEmpty) {
      return Text('"" (static binding only, no provisioning)', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    }
    return ResourceLink(scRef(scName), label: scName);
  }

  Widget? _dataSource(BuildContext context, dynamic raw) {
    final ds = asMap(raw);
    if (ds.isEmpty) return null;
    final kind = '${ds['kind'] ?? ''}';
    final group = '${ds['apiGroup'] ?? ''}';
    final name = '${ds['name'] ?? ''}';
    final ns = ds['namespace'] as String? ?? ctx.namespace;
    final label = '$kind/$name${group.isNotEmpty ? ' ($group)' : ''}';
    return ValueWithHint(ResourceLink(ObjectRef(group: group, kind: kind, name: name, namespace: ns), label: label),
        hint: kind == 'VolumeSnapshot' ? 'restored from snapshot' : (kind == 'PersistentVolumeClaim' ? 'cloned' : 'populated'));
  }

  List<Widget> _resizeCallouts(BuildContext context, dynamic requested, dynamic capacity) {
    final status = ctx.status;
    final out = <Widget>[];
    final req = parseBytes(requested);
    final cap = parseBytes(capacity);
    final allocated = dig<dynamic>(status, ['allocatedResources', 'storage']);
    final resizeStatus = dig<String>(status, ['allocatedResourceStatuses', 'storage']);
    final condTypes = {for (final c in asMapList(status['conditions'])) if (c['status'] == 'True') '${c['type']}'};

    if (resizeStatus != null && resizeStatus.endsWith('Infeasible')) {
      out.add(Callout(
        severity: Severity.error,
        title: 'Resize infeasible ($resizeStatus)',
        text: 'The ${resizeStatus.startsWith('Node') ? 'node' : 'storage backend'} rejected the expansion to ${requested ?? allocated}. '
            'Lower the request back to a supported size or check the Events tab.',
      ));
      return out;
    }
    for (final t in ['ControllerResizeError', 'NodeResizeError']) {
      if (condTypes.contains(t)) {
        out.add(Callout(severity: Severity.error, title: 'Resize failed', text: '$t: see Conditions and the Events tab.'));
        return out;
      }
    }
    final step = switch (resizeStatus) {
      'ControllerResizeInProgress' => 'the storage backend is expanding the volume',
      'NodeResizePending' => 'the backend volume is expanded; the filesystem grows when a pod mounts it',
      'NodeResizeInProgress' => 'the kubelet is growing the filesystem',
      _ => null,
    };
    if (step != null || condTypes.contains('Resizing') || condTypes.contains('FileSystemResizePending')) {
      final text = step ??
          (condTypes.contains('FileSystemResizePending')
              ? 'the backend volume is expanded; the filesystem grows when a pod (re)mounts it'
              : 'the storage backend is expanding the volume');
      out.add(Callout(
        severity: Severity.info,
        title: 'Resize in progress: ${prettyQuantity(capacity)} to ${prettyQuantity(allocated ?? requested)}',
        text: 'Currently $text.',
      ));
    } else if (req != null && cap != null && req > cap && ctx.status['phase'] == 'Bound') {
      out.add(Callout(
        severity: Severity.warn,
        title: 'Requested more than provisioned',
        text: 'Requested ${prettyQuantity(requested)} but the volume has ${prettyQuantity(capacity)}. Expansion has not started: '
            'check that the StorageClass has allowVolumeExpansion and the Events tab.',
      ));
    }
    return out;
  }
}

/// "1Gi requested · 1Gi provisioned" headline with a usage-style bar.
class _CapacityHeadline extends StatelessWidget {
  final dynamic requested;
  final dynamic capacity;
  final dynamic limit;
  const _CapacityHeadline({required this.requested, required this.capacity, this.limit});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final big = theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    Widget stat(String label, dynamic v, {Color? color}) => Padding(
          padding: const EdgeInsets.only(right: 20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(v == null ? '—' : prettyQuantity(v), style: big?.copyWith(color: v == null ? theme.hintColor : color)),
            Text(label, style: hint),
          ]),
        );
    final req = parseBytes(requested), cap = parseBytes(capacity);
    final mismatch = req != null && cap != null && req != cap;
    return Padding(
      padding: const EdgeInsets.only(top: 2, bottom: 2),
      child: Wrap(children: [
        stat('requested', requested),
        stat('provisioned', capacity, color: mismatch && req > cap ? severityColor(context, Severity.warn) : null),
        if (limit != null) stat('limit', limit),
      ]),
    );
  }
}

/// Derived reason for a Pending claim, using the StorageClass binding mode.
class _PendingExplanation extends StatelessWidget {
  final ApiClient api;
  final String? storageClassName;
  final String? volumeName;
  final String? selectedNode;
  final String? provisioner;
  const _PendingExplanation({super.key, required this.api, this.storageClassName, this.volumeName, this.selectedNode, this.provisioner});

  @override
  Widget build(BuildContext context) {
    final sc = storageClassName;
    if (volumeName != null && volumeName!.isNotEmpty) {
      return Callout(
        severity: Severity.warn,
        title: 'Pending: waiting for a specific volume',
        text: 'spec.volumeName pins this claim to PersistentVolume $volumeName, which is missing, already bound elsewhere, or '
            'does not match the requested size / access modes / class.',
        child: ResourceLink(pvRef(volumeName!), label: 'Open PV $volumeName'),
      );
    }
    if (sc == null || sc.isEmpty) {
      return Callout(
        severity: Severity.warn,
        title: 'Pending: no storage class',
        text: sc == null
            ? 'No storageClassName and no default StorageClass, so nothing will provision a volume. It binds only to a '
                'pre-created PV that matches its size, access modes and selector (or gets a default class once one exists).'
            : 'storageClassName is "", which disables dynamic provisioning. It binds only to a pre-created PV with no class '
                'that matches its size, access modes and selector.',
      );
    }
    return FetchOnce<Json?>(
      deps: sc,
      fetch: () async {
        try {
          return await api.object(scResource, name: sc);
        } on ApiException catch (e) {
          if (e.status == 404) return null;
          rethrow;
        }
      },
      loading: const SizedBox.shrink(),
      errorBuilder: (context, e) => Callout(severity: Severity.warn, title: 'Pending', text: 'Could not load StorageClass $sc: $e'),
      builder: (context, scObj) {
        if (scObj == null) {
          return Callout(
            severity: Severity.error,
            title: 'Pending: StorageClass "$sc" does not exist',
            text: 'Nothing will provision this claim until that class is created, or a matching PV with that class exists.',
          );
        }
        final mode = scObj['volumeBindingMode'] as String? ?? 'Immediate';
        final prov = scObj['provisioner'] as String? ?? provisioner ?? '?';
        if (mode == 'WaitForFirstConsumer' && selectedNode == null) {
          return Callout(
            severity: Severity.info,
            title: 'Pending: waiting for a pod to be scheduled',
            text: 'StorageClass $sc uses WaitForFirstConsumer, so the volume is only provisioned once a pod that uses this claim '
                'is scheduled. This is normal; if no pod is listed under Mounted by, it will stay Pending. If a pod exists but '
                'is unschedulable, check that pod\'s events.',
          );
        }
        if (prov == 'kubernetes.io/no-provisioner') {
          return Callout(
            severity: Severity.warn,
            title: 'Pending: no dynamic provisioner',
            text: 'StorageClass $sc uses kubernetes.io/no-provisioner. Create a PV with storageClassName "$sc" that matches this '
                'claim${selectedNode != null ? ' on node $selectedNode' : ''}.',
          );
        }
        return Callout(
          severity: Severity.warn,
          title: 'Pending: waiting for the provisioner',
          text: '${mode == 'WaitForFirstConsumer' ? 'A pod was scheduled to $selectedNode, so $prov' : '$prov (binding mode Immediate)'} '
              'should be creating the volume. Look for ExternalProvisioning / ProvisioningFailed in the Events tab, and check the '
              'provisioner\'s pods.',
        );
      },
    );
  }
}

/// Link to the StatefulSet whose volumeClaimTemplate produced this claim
/// (`<template>-<sts>-<ordinal>`).
class _CreatedByStatefulSet extends StatelessWidget {
  final ApiClient api;
  final String namespace;
  final String claimName;
  final List<ObjectRef> owners;
  const _CreatedByStatefulSet({super.key, required this.api, required this.namespace, required this.claimName, required this.owners});

  static final _pattern = RegExp(r'^(.+)-(\d+)$');

  @override
  Widget build(BuildContext context) {
    final ownerSts = owners.where((o) => o.kind == 'StatefulSet').toList();
    if (ownerSts.isNotEmpty) return _line(context, ownerSts.first, null);
    if (_pattern.firstMatch(claimName) == null || namespace.isEmpty) return const SizedBox.shrink();
    return FetchOnce<(Json, String, int)?>(
      deps: claimName,
      fetch: () async {
        final list = await api.items(stsResource, namespace: namespace);
        for (final sts in list) {
          final stsName = dig<String>(sts, ['metadata', 'name']) ?? '';
          for (final tpl in asMapList(dig(sts, ['spec', 'volumeClaimTemplates']))) {
            final tplName = dig<String>(tpl, ['metadata', 'name']) ?? '';
            final prefix = '$tplName-$stsName-';
            if (claimName.startsWith(prefix)) {
              final ord = int.tryParse(claimName.substring(prefix.length));
              if (ord != null) return (sts, tplName, ord);
            }
          }
        }
        return null;
      },
      loading: const SizedBox.shrink(),
      errorBuilder: (context, _) => const SizedBox.shrink(),
      builder: (context, hit) {
        if (hit == null) return const SizedBox.shrink();
        final (sts, tpl, ord) = hit;
        final replicas = dig<int>(sts, ['spec', 'replicas']) ?? 1;
        final ref = ObjectRef(group: 'apps', kind: 'StatefulSet', name: dig<String>(sts, ['metadata', 'name']) ?? '', namespace: namespace);
        final retention = asMap(dig(sts, ['spec', 'persistentVolumeClaimRetentionPolicy']));
        final note = StringBuffer('template "$tpl", replica #$ord');
        if (ord >= replicas) note.write(' · orphaned: scaled to $replicas, claim kept');
        if (retention.isNotEmpty) note.write(' · on delete: ${retention['whenDeleted'] ?? 'Retain'}, on scale-down: ${retention['whenScaled'] ?? 'Retain'}');
        return _line(context, ref, note.toString(), warn: ord >= replicas);
      },
    );
  }

  Widget _line(BuildContext context, ObjectRef ref, String? note, {bool warn = false}) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(Icons.account_tree_outlined, size: 14, color: theme.hintColor),
        const SizedBox(width: 6),
        Expanded(
          child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 2, children: [
            Text('Created by', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ResourceLink(ref, label: 'StatefulSet ${ref.name}'),
            if (note != null)
              Text('($note)',
                  style: theme.textTheme.bodySmall?.copyWith(color: warn ? severityColor(context, Severity.warn) : theme.hintColor)),
          ]),
        ),
      ]),
    );
  }
}

/// One pod that mounts the claim.
class PvcMount {
  final Json pod;
  final String volumeName;
  final bool readOnly;
  final List<(String container, String path, bool ro, String? subPath, bool init)> mounts;
  PvcMount(this.pod, this.volumeName, this.readOnly, this.mounts);

  String get name => dig<String>(pod, ['metadata', 'name']) ?? '';
  String? get node => dig<String>(pod, ['spec', 'nodeName']);
  bool get terminated => const {'Succeeded', 'Failed'}.contains(dig<String>(pod, ['status', 'phase']));
}

/// Pods referencing [claimName] (via persistentVolumeClaim or ephemeral).
List<PvcMount> findMounts(List<Json> pods, String claimName) {
  final out = <PvcMount>[];
  for (final pod in pods) {
    final podName = dig<String>(pod, ['metadata', 'name']) ?? '';
    for (final v in asMapList(dig(pod, ['spec', 'volumes']))) {
      final vname = '${v['name']}';
      final direct = dig<String>(v, ['persistentVolumeClaim', 'claimName']) == claimName;
      final ephemeral = v['ephemeral'] is Map && '$podName-$vname' == claimName;
      if (!direct && !ephemeral) continue;
      final mounts = <(String, String, bool, String?, bool)>[];
      for (final (key, init) in [('initContainers', true), ('containers', false)]) {
        for (final c in asMapList(dig(pod, ['spec', key]))) {
          for (final m in asMapList(c['volumeMounts'])) {
            if (m['name'] == vname) {
              mounts.add(('${c['name']}', '${m['mountPath']}', m['readOnly'] == true, m['subPath'] as String?, init));
            }
          }
        }
      }
      out.add(PvcMount(pod, vname, dig<bool>(v, ['persistentVolumeClaim', 'readOnly']) == true, mounts));
    }
  }
  return out;
}

String podStatusText(Json pod) {
  if (dig<String>(pod, ['metadata', 'deletionTimestamp']) != null) return 'Terminating';
  for (final cs in [...asMapList(dig(pod, ['status', 'initContainerStatuses'])), ...asMapList(dig(pod, ['status', 'containerStatuses']))]) {
    final reason = dig<String>(cs, ['state', 'waiting', 'reason']);
    if (reason != null && reason != 'PodInitializing') return reason;
  }
  final phase = dig<String>(pod, ['status', 'phase']) ?? 'Unknown';
  if (phase == 'Pending') {
    final sched = asMapList(dig(pod, ['status', 'conditions'])).where((c) => c['type'] == 'PodScheduled' && c['status'] == 'False');
    if (sched.isNotEmpty) return 'Unschedulable';
  }
  return phase;
}

class PvcMountedBy extends StatelessWidget {
  final ApiClient api;
  final String namespace;
  final String claimName;
  final List<String> accessModes;
  const PvcMountedBy({super.key, required this.api, required this.namespace, required this.claimName, required this.accessModes});

  @override
  Widget build(BuildContext context) {
    return FetchOnce<List<PvcMount>>(
      deps: '$namespace/$claimName',
      fetch: () async => findMounts(await api.items(podResource, namespace: namespace), claimName),
      builder: (context, mounts) {
        if (mounts.isEmpty) {
          return const InlineMessage('No pod in this namespace uses this claim. The volume is idle (and the claim can be deleted '
              'without disrupting anything).');
        }
        final active = mounts.where((m) => !m.terminated).toList();
        final nodes = {for (final m in active) ?m.node};
        final warnings = <Widget>[
          if (accessModes.contains('ReadWriteOncePod') && active.length > 1)
            Callout(
              severity: Severity.error,
              title: 'ReadWriteOncePod claim referenced by ${active.length} pods',
              text: 'Only one pod can use it; the others will fail to start (check their events).',
            )
          else if (accessModes.contains('ReadWriteOnce') && !accessModes.contains('ReadWriteMany') && nodes.length > 1)
            Callout(
              severity: Severity.error,
              title: 'ReadWriteOnce claim used on ${nodes.length} nodes',
              text: 'RWO volumes attach to a single node. Pods on other nodes (${nodes.join(', ')}) will be stuck in '
                  'ContainerCreating with Multi-Attach errors.',
            ),
        ];
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ...warnings,
          for (final m in mounts) _PodMountTile(m: m, namespace: namespace),
        ]);
      },
    );
  }
}

class _PodMountTile extends StatelessWidget {
  final PvcMount m;
  final String namespace;
  const _PodMountTile({required this.m, required this.namespace});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Container(
      margin: const EdgeInsets.only(top: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Icon(Icons.widgets_outlined, size: 14, color: theme.hintColor),
          const SizedBox(width: 6),
          Flexible(child: ResourceLink(ObjectRef(kind: 'Pod', name: m.name, namespace: namespace), label: m.name)),
          const SizedBox(width: 8),
          StatusBadge(podStatusText(m.pod), dense: true),
          const SizedBox(width: 12),
          Expanded(
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              if (m.node != null) ...[
                Icon(Icons.dns_outlined, size: 13, color: theme.hintColor),
                const SizedBox(width: 3),
                Flexible(child: ResourceLink(nodeRef(m.node!), label: m.node)),
              ] else
                Text('not scheduled', style: hint),
            ]),
          ),
        ]),
        const SizedBox(height: 4),
        if (m.mounts.isEmpty)
          Text('volume "${m.volumeName}" declared but not mounted by any container', style: hint)
        else
          for (final (c, path, ro, sub, init) in m.mounts)
            Padding(
              padding: const EdgeInsets.only(left: 20, top: 1),
              child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
                Text('${init ? 'init:' : ''}$c', style: hint),
                Icon(Icons.arrow_forward, size: 12, color: theme.hintColor),
                MonoValue(sub != null ? '$path  (subPath $sub)' : path),
                if (ro || m.readOnly) const StatusBadge('ro', severity: Severity.info, dense: true),
              ]),
            ),
      ]),
    );
  }
}
