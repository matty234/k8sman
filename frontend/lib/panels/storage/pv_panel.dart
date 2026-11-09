import 'dart:convert';

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../ui/inspector/inspector.dart';
import '../panel.dart';
import 'common.dart';
import '../../ui/widgets/atoms.dart';

class PvPanel extends ResourcePanel {
  const PvPanel();

  @override
  Set<String> get kinds => {'/PersistentVolume'};

  @override
  bool get ownerInHeader => true;

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final source = detectPvSource(spec);
    final terms = asMapList(dig(spec, ['nodeAffinity', 'required', 'nodeSelectorTerms']));
    final mountOptions = [for (final o in (spec['mountOptions'] as List? ?? const [])) '$o'];
    final hostNodes = [
      for (final t in terms)
        for (final e in asMapList(t['matchExpressions']))
          if (e['key'] == NodeSelectorView.hostnameKey && e['operator'] == 'In') ...[for (final v in (e['values'] as List? ?? const [])) '$v'],
    ];
    return [
      // Is it bound, to what, and what happens to the data?
      _PvHeader(ctx: ctx),
      // Where the data lives, collapsed behind a one-line summary.
      InspectorSection(
        id: 'pv-source',
        title: source == null ? 'Source' : 'Source · ${pvSourceLabel(source.$1)}',
        initiallyExpanded: false,
        trailing: SectionSummary(source == null ? 'none found' : pvSourceSummary(source.$1, source.$2)),
        child: source == null
            ? const InlineMessage('No volume source found in spec.')
            : PvSourceView(type: source.$1, src: source.$2, namespace: null),
      ),
      if (terms.isNotEmpty)
        InspectorSection(
          id: 'pv-affinity',
          title: 'Node affinity',
          initiallyExpanded: false,
          trailing: SectionSummary(hostNodes.isNotEmpty ? 'only on ${hostNodes.join(', ')}' : _affinitySummary(terms)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Builder(builder: (context) {
              final theme = Theme.of(context);
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('Pods using this volume can only run on nodes matching:', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              );
            }),
            NodeSelectorView(terms),
          ]),
        ),
      if (mountOptions.isNotEmpty)
        InspectorSection(
          id: 'pv-mount-options',
          title: 'Mount options',
          initiallyExpanded: false,
          trailing: SectionSummary(mountOptions.join(', ')),
          child: Wrap(spacing: 4, runSpacing: 4, children: [for (final o in mountOptions) Chipish(text: o, copyValue: o)]),
        ),
    ];
  }
}

/// "zone in eu-west-1a, eu-west-1b": the first expression of the first
/// term, its key shortened ("+ more" when there are others).
String _affinitySummary(List<Json> terms) {
  final exprs = [for (final t in terms) ...asMapList(t['matchExpressions']), for (final t in terms) ...asMapList(t['matchFields'])];
  if (exprs.isEmpty) return '${terms.length} term${terms.length == 1 ? '' : 's'}';
  final e = exprs.first;
  final values = (e['values'] as List? ?? const []).join(', ');
  final key = '${e['key'] ?? ''}'.split('/').last;
  return '$key ${'${e['operator']}' == 'In' ? 'in' : '${e['operator']}'.toLowerCase()}${values.isEmpty ? '' : ' $values'}${exprs.length > 1 ? ' + more' : ''}';
}

/// "ebs.csi.aws.com","/var/local-path/pvc-…", "10.0.0.5:/exports"
/// for a collapsed source section.
String pvSourceSummary(String type, Json src) => switch (type) {
      'csi' => '${src['driver'] ?? ''}',
      'hostPath' || 'local' => '${src['path'] ?? ''}',
      'nfs' => '${src['server'] ?? '?'}:${src['path'] ?? '?'}',
      'iscsi' => '${src['targetPortal'] ?? ''}',
      'awsElasticBlockStore' => '${src['volumeID'] ?? ''}',
      'gcePersistentDisk' => '${src['pdName'] ?? ''}',
      'azureDisk' => '${src['diskName'] ?? ''}',
      _ => src.keys.join(', '),
    };

/// The top of the PV inspector: its phase and why it matters, capacity,
/// reclaim policy and access, then the claim, class and provenance.
class _PvHeader extends StatelessWidget {
  final PanelContext ctx;
  const _PvHeader({required this.ctx});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spec = ctx.spec;
    final phase = dig<String>(ctx.status, ['phase']) ?? 'Unknown';
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
    final deleting = dig<String>(ctx.metadata, ['deletionTimestamp']) != null;
    final since = dig<String>(ctx.status, ['lastPhaseTransitionTime']);

    final sev = switch (phase) {
      'Bound' => Severity.ok,
      'Available' => Severity.info,
      'Failed' => Severity.error,
      _ => Severity.warn,
    };
    final insight = switch (phase) {
      'Released' => Insight(
          Severity.warn,
          'Released',
          'The claim ${claimNs ?? ''}/${claimName ?? ''} was deleted, but the volume still holds its data and '
              'still points at the old claim, so no new claim can bind to it. '
              '${policy == 'Retain' ? 'Reclaim policy is Retain: back up or reuse the data, then delete the PV (and the backing storage) or clear spec.claimRef to make it Available again.' : 'The reclaim policy ($policy) should clean it up shortly; if it stays Released, check the Events tab.'}',
        ),
      'Failed' => Insight(
          Severity.error,
          'Failed${reason != null ? ': $reason' : ''}',
          'Automatic reclamation (policy $policy) failed, so the volume is stuck. '
              '${message ?? 'See the Events tab for the provisioner / recycler error.'} Clean up the backing storage manually and delete the PV.',
        ),
      'Available' => const Insight(
          Severity.info,
          'Available',
          'Not bound to any claim yet. A PVC with a matching class, size, access modes and selector will bind to it.',
        ),
      'Pending' => const Insight(Severity.warn, 'Pending', 'The volume is not yet available for binding.'),
      _ => null,
    };
    final m = RegExp(r'^([\d.]+)\s*([A-Za-z]+)$').firstMatch('${capacity ?? ''}');

    return InspectorHeader(
      mark: deleting ? Severity.warn : sev,
      headline: deleting ? 'Terminating' : phase,
      headlineTone: sev == Severity.warn || sev == Severity.error ? sev : null,
      detail: since == null ? null : Row(children: [const Text('since '), AgeText(since, suffix: ' ago')]),
      figures: [
        capacity == null
            ? const InspectorFigure('—', 'capacity')
            : InspectorFigure(m?.group(1) ?? '$capacity', 'capacity', of: m?.group(2), tooltip: prettyQuantity(capacity)),
        InspectorFigure(policy, 'reclaim', tooltip: _policyHint(policy)),
        InspectorFigure(modes.isEmpty ? '—' : modes.map(accessModeShort).join(','), 'access', tooltip: modes.map((m) => '$m: ${accessModeInfo[m]?.$2 ?? ''}').join('\n')),
      ],
      insights: [
        ?insight,
        if (policy == 'Delete' && phase != 'Released')
          const Insight(Severity.warn, 'Reclaim policy: Delete', 'Deleting the bound claim also deletes this volume and the data on its backing storage.'),
        if (deleting) const Insight(Severity.warn, 'Terminating', 'Deletion waits for kubernetes.io/pv-protection: the volume is removed once no claim is bound to it.'),
      ],
      facts: [
        ?ownerFact(ctx.object),
        (
          'Claim',
          claimName != null ? ResourceLink(pvcRef(claimName, claimNs), label: '${claimNs != null ? '$claimNs/' : ''}$claimName') : Text('unbound', style: hint),
        ),
        ('Class', sc != null && sc.isNotEmpty ? ResourceLink(scRef(sc), label: sc) : Text('none (static)', style: hint)),
        ('Reclaim', ValueWithHint(Text(policy, style: theme.textTheme.bodySmall), hint: _policyHint(policy))),
        ('Access', AccessModesView(modes)),
        ('Mode', ValueWithHint(Text(spec['volumeMode'] as String? ?? 'Filesystem', style: theme.textTheme.bodySmall),
            hint: (spec['volumeMode'] ?? 'Filesystem') == 'Block' ? 'raw block device' : null)),
        ('Provisioner', dig<String>(ctx.metadata, ['annotations', 'pv.kubernetes.io/provisioned-by']) != null
            ? MonoText.cell(dig<String>(ctx.metadata, ['annotations', 'pv.kubernetes.io/provisioned-by'])!)
            : null),
        ('Attr. class', spec['volumeAttributesClassName'] as String?),
      ],
      factsKeyWidth: 76,
    );
  }

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
    Widget? mono(String k) => src[k] == null ? null : MonoText.cell('${src[k]}');
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
          const Padding(
            padding: EdgeInsets.only(top: 8),
            child: InsightLine(Severity.info, 'Data lives on one node\'s filesystem; pods rescheduled elsewhere will not see it (see Node affinity).'),
          ),
        ]);
      case 'local':
        return KeyValueTable([('Path', mono('path')), ('FS type', s('fsType'))], keyWidth: 120);
      case 'nfs':
        return KeyValueTable([
          ('Export', MonoText.cell('${src['server'] ?? '?'}:${src['path'] ?? '?'}')),
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
            (e.key, e.value is Map || e.value is List ? MonoText.cell(jsonEncode(e.value)) : MonoText.cell('${e.value}')),
        ], keyWidth: 120);
    }
  }
}
