import 'package:flutter/material.dart';
import '../../ui/security/security_tab.dart' show SecurityInsight, securityTab;

import '../../api/models.dart';
import '../../metrics/workload_usage.dart';
import '../../prometheus/metric_history_chart.dart';
import '../../ui/inspector/inspector.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../actions/actions.dart';
import '../../ui/logs/open_logs.dart';
import '../../ui/terminal/open_terminal.dart';
import '../panel.dart';
import 'rollout.dart' show WorkloadHeadline;
import 'widgets/pods_list.dart';
import 'widgets/sections.dart';
import 'widgets/status_header.dart';
import 'widgets/util.dart';

(String, Severity) daemonSetStatus(Json ds) {
  final st = asMap(ds['status']);
  final desired = asIntOrNull(st['desiredNumberScheduled']) ?? 0;
  final ready = asIntOrNull(st['numberReady']) ?? 0;
  final updated = asIntOrNull(st['updatedNumberScheduled']) ?? 0;
  final mis = asIntOrNull(st['numberMisscheduled']) ?? 0;
  final gen = asIntOrNull(dig(ds, ['metadata', 'generation'])) ?? 0;
  final observed = asIntOrNull(st['observedGeneration']) ?? 0;
  if (gen > observed) return ('Waiting for controller', Severity.warn);
  if (desired == 0) return ('No eligible nodes', Severity.warn);
  if (updated < desired) return ('Rolling: $updated of $desired nodes updated', Severity.warn);
  if (ready < desired) return ('$ready of $desired ready', ready == 0 ? Severity.error : Severity.warn);
  if (mis > 0) return ('$mis misscheduled', Severity.warn);
  return ('Running on all $desired nodes', Severity.ok);
}

/// The status header's headline: "Ready on 3/3 nodes", "Rolling out"
/// (2/3 nodes updated), "No eligible nodes", …
WorkloadHeadline daemonSetHeadline(Json ds) {
  final st = asMap(ds['status']);
  final desired = asIntOrNull(st['desiredNumberScheduled']) ?? 0;
  final ready = asIntOrNull(st['numberReady']) ?? 0;
  final updated = asIntOrNull(st['updatedNumberScheduled']) ?? 0;
  final mis = asIntOrNull(st['numberMisscheduled']) ?? 0;
  final (text, sev) = daemonSetStatus(ds);
  if (text.startsWith('Rolling')) {
    return WorkloadHeadline('Rolling out', Severity.info, detail: '$updated/$desired nodes updated', progress: desired == 0 ? null : updated / desired);
  }
  if (sev == Severity.ok) return WorkloadHeadline('Ready on $ready/$desired nodes', Severity.ok, detail: 'Up to date on every eligible node');
  if (text.endsWith('ready')) return WorkloadHeadline('Ready on $ready/$desired nodes', sev, detail: '${desired - ready} not ready');
  if (text.endsWith('misscheduled')) return WorkloadHeadline('Ready on $ready/$desired nodes', Severity.warn, detail: '$mis misscheduled');
  if (text == 'No eligible nodes') return WorkloadHeadline(text, sev, detail: 'No node matches its node selector, affinity and tolerations');
  return WorkloadHeadline(text, sev);
}

class DaemonSetPanel extends ResourcePanel {
  const DaemonSetPanel();

  @override
  bool get showsOwned => true;

  @override
  bool get ownerInHeader => true;

  @override
  Set<String> get kinds => const {'apps/DaemonSet'};

  @override
  List<PanelTab> tabs(PanelContext ctx) => [securityTab(ctx)];

  @override
  List<ResourceAction> actions(PanelContext ctx) => [workloadLogsAction(ctx), workloadTerminalAction(ctx)];

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final st = ctx.status;
    final head = daemonSetHeadline(ctx.object);
    final strat = asMap(spec['updateStrategy']);
    final ru = asMap(strat['rollingUpdate']);
    final onDelete = strat['type'] == 'OnDelete';
    final podSpec = asMap(dig(spec, ['template', 'spec']));
    final desired = asIntOrNull(st['desiredNumberScheduled']) ?? 0;
    final ready = asIntOrNull(st['numberReady']) ?? 0;
    final updated = asIntOrNull(st['updatedNumberScheduled']) ?? 0;
    final available = asIntOrNull(st['numberAvailable']) ?? 0;
    final unavailable = asIntOrNull(st['numberUnavailable']) ?? (desired - available).clamp(0, desired);
    final mis = asIntOrNull(st['numberMisscheduled']) ?? 0;
    return [
      CoreSection('status', InspectorHeader(
        extraInsights: [SecurityInsight(ctx)],
        headline: head.text,
        mark: head.severity,
        detail: head.detail,
        progress: head.progress == null ? null : InspectorProgress(head.progress!, tooltip: '$updated of $desired nodes run the latest pod template'),
        figures: [
          InspectorFigure.count(ready, desired, 'ready', zeroIsError: true),
          InspectorFigure('$updated', 'updated', of: '/$desired', tooltip: 'on the latest pod template'),
          InspectorFigure.count(available, desired, 'available', zeroIsError: true),
          InspectorFigure('$unavailable', 'unavailable', severity: unavailable > 0 ? Severity.warn : Severity.neutral),
        ],
        insights: [
          if (mis > 0) Insight(Severity.warn, '$mis misscheduled', 'Running on nodes the DaemonSet should not run on (taints or node selector changed).'),
          ...conditionInsights(asMapList(st['conditions'])),
        ],
        facts: [?ownerFact(ctx.object)],
      )),
      CoreSection('pods', PodsList(
        key: ValueKey('pods-${ctx.uid}'),
        api: ctx.api,
        namespace: ctx.namespace,
        selector: spec['selector'],
        ownerUid: ctx.uid,
        refreshKey: workloadRefreshKey(ctx),
        actionCtx: ctx,
        sectionTitle: 'Pods',
      )),
      CoreSection('usage', workloadUsageSection(ctx)),
      CoreSection('history', workloadHistory(ctx)),
      CoreSection('strategy', workloadSection(
        'strategy',
        'Strategy',
        onDelete ? 'OnDelete' : 'RollingUpdate · ${ru['maxUnavailable'] ?? 1} unavailable · ${ru['maxSurge'] ?? 0} surge',
        KeyValueTable([
          (
            'Update strategy',
            onDelete ? 'OnDelete (pods update only when deleted)' : 'RollingUpdate · maxUnavailable ${ru['maxUnavailable'] ?? 1} · maxSurge ${ru['maxSurge'] ?? 0}',
          ),
          if (spec['minReadySeconds'] != null) ('Min ready', '${spec['minReadySeconds']}s'),
          ('History limit', '${spec['revisionHistoryLimit'] ?? 10} revisions'),
        ], keyWidth: 120),
      )),
      CoreSection('scheduling', schedulingSection(podSpec, emptyText: 'No nodeSelector, tolerations or affinity: runs on every schedulable node without taints', none: 'every node')),
      CoreSection('pod-template', podTemplateSection(asMap(spec['template']), ctx.namespace, uid: ctx.uid)),
      if (asMapList(st['conditions']).isNotEmpty) CoreSection('conditions', conditionsSection(context, st)),
      CoreSection('selector', selectorSection(spec['selector'])),
    ];
  }
}
