import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../actions/actions.dart';
import '../../ui/logs/open_logs.dart';
import '../../ui/terminal/open_terminal.dart';
import '../panel.dart';
import 'widgets/pod_template.dart';
import 'widgets/pods_list.dart';
import 'widgets/replica_bar.dart';
import 'widgets/util.dart';

(String, Severity) daemonSetStatus(Json ds) {
  final st = asMap(ds['status']);
  final desired = asInt(st['desiredNumberScheduled']) ?? 0;
  final ready = asInt(st['numberReady']) ?? 0;
  final updated = asInt(st['updatedNumberScheduled']) ?? 0;
  final mis = asInt(st['numberMisscheduled']) ?? 0;
  final gen = asInt(dig(ds, ['metadata', 'generation'])) ?? 0;
  final observed = asInt(st['observedGeneration']) ?? 0;
  if (gen > observed) return ('Waiting for controller', Severity.warn);
  if (desired == 0) return ('No eligible nodes', Severity.warn);
  if (updated < desired) return ('Rolling: $updated of $desired nodes updated', Severity.warn);
  if (ready < desired) return ('$ready of $desired ready', ready == 0 ? Severity.error : Severity.warn);
  if (mis > 0) return ('$mis misscheduled', Severity.warn);
  return ('Running on all $desired nodes', Severity.ok);
}

class DaemonSetPanel extends ResourcePanel {
  const DaemonSetPanel();

  @override
  Set<String> get kinds => const {'apps/DaemonSet'};

  @override
  List<ResourceAction> actions(PanelContext ctx) => [workloadLogsAction(ctx), workloadTerminalAction(ctx)];

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final st = ctx.status;
    final (headline, sev) = daemonSetStatus(ctx.object);
    final strat = asMap(spec['updateStrategy']);
    final ru = asMap(strat['rollingUpdate']);
    final podSpec = asMap(dig(spec, ['template', 'spec']));
    final sched = PodTemplateSummary.schedulingEntries(podSpec);
    final desired = asInt(st['desiredNumberScheduled']) ?? 0;
    final ready = asInt(st['numberReady']) ?? 0;
    final available = asInt(st['numberAvailable']) ?? 0;
    return [
      DetailSection(
        title: 'Nodes',
        icon: Icons.dns_outlined,
        trailing: StatusBadge(headline, severity: sev, dense: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ReplicaStatusBar(
              desired: desired,
              current: asInt(st['currentNumberScheduled']) ?? 0,
              updated: asInt(st['updatedNumberScheduled']) ?? 0,
              ready: ready,
              available: available,
              unavailable: asInt(st['numberUnavailable']) ?? (desired - available).clamp(0, desired),
              extra: [('misscheduled', asInt(st['numberMisscheduled']) ?? 0, Severity.warn)],
              unit: 'pods',
            ),
            const SizedBox(height: 10),
            KeyValueTable([
              (
                'Update strategy',
                strat['type'] == 'OnDelete'
                    ? 'OnDelete (pods update only when deleted)'
                    : 'RollingUpdate · maxUnavailable ${ru['maxUnavailable'] ?? 1} · maxSurge ${ru['maxSurge'] ?? 0}',
              ),
              if (spec['minReadySeconds'] != null) ('Min ready', '${spec['minReadySeconds']}s'),
              ('History limit', '${spec['revisionHistoryLimit'] ?? 10} revisions'),
              ('Selector', SelectorChips(spec['selector'])),
            ], keyWidth: 120),
          ],
        ),
      ),
      DetailSection(
        title: 'Scheduling',
        icon: Icons.alt_route,
        child: sched.isEmpty
            ? const InlineMessage('No nodeSelector, tolerations or affinity: runs on every schedulable node without taints')
            : KeyValueTable(sched, keyWidth: 120),
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
          actionCtx: ctx,
        ),
      ),
      DetailSection(
        title: 'Pod template',
        icon: Icons.inventory_2_outlined,
        child: PodTemplateSummary(template: asMap(spec['template']), namespace: ctx.namespace, showScheduling: false),
      ),
    ];
  }
}
