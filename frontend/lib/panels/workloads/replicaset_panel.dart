import 'package:flutter/material.dart';

import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'rollout.dart';
import 'widgets/pod_template.dart';
import 'widgets/pods_list.dart';
import 'widgets/replica_bar.dart';
import 'widgets/util.dart';

class ReplicaSetPanel extends ResourcePanel {
  const ReplicaSetPanel();

  @override
  Set<String> get kinds => const {'apps/ReplicaSet'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final st = ctx.status;
    final owners = ownerRefs(ctx.object);
    final desired = asInt(spec['replicas']) ?? 1;
    final ready = asInt(st['readyReplicas']) ?? 0;
    final rev = dig<String>(ctx.metadata, ['annotations', revisionAnnotation]);
    final oldRevision = desired == 0 && owners.any((o) => o.kind == 'Deployment');
    final failure = asMapList(st['conditions']).where((c) => c['type'] == 'ReplicaFailure' && c['status'] == 'True').firstOrNull;
    final (headline, sev) = failure != null
        ? ('ReplicaFailure', Severity.error)
        : oldRevision
            ? ('Old revision (scaled to 0)', Severity.neutral)
            : ready >= desired
                ? ('Ready', Severity.ok)
                : ('$ready of $desired ready', ready == 0 ? Severity.error : Severity.warn);
    return [
      DetailSection(
        title: 'Replicas',
        icon: Icons.layers_outlined,
        trailing: StatusBadge(headline, severity: sev, dense: true),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ReplicaStatusBar(
            desired: desired,
            current: asInt(st['replicas']) ?? 0,
            ready: ready,
            available: asInt(st['availableReplicas']) ?? 0,
          ),
          const SizedBox(height: 10),
          KeyValueTable([
            (
              'Owner',
              owners.isEmpty
                  ? 'none (standalone ReplicaSet)'
                  : Wrap(spacing: 10, children: [for (final o in owners) ResourceLink(o)]),
            ),
            ('Revision', rev),
            ('Template hash', dig<String>(ctx.metadata, ['labels', 'pod-template-hash'])),
            ('Fully labeled', '${st['fullyLabeledReplicas'] ?? 0}'),
            if (spec['minReadySeconds'] != null) ('Min ready', '${spec['minReadySeconds']}s'),
            ('Selector', SelectorChips(spec['selector'])),
          ], keyWidth: 120),
        ]),
      ),
      if (asMapList(st['conditions']).isNotEmpty)
        DetailSection(title: 'Conditions', icon: Icons.checklist, child: ConditionsTable(st['conditions'] as List?)),
      DetailSection(
        title: 'Pods',
        icon: Icons.view_in_ar,
        child: PodsList(
          key: ValueKey('pods-${ctx.uid}'),
          api: ctx.api,
          namespace: ctx.namespace,
          selector: spec['selector'],
          ownerUid: ctx.uid,
          refreshKey: workloadRefreshKey(ctx),
        ),
      ),
      DetailSection(
        title: 'Pod template',
        icon: Icons.inventory_2_outlined,
        child: PodTemplateSummary(template: asMap(spec['template']), namespace: ctx.namespace),
      ),
    ];
  }
}
