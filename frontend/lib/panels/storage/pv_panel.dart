import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'common.dart';

class PvPanel extends ResourcePanel {
  const PvPanel();

  @override
  Set<String> get kinds => {'/PersistentVolume'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final source = detectPvSource(spec);
    final terms = asMapList(dig(spec, ['nodeAffinity', 'required', 'nodeSelectorTerms']));
    final mountOptions = [for (final o in (spec['mountOptions'] as List? ?? const [])) '$o'];
    return [
      DetailSection(
        title: 'Volume',
        icon: Icons.storage,
        trailing: StatusBadge(dig<String>(ctx.status, ['phase']) ?? 'Unknown', dense: true),
        child: _VolumeBody(ctx: ctx),
      ),
      DetailSection(
        title: source == null ? 'Source' : 'Source · ${pvSourceLabel(source.$1)}',
        icon: Icons.album_outlined,
        child: source == null
            ? const InlineMessage('No volume source found in spec.')
            : PvSourceView(type: source.$1, src: source.$2, namespace: null),
      ),
      if (terms.isNotEmpty)
        DetailSection(
          title: 'Node affinity',
          icon: Icons.dns_outlined,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Builder(builder: (context) {
              final theme = Theme.of(context);
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('Pods using this volume can only run on nodes matching:',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              );
            }),
            NodeSelectorView(terms),
          ]),
        ),
      if (mountOptions.isNotEmpty)
        DetailSection(
          title: 'Mount options',
          icon: Icons.tune,
          child: Wrap(spacing: 4, runSpacing: 4, children: [for (final o in mountOptions) Chipish(text: o, copyValue: o)]),
        ),
    ];
  }
}

class _VolumeBody extends StatelessWidget {
  final PanelContext ctx;
  const _VolumeBody({required this.ctx});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spec = ctx.spec;
    final phase = dig<String>(ctx.status, ['phase']) ?? '';
    final reason = dig<String>(ctx.status, ['reason']);
    final message = dig<String>(ctx.status, ['message']);
    final policy = spec['persistentVolumeReclaimPolicy'] as String? ?? 'Retain';
    final claim = asMap(spec['claimRef']);
    final sc = spec['storageClassName'] as String?;
    final capacity = dig<dynamic>(spec, ['capacity', 'storage']);
    final modes = [for (final m in (spec['accessModes'] as List? ?? const [])) '$m'];
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final claimName = claim['name'] as String?;
    final claimNs = claim['namespace'] as String?;

    final phaseCallout = switch (phase) {
      'Released' => Callout(
          severity: Severity.warn,
          title: 'Released',
          text: 'The claim ${claimNs ?? ''}/${claimName ?? ''} was deleted, but the volume still holds its data and '
              'still points at the old claim, so no new claim can bind to it. '
              '${policy == 'Retain' ? 'Reclaim policy is Retain: back up or reuse the data, then delete the PV (and the backing storage) or clear spec.claimRef to make it Available again.' : 'The reclaim policy ($policy) should clean it up shortly; if it stays Released, check the Events tab.'}',
        ),
      'Failed' => Callout(
          severity: Severity.error,
          title: 'Failed${reason != null ? ': $reason' : ''}',
          text: 'Automatic reclamation (policy $policy) failed, so the volume is stuck. '
              '${message ?? 'See the Events tab for the provisioner / recycler error.'} Clean up the backing storage manually and delete the PV.',
        ),
      'Available' => const Callout(
          severity: Severity.info,
          title: 'Available',
          text: 'Not bound to any claim yet. A PVC with a matching class, size, access modes and selector will bind to it.',
        ),
      'Pending' => const Callout(severity: Severity.warn, title: 'Pending', text: 'The volume is not yet available for binding.'),
      _ => null,
    };

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(crossAxisAlignment: WrapCrossAlignment.end, spacing: 10, children: [
        Text(capacity == null ? '—' : prettyQuantity(capacity), style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600)),
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Text([
            modes.map(accessModeShort).join(', '),
            spec['volumeMode'] ?? 'Filesystem',
            if (sc != null && sc.isNotEmpty) sc,
          ].where((s) => '$s'.isNotEmpty).join(' · '), style: hint),
        ),
      ]),
      ?phaseCallout,
      if (policy == 'Delete' && phase != 'Released')
        const Callout(
          severity: Severity.warn,
          title: 'Reclaim policy: Delete',
          text: 'Deleting the bound claim also deletes this volume and the data on its backing storage.',
        ),
      if (dig<String>(ctx.metadata, ['deletionTimestamp']) != null)
        const Callout(
          severity: Severity.warn,
          title: 'Terminating',
          text: 'Deletion waits for kubernetes.io/pv-protection: the volume is removed once no claim is bound to it.',
        ),
      const SizedBox(height: 6),
      KeyValueTable([
        (
          'Claim',
          claimName != null
              ? ResourceLink(pvcRef(claimName, claimNs), label: '${claimNs != null ? '$claimNs/' : ''}$claimName')
              : Text('unbound', style: hint),
        ),
        ('Storage class', sc != null && sc.isNotEmpty ? ResourceLink(scRef(sc), label: sc) : Text('none (static)', style: hint)),
        ('Reclaim policy', ValueWithHint(StatusBadge(policy, dense: true, severity: _policySeverity(policy)), hint: _policyHint(policy))),
        ('Access modes', AccessModesView(modes)),
        ('Volume mode', spec['volumeMode'] as String? ?? 'Filesystem'),
        ('Provisioned by', dig<String>(ctx.metadata, ['annotations', 'pv.kubernetes.io/provisioned-by']) != null
            ? MonoValue(dig<String>(ctx.metadata, ['annotations', 'pv.kubernetes.io/provisioned-by'])!)
            : null),
        ('Volume attr. class', spec['volumeAttributesClassName'] as String?),
        ('Phase since', dig<String>(ctx.status, ['lastPhaseTransitionTime']) != null
            ? AgeText(dig<String>(ctx.status, ['lastPhaseTransitionTime']), suffix: ' ago')
            : null),
      ], keyWidth: 120),
    ]);
  }

  static Severity _policySeverity(String p) => switch (p) {
        'Delete' => Severity.warn,
        'Recycle' => Severity.warn,
        _ => Severity.ok,
      };

  static String _policyHint(String p) => switch (p) {
        'Delete' => 'volume + data deleted with the claim',
        'Retain' => 'data kept after the claim is deleted',
        'Recycle' => 'deprecated: data scrubbed (rm -rf) and reused',
        _ => '',
      };
}

/// Spec keys of a PV that are not the volume source.
const _nonSourceKeys = {
  'accessModes', 'capacity', 'claimRef', 'mountOptions', 'nodeAffinity', 'persistentVolumeReclaimPolicy', 'storageClassName',
  'volumeMode', 'volumeAttributesClassName',
};

/// Finds the volume source (`csi`, `nfs`, ...) in a PV spec.
(String, Json)? detectPvSource(Json spec) {
  for (final e in spec.entries) {
    if (!_nonSourceKeys.contains(e.key) && e.value is Map) return (e.key, asMap(e.value));
  }
  return null;
}

String pvSourceLabel(String type) => const {
      'csi': 'CSI',
      'hostPath': 'hostPath',
      'local': 'Local',
      'nfs': 'NFS',
      'iscsi': 'iSCSI',
      'awsElasticBlockStore': 'AWS EBS (in-tree)',
      'gcePersistentDisk': 'GCE PD (in-tree)',
      'azureDisk': 'Azure Disk (in-tree)',
      'azureFile': 'Azure File (in-tree)',
      'cephfs': 'CephFS',
      'rbd': 'Ceph RBD',
      'fc': 'Fibre Channel',
      'vsphereVolume': 'vSphere (in-tree)',
    }[type] ??
    type;

/// Type-specific rendering of a PV volume source.
class PvSourceView extends StatelessWidget {
  final String type;
  final Json src;
  final String? namespace;
  const PvSourceView({super.key, required this.type, required this.src, this.namespace});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    String? s(String k) => src[k] == null ? null : '${src[k]}';
    Widget? mono(String k) => src[k] == null ? null : MonoValue('${src[k]}');
    Widget? ro() => src['readOnly'] == true ? const StatusBadge('read-only', severity: Severity.info, dense: true) : null;

    switch (type) {
      case 'csi':
        final attrs = asMap(src['volumeAttributes']);
        final secretRefs = [
          for (final k in ['controllerPublishSecretRef', 'nodeStageSecretRef', 'nodePublishSecretRef', 'controllerExpandSecretRef', 'nodeExpandSecretRef'])
            if (asMap(src[k]).isNotEmpty) (k.replaceAll('SecretRef', ''), asMap(src[k])),
        ];
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KeyValueTable([
            ('Driver', mono('driver')),
            ('Volume handle', mono('volumeHandle')),
            ('FS type', s('fsType')),
            ('Access', ro()),
            for (final (k, ref) in secretRefs)
              ('$k secret', ResourceLink(ObjectRef(kind: 'Secret', name: '${ref['name']}', namespace: ref['namespace'] as String?),
                  label: '${ref['namespace'] ?? ''}/${ref['name']}')),
          ], keyWidth: 120),
          if (attrs.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text('Volume attributes', style: hint),
            const SizedBox(height: 2),
            ParamsTable(attrs),
          ],
        ]);
      case 'hostPath':
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KeyValueTable([('Path', mono('path')), ('Type', s('type')?.isEmpty ?? true ? 'unchecked' : s('type'))], keyWidth: 120),
          const Callout(
            severity: Severity.info,
            text: 'Data lives on one node\'s filesystem; pods rescheduled elsewhere will not see it (see Node affinity).',
          ),
        ]);
      case 'local':
        return KeyValueTable([('Path', mono('path')), ('FS type', s('fsType'))], keyWidth: 120);
      case 'nfs':
        return KeyValueTable([
          ('Export', MonoValue('${src['server'] ?? '?'}:${src['path'] ?? '?'}')),
          ('Server', s('server')),
          ('Path', mono('path')),
          ('Access', ro()),
        ], keyWidth: 120);
      case 'iscsi':
        final portals = [for (final p in (src['portals'] as List? ?? const [])) '$p'];
        return KeyValueTable([
          ('Target portal', mono('targetPortal')),
          ('IQN', mono('iqn')),
          ('LUN', s('lun')),
          ('Interface', s('iscsiInterface')),
          ('FS type', s('fsType')),
          ('Portals', portals.isEmpty ? null : Wrap(spacing: 4, runSpacing: 4, children: [for (final p in portals) Chipish(text: p)])),
          ('CHAP', src['chapAuthSession'] == true || src['chapAuthDiscovery'] == true ? 'enabled' : null),
          ('Access', ro()),
        ], keyWidth: 120);
      case 'awsElasticBlockStore':
        return KeyValueTable([('Volume ID', mono('volumeID')), ('FS type', s('fsType')), ('Partition', s('partition')), ('Access', ro())],
            keyWidth: 120);
      case 'gcePersistentDisk':
        return KeyValueTable([('PD name', mono('pdName')), ('FS type', s('fsType')), ('Partition', s('partition')), ('Access', ro())],
            keyWidth: 120);
      case 'azureDisk':
        return KeyValueTable([
          ('Disk name', mono('diskName')),
          ('Disk URI', mono('diskURI')),
          ('Kind', s('kind')),
          ('Caching', s('cachingMode')),
          ('FS type', s('fsType')),
          ('Access', ro()),
        ], keyWidth: 120);
      default:
        return KeyValueTable([
          for (final e in src.entries)
            (e.key, e.value is Map || e.value is List ? MonoValue(jsonEncode(e.value)) : MonoValue('${e.value}')),
        ], keyWidth: 120);
    }
  }
}
