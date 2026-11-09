import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../metrics/volume_usage.dart';
import '../../prometheus/metric_history_chart.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../../ui/inspector/inspector.dart';
import '../panel.dart';
import 'common.dart';
import '../../util/json.dart';

class PvcPanel extends ResourcePanel {
  const PvcPanel();

  @override
  Set<String> get kinds => {'/PersistentVolumeClaim'};

  @override
  bool get ownerInHeader => true;

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final status = ctx.status;
    final conditions = asMapList(status['conditions']);
    final volumeName = spec['volumeName'] as String?;
    final ds = asMap(spec['dataSourceRef'] ?? spec['dataSource']);
    final modes = asStrings(status['accessModes']).isNotEmpty ? asStrings(status['accessModes']) : asStrings(spec['accessModes']);
    final trueConds = [for (final c in conditions) if (c['status'] == 'True') '${c['type']}'];
    final mountsKey = 'pvc-mounts:${identityHashCode(ctx.api)}:${ctx.namespace}/${ctx.name}';
    Future<List<PvcMount>> mounts() => SharedFetch.get(mountsKey, () async => findMounts(await ctx.api.items(podResource, namespace: ctx.namespace), ctx.name));
    return [
      // Is it bound, how big, how full?
      PvcStatusHeader(ctx, mountNodes: () async => {
            for (final m in await mounts())
              if (m.node != null && dig<String>(m.pod, ['status', 'phase']) == 'Running') m.node!,
          }),
      pvcHistory(ctx),
      InspectorSection(
        id: 'pvc-mounts',
        title: 'Mounted by',
        trailing: FutureBuilder<List<PvcMount>>(
          future: mounts(),
          builder: (context, snap) => SectionSummary(snap.data == null ? '' : (snap.data!.isEmpty ? 'idle' : plural(snap.data!.length, 'pod'))),
        ),
        child: PvcMountedBy(
          key: ValueKey('mounts-${ctx.uid}'),
          api: ctx.api,
          namespace: ctx.namespace ?? '',
          claimName: ctx.name,
          accessModes: asStrings(spec['accessModes']),
          load: mounts,
        ),
      ),
      // Reference detail, collapsed behind a one-line summary.
      InspectorSection(
        id: 'pvc-volume',
        title: 'Volume',
        initiallyExpanded: false,
        trailing: SectionSummary([
          volumeName != null && volumeName.isNotEmpty ? volumeName : 'not bound',
          if ((spec['volumeMode'] ?? 'Filesystem') == 'Block') 'block',
        ].join(' · ')),
        child: _VolumeDetails(ctx: ctx, modes: modes),
      ),
      if (ds.isNotEmpty)
        InspectorSection(
          id: 'pvc-datasource',
          title: 'Data source',
          initiallyExpanded: false,
          trailing: SectionSummary('${ds['kind'] ?? ''}/${ds['name'] ?? ''}'),
          child: _dataSource(ctx, ds),
        ),
      if (conditions.isNotEmpty)
        InspectorSection(
          id: 'pvc-conditions',
          title: 'Conditions',
          initiallyExpanded: false,
          trailing: SectionSummary(trueConds.isEmpty ? 'none true' : trueConds.join(', '),
              color: trueConds.any((t) => t.contains('Error')) ? severityColor(context, Severity.error) : null),
          child: ConditionsTable(conditions),
        ),
      _CreatedByStatefulSet(key: ValueKey('sts-${ctx.uid}'), api: ctx.api, namespace: ctx.namespace ?? '', claimName: ctx.name, owners: ownerRefs(ctx.object)),
    ];
  }

  static Widget _dataSource(PanelContext ctx, Json ds) {
    final kind = '${ds['kind'] ?? ''}';
    final group = '${ds['apiGroup'] ?? ''}';
    final name = '${ds['name'] ?? ''}';
    final ns = ds['namespace'] as String? ?? ctx.namespace;
    final label = '$kind/$name${group.isNotEmpty ? ' ($group)' : ''}';
    return ValueWithHint(ResourceLink(ObjectRef(group: group, kind: kind, name: name, namespace: ns), label: label),
        hint: kind == 'VolumeSnapshot' ? 'restored from snapshot' : (kind == 'PersistentVolumeClaim' ? 'cloned' : 'populated'));
  }
}


/// "1Gi" as a big figure: the number, then its unit small.
InspectorFigure _quantityFigure(dynamic q, String label, {Severity severity = Severity.neutral, String? tooltip}) {
  if (q == null) return InspectorFigure('—', label);
  final m = RegExp(r'^([\d.]+)\s*([A-Za-z]+)$').firstMatch('$q');
  return m == null
      ? InspectorFigure('$q', label, severity: severity, tooltip: tooltip)
      : InspectorFigure(m.group(1), label, of: m.group(2), severity: severity, tooltip: tooltip ?? prettyQuantity(q));
}

/// The top of the claim inspector: Bound, or Pending / Lost and why; how
/// much was requested and provisioned; the class, access modes and how
/// full the volume is.
class PvcStatusHeader extends StatelessWidget {
  final PanelContext ctx;
  final Future<Set<String>> Function() mountNodes;
  const PvcStatusHeader(this.ctx, {super.key, required this.mountNodes});

  @override
  Widget build(BuildContext context) {
    final spec = ctx.spec;
    final status = ctx.status;
    final phase = status['phase'] as String? ?? 'Unknown';
    final requested = dig<dynamic>(spec, ['resources', 'requests', 'storage']);
    final limit = dig<dynamic>(spec, ['resources', 'limits', 'storage']);
    final capacity = dig<dynamic>(status, ['capacity', 'storage']);
    final modes = asStrings(status['accessModes']).isNotEmpty ? asStrings(status['accessModes']) : asStrings(spec['accessModes']);
    final scName = spec['storageClassName'] as String?;
    final volumeName = spec['volumeName'] as String?;
    final selectedNode = dig<String>(ctx.metadata, ['annotations', 'volume.kubernetes.io/selected-node']);
    final provisioner = dig<String>(ctx.metadata, ['annotations', 'volume.kubernetes.io/storage-provisioner']) ??
        dig<String>(ctx.metadata, ['annotations', 'volume.beta.kubernetes.io/storage-provisioner']);
    final deleting = dig<String>(ctx.metadata, ['deletionTimestamp']) != null;
    final req = parseBytes(requested), cap = parseBytes(capacity);
    final short = req != null && cap != null && req > cap;

    final sev = switch (phase) {
      'Bound' => Severity.ok,
      'Lost' => Severity.error,
      _ => Severity.warn,
    };
    return InspectorHeader(
      mark: deleting ? Severity.warn : sev,
      headline: deleting ? 'Terminating' : phase,
      headlineTone: phase == 'Bound' && !deleting ? null : (deleting ? Severity.warn : sev),
      detail: deleting ? Text('was $phase') : null,
      figures: [
        _quantityFigure(capacity, 'provisioned', severity: short ? Severity.warn : Severity.neutral),
        // Only when it differs from what was provisioned.
        if (cap == null || req != cap) _quantityFigure(requested, 'requested'),
        if (limit != null) _quantityFigure(limit, 'limit'),
      ],
      extraInsights: [
        if (deleting)
          InsightLine(
            Severity.warn,
            'Terminating',
            detail: (asMap(ctx.metadata)['finalizers'] as List? ?? const []).contains('kubernetes.io/pvc-protection')
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
          const InsightLine(
            Severity.error,
            'Lost',
            detail: 'The PersistentVolume this claim was bound to no longer exists. Data on it may be gone; the claim must be '
                'recreated (or the PV restored) before pods can use it.',
          ),
        ..._resizeInsights(requested, capacity),
      ],
      facts: [
        ?ownerFact(ctx.object),
        ('Class', _storageClassValue(context, scName)),
        ('Access', AccessModesView(modes)),
        (
          'Usage',
          PvcUsageSection(
            key: ValueKey('usage-${ctx.uid}'),
            api: ctx.api,
            namespace: ctx.namespace ?? '',
            claim: ctx.name,
            bound: phase == 'Bound',
            mountNodes: mountNodes,
          ),
        ),
      ],
      factsKeyWidth: 56,
    );
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

  List<Widget> _resizeInsights(dynamic requested, dynamic capacity) {
    final status = ctx.status;
    final out = <Widget>[];
    final req = parseBytes(requested);
    final cap = parseBytes(capacity);
    final allocated = dig<dynamic>(status, ['allocatedResources', 'storage']);
    final resizeStatus = dig<String>(status, ['allocatedResourceStatuses', 'storage']);
    final condTypes = {for (final c in asMapList(status['conditions'])) if (c['status'] == 'True') '${c['type']}'};

    if (resizeStatus != null && resizeStatus.endsWith('Infeasible')) {
      out.add(InsightLine(
        Severity.error,
        'Resize infeasible ($resizeStatus)',
        detail: 'The ${resizeStatus.startsWith('Node') ? 'node' : 'storage backend'} rejected the expansion to ${requested ?? allocated}. '
            'Lower the request back to a supported size or check the Events tab.',
      ));
      return out;
    }
    for (final t in ['ControllerResizeError', 'NodeResizeError']) {
      if (condTypes.contains(t)) {
        out.add(InsightLine(Severity.error, 'Resize failed', detail: '$t: see Conditions and the Events tab.'));
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
      out.add(InsightLine(
        Severity.info,
        'Resize in progress: ${prettyQuantity(capacity)} to ${prettyQuantity(allocated ?? requested)}',
        detail: 'Currently $text.',
      ));
    } else if (req != null && cap != null && req > cap && ctx.status['phase'] == 'Bound') {
      out.add(InsightLine(
        Severity.warn,
        'Requested more than provisioned',
        detail: 'Requested ${prettyQuantity(requested)} but the volume has ${prettyQuantity(capacity)}. Expansion has not started: '
            'check that the StorageClass has allowVolumeExpansion and the Events tab.',
      ));
    }
    return out;
  }
}

/// The bound volume and how the claim asks for it: the PV link, volume
/// mode, provisioner, selected node, selector and attributes class.
class _VolumeDetails extends StatelessWidget {
  final PanelContext ctx;
  final List<String> modes;
  const _VolumeDetails({required this.ctx, required this.modes});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spec = ctx.spec;
    final volumeName = spec['volumeName'] as String?;
    final selectedNode = dig<String>(ctx.metadata, ['annotations', 'volume.kubernetes.io/selected-node']);
    final provisioner = dig<String>(ctx.metadata, ['annotations', 'volume.kubernetes.io/storage-provisioner']) ??
        dig<String>(ctx.metadata, ['annotations', 'volume.beta.kubernetes.io/storage-provisioner']);
    return KeyValueTable([
      ('Volume', volumeName != null && volumeName.isNotEmpty ? ResourceLink(pvRef(volumeName), label: volumeName) : Text('not bound yet', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
      ('Volume mode', ValueWithHint(Text(spec['volumeMode'] as String? ?? 'Filesystem', style: theme.textTheme.bodySmall),
          hint: (spec['volumeMode'] ?? 'Filesystem') == 'Block' ? 'raw block device, no filesystem' : 'mounted as a directory')),
      ('Provisioner', provisioner != null ? MonoValue(provisioner) : null),
      ('Selected node', selectedNode != null ? ResourceLink(nodeRef(selectedNode), label: selectedNode) : null),
      ('Selector', asMap(spec['selector']).isNotEmpty ? MonoValue(selectorToString(spec['selector'])) : null),
      ('Volume attr. class', spec['volumeAttributesClassName'] as String?),
    ], keyWidth: 120);
  }
}

/// An insight line (title, text, optional action) for the pending
/// explanation.
class _Insight extends StatelessWidget {
  final Severity severity;
  final String? title;
  final String text;
  final Widget? child;
  const _Insight({required this.severity, required this.text, this.title, this.child});

  @override
  Widget build(BuildContext context) => InsightLine(severity, title ?? text, detail: title == null ? null : text, action: child);
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
      return _Insight(
        severity: Severity.warn,
        title: 'Pending: waiting for a specific volume',
        text: 'spec.volumeName pins this claim to PersistentVolume $volumeName, which is missing, already bound elsewhere, or '
            'does not match the requested size / access modes / class.',
        child: ResourceLink(pvRef(volumeName!), label: 'Open PV $volumeName'),
      );
    }
    if (sc == null || sc.isEmpty) {
      return _Insight(
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
      errorBuilder: (context, e) => _Insight(severity: Severity.warn, title: 'Pending', text: 'Could not load StorageClass $sc: $e'),
      builder: (context, scObj) {
        if (scObj == null) {
          return _Insight(
            severity: Severity.error,
            title: 'Pending: StorageClass "$sc" does not exist',
            text: 'Nothing will provision this claim until that class is created, or a matching PV with that class exists.',
          );
        }
        final mode = scObj['volumeBindingMode'] as String? ?? 'Immediate';
        final prov = scObj['provisioner'] as String? ?? provisioner ?? '?';
        if (mode == 'WaitForFirstConsumer' && selectedNode == null) {
          return _Insight(
            severity: Severity.info,
            title: 'Pending: waiting for a pod to be scheduled',
            text: 'StorageClass $sc uses WaitForFirstConsumer, so the volume is only provisioned once a pod that uses this claim '
                'is scheduled. This is normal; if no pod is listed under Mounted by, it will stay Pending. If a pod exists but '
                'is unschedulable, check that pod\'s events.',
          );
        }
        if (prov == 'kubernetes.io/no-provisioner') {
          return _Insight(
            severity: Severity.warn,
            title: 'Pending: no dynamic provisioner',
            text: 'StorageClass $sc uses kubernetes.io/no-provisioner. Create a PV with storageClassName "$sc" that matches this '
                'claim${selectedNode != null ? ' on node $selectedNode' : ''}.',
          );
        }
        return _Insight(
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
/// (`<template>-<sts>-<ordinal>`), as a collapsed section; nothing when the
/// claim didn't come from one.
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
    if (ownerSts.isNotEmpty) return _section(context, ownerSts.first, null, ownerSts.first.name);
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
        return _section(context, ref, note.toString(), '${ref.name} #$ord${ord >= replicas ? ' · orphaned' : ''}', warn: ord >= replicas);
      },
    );
  }

  Widget _section(BuildContext context, ObjectRef ref, String? note, String summary, {bool warn = false}) {
    final theme = Theme.of(context);
    return InspectorSection(
      id: 'pvc-created-by',
      title: 'Created by StatefulSet',
      initiallyExpanded: false,
      trailing: SectionSummary(summary, color: warn ? severityColor(context, Severity.warn) : null),
      child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 2, children: [
        ResourceLink(ref, label: 'StatefulSet ${ref.name}'),
        if (note != null)
          Text('($note)', style: theme.textTheme.bodySmall?.copyWith(color: warn ? severityColor(context, Severity.warn) : theme.hintColor)),
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

/// The pods that mount the claim as compact rows (troubled pods first),
/// each with where it mounts the volume; warnings when the access mode
/// can't serve them all.
class PvcMountedBy extends StatelessWidget {
  final ApiClient api;
  final String namespace;
  final String claimName;
  final List<String> accessModes;

  /// Loads the mounts (shared with the section summary); defaults to
  /// listing the namespace's pods.
  final Future<List<PvcMount>> Function()? load;
  const PvcMountedBy({super.key, required this.api, required this.namespace, required this.claimName, required this.accessModes, this.load});

  @override
  Widget build(BuildContext context) {
    return FetchOnce<List<PvcMount>>(
      deps: '$namespace/$claimName',
      fetch: load ?? () async => findMounts(await api.items(podResource, namespace: namespace), claimName),
      builder: (context, mounts) {
        if (mounts.isEmpty) {
          return const InlineMessage('No pod in this namespace uses this claim. The volume is idle (and the claim can be deleted '
              'without disrupting anything).');
        }
        final active = mounts.where((m) => !m.terminated).toList();
        final nodes = {for (final m in active) ?m.node};
        final warnings = <Widget>[
          if (accessModes.contains('ReadWriteOncePod') && active.length > 1)
            InsightLine(
              Severity.error,
              'ReadWriteOncePod claim referenced by ${active.length} pods',
              detail: 'Only one pod can use it; the others will fail to start (check their events).',
            )
          else if (accessModes.contains('ReadWriteOnce') && !accessModes.contains('ReadWriteMany') && nodes.length > 1)
            InsightLine(
              Severity.error,
              'ReadWriteOnce claim used on ${nodes.length} nodes',
              detail: 'RWO volumes attach to a single node. Pods on other nodes (${nodes.join(', ')}) will be stuck in '
                  'ContainerCreating with Multi-Attach errors.',
            ),
        ];
        bool bad(PvcMount m) => severityOf(podStatusText(m.pod)) == Severity.error || severityOf(podStatusText(m.pod)) == Severity.warn;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final w in warnings) Padding(padding: const EdgeInsets.only(bottom: 10), child: w),
          TrimmedList([
            for (final m in [...mounts.where(bad), ...mounts.where((m) => !bad(m))]) _PodMountRow(m: m, namespace: namespace),
          ], keep: 6, trimAbove: 8),
        ]);
      },
    );
  }
}

class _PodMountRow extends StatelessWidget {
  final PvcMount m;
  final String namespace;
  const _PodMountRow({required this.m, required this.namespace});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final status = podStatusText(m.pod);
    final sev = m.terminated ? Severity.neutral : (status == 'Running' ? Severity.ok : severityOf(status));
    final problem = sev == Severity.error || sev == Severity.warn;
    return InspectorRow(
      key: ValueKey('pvc-mount-${m.name}'),
      dot: sev,
      dotTooltip: status,
      problem: problem,
      title: ResourceLink(ObjectRef(kind: 'Pod', name: m.name, namespace: namespace), label: m.name, singleLine: true),
      subtitle: Row(children: [
        Text(status, style: problem ? TextStyle(color: severityColor(context, sev), fontWeight: FontWeight.w600) : null),
        const Text('  ·  '),
        if (m.node != null) Flexible(child: ResourceLink(nodeRef(m.node!), label: m.node, singleLine: true)) else const Text('not scheduled'),
      ]),
      below: m.mounts.isEmpty
          ? Text('volume "${m.volumeName}" declared but not mounted by any container', style: hint)
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (c, path, ro, sub, init) in m.mounts)
                Padding(
                  padding: const EdgeInsets.only(top: 1),
                  child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
                    Text('${init ? 'init:' : ''}$c', style: hint),
                    Icon(Icons.arrow_forward, size: 11, color: theme.hintColor),
                    MonoValue(sub != null ? '$path  (subPath $sub)' : path),
                    if (ro || m.readOnly) Text('read-only', style: hint),
                  ]),
                ),
            ]),
    );
  }
}
