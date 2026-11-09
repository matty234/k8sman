import 'package:flutter/material.dart';

import '../../ui/inspector/inspector.dart';
import '../../util/k8s.dart';
import '../../actions/actions.dart';
import '../../ui/logs/open_logs.dart';
import '../panel.dart';
import 'rollout.dart';
import 'widgets/pods_list.dart';
import 'widgets/scaling.dart';
import 'widgets/sections.dart';
import 'widgets/status_header.dart';
import 'widgets/util.dart';

class ReplicaSetPanel extends ResourcePanel {
  const ReplicaSetPanel();

  @override
  bool get showsOwned => true;

  @override
  bool get ownerInHeader => true;

  @override
  Set<String> get kinds => const {'apps/ReplicaSet'};

  @override
  List<ResourceAction> actions(PanelContext ctx) => [workloadLogsAction(ctx)];

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final st = ctx.status;
    final owners = ownerRefs(ctx.object);
    final byDeployment = owners.any((o) => o.kind == 'Deployment');
    final desired = asInt(spec['replicas']) ?? 1;
    final ready = asInt(st['readyReplicas']) ?? 0;
    final available = asInt(st['availableReplicas']) ?? 0;
    final current = asInt(st['replicas']) ?? 0;
    final rev = dig<String>(ctx.metadata, ['annotations', revisionAnnotation]);
    final oldRevision = desired == 0 && byDeployment;
    final failure = asMapList(st['conditions']).where((c) => c['type'] == 'ReplicaFailure' && c['status'] == 'True').firstOrNull;
    final head = failure != null
        ? WorkloadHeadline('Replica failure', Severity.error, detail: failure['reason'] as String?)
        : oldRevision
        ? WorkloadHeadline('Old revision', Severity.neutral, detail: rev == null ? 'Scaled to 0 by its Deployment' : 'Revision $rev, scaled to 0 by its Deployment')
        : desired == 0
        ? const WorkloadHeadline('Scaled to 0', Severity.neutral)
        : ready >= desired
        ? WorkloadHeadline('Ready $ready/$desired', Severity.ok, detail: rev == null ? null : 'Revision $rev')
        : WorkloadHeadline('Ready $ready/$desired', ready == 0 ? Severity.error : Severity.warn, detail: '${desired - ready} not ready');
    return [
      InspectorHeader(
        headline: head.text,
        mark: head.severity,
        detail: head.detail,
        figures: [
          InspectorFigure.count(ready, desired, 'ready', zeroIsError: desired > 0),
          InspectorFigure.count(available, desired, 'available', zeroIsError: desired > 0),
          InspectorFigure('$current', 'pods', tooltip: 'pods that exist (status.replicas)'),
        ],
        insights: [
          ...conditionInsights(asMapList(st['conditions'])),
          if (byDeployment && !ctx.app.readOnly && !oldRevision)
            const Insight(Severity.neutral, 'Scaled by its Deployment', 'The Deployment resets manual scaling of this ReplicaSet.'),
        ],
        extraInsights: [HpaOverrideNote(ctx, key: ValueKey('hpa-${ctx.uid}'))],
        facts: [
          ('Owner', owners.isEmpty ? 'none (standalone ReplicaSet)' : OwnerLine(ctx.object)),
          replicasFact(ctx),
          ('Hash', dig<String>(ctx.metadata, ['labels', 'pod-template-hash'])),
        ],
      ),
      PodsList(
        key: ValueKey('pods-${ctx.uid}'),
        api: ctx.api,
        namespace: ctx.namespace,
        selector: spec['selector'],
        ownerUid: ctx.uid,
        refreshKey: workloadRefreshKey(ctx),
        actionCtx: ctx,
        sectionTitle: 'Pods',
      ),
      podTemplateSection(asMap(spec['template']), ctx.namespace),
      schedulingSection(asMap(dig(spec, ['template', 'spec']))),
      if (asMapList(st['conditions']).isNotEmpty) conditionsSection(context, st),
      selectorSection(spec['selector'], extra: [
        ('Fully labeled', '${st['fullyLabeledReplicas'] ?? 0}'),
        if (spec['minReadySeconds'] != null) ('Min ready', '${spec['minReadySeconds']}s'),
      ]),
    ];
  }
}
