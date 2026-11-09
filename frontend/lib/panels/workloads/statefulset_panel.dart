import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../metrics/workload_usage.dart';
import '../../prometheus/metric_history_chart.dart';
import '../../ui/inspector/inspector.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../actions/actions.dart';
import '../../ui/logs/open_logs.dart';
import '../../ui/terminal/open_terminal.dart';
import '../panel.dart';
import 'rollout.dart' show WorkloadHeadline;
import 'widgets/pods_list.dart';
import 'widgets/scaling.dart';
import 'widgets/sections.dart';
import 'widgets/status_header.dart';
import 'widgets/util.dart';

const pvcRef = ResourceRef(resource: 'persistentvolumeclaims');

/// Headline for a StatefulSet's update state.
(String, Severity) statefulSetStatus(Json sts) {
  final spec = asMap(sts['spec']);
  final st = asMap(sts['status']);
  final desired = asInt(spec['replicas']) ?? 1;
  final ready = asInt(st['readyReplicas']) ?? 0;
  final updated = asInt(st['updatedReplicas']) ?? 0;
  final gen = asInt(dig(sts, ['metadata', 'generation'])) ?? 0;
  final observed = asInt(st['observedGeneration']) ?? 0;
  final partition = asInt(dig(spec, ['updateStrategy', 'rollingUpdate', 'partition'])) ?? 0;
  final cur = st['currentRevision'], upd = st['updateRevision'];
  if (gen > observed) return ('Waiting for controller', Severity.warn);
  if (dig(spec, ['updateStrategy', 'type']) == 'OnDelete' && cur != upd) {
    return ('OnDelete: $updated of $desired updated', Severity.warn);
  }
  if (cur != null && upd != null && cur != upd) {
    final target = desired - partition;
    if (partition > 0 && updated >= target) return ('Partitioned: $updated of $desired updated', Severity.info);
    return ('Rolling update: $updated of $desired updated', Severity.warn);
  }
  if (ready < desired) return ('$ready of $desired ready', ready == 0 && desired > 0 ? Severity.error : Severity.warn);
  return ('Up to date', Severity.ok);
}

/// The status header's headline: "Ready 3/3", "Rolling out" (1/3
/// updated), "Partitioned", "Update pending" (OnDelete), …
WorkloadHeadline statefulSetHeadline(Json sts) {
  final spec = asMap(sts['spec']);
  final st = asMap(sts['status']);
  final desired = asInt(spec['replicas']) ?? 1;
  final ready = asInt(st['readyReplicas']) ?? 0;
  final updated = asInt(st['updatedReplicas']) ?? 0;
  final partition = asInt(dig(spec, ['updateStrategy', 'rollingUpdate', 'partition'])) ?? 0;
  final progress = desired == 0 ? null : (updated / desired).clamp(0.0, 1.0);
  final (text, sev) = statefulSetStatus(sts);
  if (text.startsWith('Waiting')) return WorkloadHeadline(text, sev);
  if (text.startsWith('OnDelete')) return WorkloadHeadline('Update pending', Severity.warn, detail: 'OnDelete: $updated/$desired updated; pods update when deleted', progress: progress);
  if (text.startsWith('Partitioned')) return WorkloadHeadline('Partitioned', Severity.info, detail: '$updated/$desired updated · ordinals ≥ $partition', progress: progress);
  if (text.startsWith('Rolling')) return WorkloadHeadline('Rolling out', Severity.info, detail: '$updated/$desired updated', progress: progress);
  if (desired == 0) return const WorkloadHeadline('Scaled to 0', Severity.neutral);
  if (sev == Severity.ok) return WorkloadHeadline('Ready $ready/$desired', Severity.ok, detail: 'Up to date');
  final n = desired - ready;
  return WorkloadHeadline('Ready $ready/$desired', sev, detail: '$n replica${n == 1 ? '' : 's'} not ready');
}

class StatefulSetPanel extends ResourcePanel {
  const StatefulSetPanel();

  @override
  bool get showsOwned => true;

  @override
  bool get ownerInHeader => true;

  @override
  Set<String> get kinds => const {'apps/StatefulSet'};

  @override
  List<ResourceAction> actions(PanelContext ctx) => [workloadLogsAction(ctx), workloadTerminalAction(ctx)];

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final st = ctx.status;
    final desired = asInt(spec['replicas']) ?? 1;
    final ready = asInt(st['readyReplicas']) ?? 0;
    final updated = asInt(st['updatedReplicas']) ?? 0;
    final available = asInt(st['availableReplicas']) ?? ready;
    final head = statefulSetHeadline(ctx.object);
    final strat = asMap(spec['updateStrategy']);
    final onDelete = strat['type'] == 'OnDelete';
    final partition = asInt(dig(strat, ['rollingUpdate', 'partition'])) ?? 0;
    final maxUnavail = dig(strat, ['rollingUpdate', 'maxUnavailable']);
    final retention = asMap(spec['persistentVolumeClaimRetentionPolicy']);
    final svc = spec['serviceName'] as String?;
    final cur = st['currentRevision'] as String?;
    final upd = st['updateRevision'] as String?;
    final templates = asMapList(spec['volumeClaimTemplates']);
    final ordStart = asInt(dig(spec, ['ordinals', 'start'])) ?? 0;
    final key = workloadRefreshKey(ctx);
    final theme = Theme.of(context);
    final parallel = spec['podManagementPolicy'] == 'Parallel';

    return [
      InspectorHeader(
        headline: head.text,
        mark: head.severity,
        detail: head.detail,
        progress: head.progress == null ? null : InspectorProgress(head.progress!, tooltip: '$updated of $desired replicas on the update revision'),
        figures: [
          InspectorFigure.count(ready, desired, 'ready', zeroIsError: true),
          InspectorFigure('$updated', 'updated', of: '/$desired', tooltip: 'on the update revision'),
          InspectorFigure.count(available, desired, 'available', zeroIsError: true),
        ],
        insights: conditionInsights(asMapList(st['conditions'])),
        extraInsights: [HpaOverrideNote(ctx, key: ValueKey('hpa-${ctx.uid}'))],
        facts: [
          ?ownerFact(ctx.object),
          replicasFact(ctx),
          ('Service', svc == null || svc.isEmpty ? null : ResourceLink(ObjectRef(kind: 'Service', name: svc, namespace: ctx.namespace), label: svc)),
        ],
      ),
      PodsList(
        key: ValueKey('pods-${ctx.uid}'),
        api: ctx.api,
        namespace: ctx.namespace,
        selector: spec['selector'],
        ownerUid: ctx.uid,
        refreshKey: key,
        sortByOrdinal: true,
        actionCtx: ctx,
        sectionTitle: 'Pods',
      ),
      workloadUsageSection(ctx),
      workloadHistory(ctx),
      if (templates.isNotEmpty)
        workloadSection(
          'claims',
          'Volume claims',
          [
            for (final t in templates)
              [
                '${dig(t, ['metadata', 'name'])}',
                ?dig(t, ['spec', 'resources', 'requests', 'storage'])?.toString(),
              ].join(' '),
            'per replica',
          ].join(' · '),
          StatefulSetClaims(
            key: ValueKey('pvc-${ctx.uid}'),
            api: ctx.api,
            namespace: ctx.namespace,
            stsName: ctx.name,
            templates: templates,
            replicas: desired,
            ordinalStart: ordStart,
            refreshKey: key,
          ),
        ),
      workloadSection(
        'strategy',
        'Strategy',
        [
          onDelete ? 'OnDelete' : 'RollingUpdate',
          if (partition > 0) 'partition $partition',
          parallel ? 'parallel' : 'ordered',
        ].join(' · '),
        KeyValueTable([
          (
            'Update strategy',
            onDelete ? 'OnDelete (pods update only when deleted)' : 'RollingUpdate${maxUnavail != null ? ' · maxUnavailable $maxUnavail' : ''}',
          ),
          (
            'Partition',
            partition > 0
                ? Text('$partition: only ordinals ≥ $partition get the new revision', style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.warn)))
                : (onDelete ? null : '0'),
          ),
          ('Pod management', parallel ? 'Parallel' : 'OrderedReady (one at a time, in order)'),
          ('Revisions', _Revisions(current: cur, update: upd)),
          if (retention.isNotEmpty)
            ('PVC retention', 'whenDeleted: ${retention['whenDeleted'] ?? 'Retain'} · whenScaled: ${retention['whenScaled'] ?? 'Retain'}')
          else
            ('PVC retention', 'Retain (default)'),
          if (spec['minReadySeconds'] != null) ('Min ready', '${spec['minReadySeconds']}s'),
          if (ordStart != 0) ('Ordinals start', '$ordStart'),
        ], keyWidth: 120),
      ),
      podTemplateSection(asMap(spec['template']), ctx.namespace, uid: ctx.uid),
      schedulingSection(asMap(dig(spec, ['template', 'spec']))),
      if (asMapList(st['conditions']).isNotEmpty) conditionsSection(context, st),
      selectorSection(spec['selector']),
    ];
  }
}

class _Revisions extends StatelessWidget {
  final String? current;
  final String? update;
  const _Revisions({required this.current, required this.update});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (current == null && update == null) return const HintText('—');
    if (current == update) {
      return Row(
        children: [
          Flexible(
            child: Text('$current', style: monoStyle(context, size: 11), overflow: TextOverflow.ellipsis),
          ),
          const SizedBox(width: 6),
          const StatusBadge('current = update', severity: Severity.ok, dense: true),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: 'current ',
                style: TextStyle(color: theme.hintColor),
              ),
              TextSpan(text: current ?? '?'),
            ],
          ),
          style: monoStyle(context, size: 11),
        ),
        Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: 'update  ',
                style: TextStyle(color: theme.hintColor),
              ),
              TextSpan(
                text: update ?? '?',
                style: TextStyle(color: severityColor(context, Severity.warn)),
              ),
            ],
          ),
          style: monoStyle(context, size: 11),
        ),
      ],
    );
  }
}

/// Volume claim templates and the actual PVCs `<template>-<sts>-<ordinal>`,
/// including leftover claims from ordinals beyond the current replica count.
class StatefulSetClaims extends StatefulWidget {
  final ApiClient api;
  final String? namespace;
  final String stsName;
  final List<Json> templates;
  final int replicas;
  final int ordinalStart;
  final String refreshKey;

  const StatefulSetClaims({
    super.key,
    required this.api,
    required this.namespace,
    required this.stsName,
    required this.templates,
    required this.replicas,
    required this.ordinalStart,
    required this.refreshKey,
  });

  @override
  State<StatefulSetClaims> createState() => _StatefulSetClaimsState();
}

class _StatefulSetClaimsState extends State<StatefulSetClaims> {
  late Future<Map<String, Json>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(StatefulSetClaims old) {
    super.didUpdateWidget(old);
    if (old.refreshKey != widget.refreshKey) _future = _load(); // build() follows didUpdateWidget
  }

  Future<Map<String, Json>> _load() async {
    final all = await widget.api.items(pvcRef, namespace: widget.namespace);
    return {
      for (final p in all) '${dig(p, ['metadata', 'name'])}': p,
    };
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final t in widget.templates) ...[
          _templateHeader(context, t),
          FutureBuilder<Map<String, Json>>(
            future: _future,
            builder: (context, snap) {
              final tname = '${dig(t, ['metadata', 'name'])}';
              final byName = snap.data ?? const <String, Json>{};
              final prefix = '$tname-${widget.stsName}-';
              final expected = [for (var i = 0; i < widget.replicas; i++) '$prefix${widget.ordinalStart + i}'];
              final extra = [
                for (final n in byName.keys)
                  if (n.startsWith(prefix) && int.tryParse(n.substring(prefix.length)) != null && !expected.contains(n)) n,
              ]..sort(naturalCompare);
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final n in expected) _claimRow(context, n, byName[n], loaded: snap.hasData),
                  for (final n in extra) _claimRow(context, n, byName[n], loaded: true, orphan: true),
                  if (snap.hasError) InlineMessage('${snap.error}', isError: true),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
        ],
        if (widget.templates.isEmpty) Text('No volumeClaimTemplates', style: theme.textTheme.bodySmall),
      ],
    );
  }

  Widget _templateHeader(BuildContext context, Json t) {
    final theme = Theme.of(context);
    final spec = asMap(t['spec']);
    final size = dig(spec, ['resources', 'requests', 'storage']);
    final modes = (spec['accessModes'] as List?)?.join(',');
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text('${dig(t, ['metadata', 'name'])}', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          if (size != null) Chipish(text: '$size'),
          if (modes != null) Chipish(text: modes),
          Text('class ${spec['storageClassName'] ?? '(default)'}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ],
      ),
    );
  }

  Widget _claimRow(BuildContext context, String name, Json? pvc, {required bool loaded, bool orphan = false}) {
    final theme = Theme.of(context);
    final phase = dig<String>(pvc, ['status', 'phase']);
    final cap = dig(pvc, ['status', 'capacity', 'storage']);
    final vol = dig<String>(pvc, ['spec', 'volumeName']);
    return Padding(
      padding: const EdgeInsets.only(left: 10, bottom: 3),
      child: Row(
        children: [
          Expanded(
            flex: 4,
            child: OneLineLink(ObjectRef(kind: 'PersistentVolumeClaim', name: name, namespace: widget.namespace)),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 130,
            child: Row(
              children: [
                if (!loaded)
                  const SizedBox.shrink()
                else if (pvc == null)
                  const StatusBadge('missing', severity: Severity.warn, dense: true)
                else
                  StatusBadge(phase ?? 'Unknown', dense: true),
                if (orphan) ...[
                  const SizedBox(width: 6),
                  const Tooltip(
                    message: 'Ordinal beyond current replicas: retained after scale-down',
                    child: StatusBadge('retained', severity: Severity.neutral, dense: true),
                  ),
                ],
              ],
            ),
          ),
          SizedBox(width: 56, child: Text(cap == null ? '' : '$cap', style: theme.textTheme.bodySmall)),
          Expanded(
            flex: 3,
            child: vol == null ? const SizedBox.shrink() : OneLineLink(ObjectRef(kind: 'PersistentVolume', name: vol)),
          ),
        ],
      ),
    );
  }
}
