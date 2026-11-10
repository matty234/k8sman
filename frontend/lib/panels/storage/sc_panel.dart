import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../../ui/inspector/inspector.dart';
import '../panel.dart';
import 'common.dart';

class StorageClassPanel extends ResourcePanel {
  const StorageClassPanel();

  @override
  Set<String> get kinds => {'storage.k8s.io/StorageClass'};

  @override
  bool get ownerInHeader => true;

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final o = ctx.object;
    final params = asMap(o['parameters']);
    final topo = asMapList(o['allowedTopologies']);
    final zones = [for (final t in topo) for (final e in asMapList(t['matchLabelExpressions'])) ...[for (final v in (e['values'] as List? ?? const [])) '$v']];
    Widget usage(Widget Function(BuildContext, StorageClassUsageData?) builder) => SharedFetchBuilder<StorageClassUsageData>(
          fetchKey: 'sc-usage:${identityHashCode(ctx.api)}:${ctx.name}',
          fetch: () => fetchStorageClassUsage(ctx.api, ctx.name),
          builder: (context, snap) => builder(context, snap.data),
        );
    return [
      // What provisions it, how it binds, and how much uses it.
      CoreSection('status', usage((context, u) => _ClassHeader(object: o, usage: u))),
      CoreSection('used-by', usage((context, u) => InspectorSection(
            id: 'sc-usage',
            title: 'Used by',
            trailing: SectionSummary(u == null ? '' : '${plural(u.pvcs.length, 'claim')} · ${plural(u.pvs.length, 'volume')}'),
            child: StorageClassUsage(key: ValueKey('usage-${ctx.uid}'), api: ctx.api, className: ctx.name),
          ))),
      // Reference detail, collapsed behind a one-line summary.
      CoreSection('parameters', InspectorSection(
        id: 'sc-parameters',
        title: 'Parameters',
        initiallyExpanded: false,
        trailing: SectionSummary(params.isEmpty ? 'none' : params.keys.take(4).join(', ') + (params.length > 4 ? ' +${params.length - 4}' : '')),
        child: ParamsTable(params, emptyText: 'No parameters (provisioner defaults apply)'),
      )),
      if (topo.isNotEmpty)
        CoreSection('allowed-topologies', InspectorSection(
          id: 'sc-topologies',
          title: 'Allowed topologies',
          initiallyExpanded: false,
          trailing: SectionSummary(zones.isEmpty ? '${topo.length} term${topo.length == 1 ? '' : 's'}' : 'only in ${zones.join(', ')}'),
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
        )),
    ];
  }
}

/// The provisioner (with a default chip), how much uses the class, and how
/// it binds, expands and reclaims.
class _ClassHeader extends StatelessWidget {
  final Json object;
  final StorageClassUsageData? usage;
  const _ClassHeader({required this.object, required this.usage});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final provisioner = object['provisioner'] as String? ?? '';
    final policy = object['reclaimPolicy'] as String? ?? 'Delete';
    final mode = object['volumeBindingMode'] as String? ?? 'Immediate';
    final expand = object['allowVolumeExpansion'] == true;
    final mountOptions = [for (final m in (object['mountOptions'] as List? ?? const [])) '$m'];
    final isDefault = isDefaultClass(object);
    final u = usage;
    final total = u?.pvcs.fold<double>(0, (s, c) => s + (parseBytes(dig(c, ['spec', 'resources', 'requests', 'storage'])) ?? 0));
    final pending = u?.pvcs.where((c) => dig<String>(c, ['status', 'phase']) == 'Pending').length ?? 0;
    final released = u?.pvs.where((p) => dig<String>(p, ['status', 'phase']) == 'Released').length ?? 0;
    final size = total == null ? null : (total == 0 ? ['0'] : formatBytes(total).split(' '));

    return InspectorHeader(
      headline: provisioner.isEmpty ? '(no provisioner)' : provisioner,
      chips: [
        if (isDefault)
          const Tooltip(message: 'Used by claims without storageClassName', child: StatusBadge('default', severity: Severity.info, dense: true)),
      ],
      figures: [
        InspectorFigure(u == null ? null : '${u.pvcs.length}', 'claims'),
        InspectorFigure(size?.first, 'requested', of: size != null && size.length > 1 ? ' ${size[1]}' : null),
        InspectorFigure(u == null ? null : '${u.pvs.length}', 'volumes'),
        if (pending > 0) InspectorFigure('$pending', 'pending', severity: Severity.warn),
        if (released > 0) InspectorFigure('$released', 'released PVs', severity: Severity.warn),
      ],
      insights: [
        if (provisioner == 'kubernetes.io/no-provisioner') const Insight(Severity.info, 'No dynamic provisioning: PVs for this class must be created manually.'),
      ],
      facts: [
        ?ownerFact(object),
        (
          'Binding',
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(mode, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
            Text(bindingModeExplanation(mode), style: hint),
          ]),
        ),
        (
          'Expansion',
          ValueWithHint(Text(expand ? 'allowed' : 'not allowed', style: theme.textTheme.bodySmall),
              hint: expand ? 'grow claims by editing spec.resources.requests' : 'claims cannot be resized'),
        ),
        (
          'Reclaim',
          ValueWithHint(Text(policy, style: theme.textTheme.bodySmall), hint: policy == 'Delete' ? 'data deleted with the claim' : 'volumes kept after the claim is deleted'),
        ),
        ('Mount options', mountOptions.isEmpty ? null : Wrap(spacing: 4, runSpacing: 4, children: [for (final m in mountOptions) Chipish(text: m, copyValue: m)])),
      ],
      factsKeyWidth: 76,
    );
  }
}

/// PVCs (all namespaces) and PVs that use a class, troubled ones first.
class StorageClassUsageData {
  final List<Json> pvcs;
  final List<Json> pvs;
  StorageClassUsageData(this.pvcs, this.pvs);
}

int _phaseRank(String p) => switch (p) { 'Lost' => 0, 'Pending' => 1, 'Failed' => 0, 'Released' => 2, _ => 3 };

Future<StorageClassUsageData> fetchStorageClassUsage(ApiClient api, String className) async {
  final res = await Future.wait([api.items(pvcResource), api.items(pvResource)]);
  bool match(Json o) => dig<String>(o, ['spec', 'storageClassName']) == className;
  String phase(Json o) => dig<String>(o, ['status', 'phase']) ?? '';
  String key(Json o) => '${dig<String>(o, ['metadata', 'namespace']) ?? ''}/${dig<String>(o, ['metadata', 'name'])}';
  int cmp(Json a, Json b) {
    final r = _phaseRank(phase(a)).compareTo(_phaseRank(phase(b)));
    return r != 0 ? r : key(a).compareTo(key(b));
  }

  return StorageClassUsageData(res[0].where(match).toList()..sort(cmp), res[1].where(match).toList()..sort(cmp));
}

/// The claims and volumes of a class as compact rows.
class StorageClassUsage extends StatelessWidget {
  final ApiClient api;
  final String className;
  const StorageClassUsage({super.key, required this.api, required this.className});

  @override
  Widget build(BuildContext context) {
    return SharedFetchBuilder<StorageClassUsageData>(
      fetchKey: 'sc-usage:${identityHashCode(api)}:$className',
      fetch: () => fetchStorageClassUsage(api, className),
      builder: (context, snap) {
        if (snap.hasError) return InlineMessage('${snap.error}', isError: true);
        final u = snap.data;
        if (u == null) return const SectionSpinner();
        if (u.pvcs.isEmpty && u.pvs.isEmpty) return const InlineMessage('No claims or volumes use this class.');
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (u.pvcs.isNotEmpty) ...[
            const _GroupLabel('Claims'),
            TrimmedList([for (final c in u.pvcs) _ClaimRow(c)], keep: 6, trimAbove: 8),
          ],
          if (u.pvs.isNotEmpty) ...[
            const _GroupLabel('Volumes'),
            TrimmedList([for (final p in u.pvs) _VolumeRow(p)], keep: 6, trimAbove: 8),
          ],
        ]);
      },
    );
  }
}

class _GroupLabel extends StatelessWidget {
  final String text;
  const _GroupLabel(this.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 0, 2),
      child: Text(text, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600, letterSpacing: 0.3)),
    );
  }
}

Severity _phaseSeverity(String phase) => switch (phase) {
      'Bound' => Severity.ok,
      'Available' => Severity.info,
      'Lost' || 'Failed' => Severity.error,
      _ => Severity.warn,
    };

class _ClaimRow extends StatelessWidget {
  final Json pvc;
  const _ClaimRow(this.pvc);

  @override
  Widget build(BuildContext context) {
    final ns = dig<String>(pvc, ['metadata', 'namespace']);
    final name = dig<String>(pvc, ['metadata', 'name']) ?? '';
    final phase = dig<String>(pvc, ['status', 'phase']) ?? 'Unknown';
    final cap = dig<dynamic>(pvc, ['status', 'capacity', 'storage']) ?? dig<dynamic>(pvc, ['spec', 'resources', 'requests', 'storage']);
    final modes = [for (final m in (dig<List>(pvc, ['spec', 'accessModes']) ?? const [])) accessModeShort('$m')];
    final sev = _phaseSeverity(phase);
    final bad = sev == Severity.warn || sev == Severity.error;
    return InspectorRow(
      dot: sev,
      dotTooltip: phase,
      title: ResourceLink(pvcRef(name, ns), label: '${ns ?? ''}/$name', singleLine: true),
      subtitle: Text.rich(TextSpan(children: [
        TextSpan(text: phase, style: bad ? TextStyle(color: severityColor(context, sev), fontWeight: FontWeight.w600) : null),
        if (modes.isNotEmpty) TextSpan(text: '  ·  ${modes.join(',')}'),
      ])),
      trailing: [if (cap != null) Text('$cap', style: monoStyle(context, size: 11.5))],
    );
  }
}

class _VolumeRow extends StatelessWidget {
  final Json pv;
  const _VolumeRow(this.pv);

  @override
  Widget build(BuildContext context) {
    final name = dig<String>(pv, ['metadata', 'name']) ?? '';
    final phase = dig<String>(pv, ['status', 'phase']) ?? 'Unknown';
    final cap = dig<dynamic>(pv, ['spec', 'capacity', 'storage']);
    final claim = asMap(dig(pv, ['spec', 'claimRef']));
    final sev = _phaseSeverity(phase);
    final bad = sev == Severity.warn || sev == Severity.error;
    return InspectorRow(
      dot: sev,
      dotTooltip: phase,
      title: ResourceLink(pvRef(name), label: name, singleLine: true),
      subtitle: Text.rich(TextSpan(children: [
        TextSpan(text: phase, style: bad ? TextStyle(color: severityColor(context, sev), fontWeight: FontWeight.w600) : null),
        if (claim['name'] != null) TextSpan(text: '  ·  bound to ${claim['namespace'] ?? ''}/${claim['name']}'),
      ])),
      trailing: [if (cap != null) Text('$cap', style: monoStyle(context, size: 11.5))],
    );
  }
}
