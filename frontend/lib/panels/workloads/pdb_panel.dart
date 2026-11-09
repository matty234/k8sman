import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/detail/owner_line.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'widgets/pods_list.dart';
import 'widgets/sections.dart';
import 'widgets/status_header.dart';
import 'widgets/util.dart';

class PdbPanel extends ResourcePanel {
  const PdbPanel();

  @override
  bool get ownerInHeader => true;

  @override
  Set<String> get kinds => const {'policy/PodDisruptionBudget'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final st = ctx.status;
    final allowed = asInt(st['disruptionsAllowed']);
    final currentHealthy = asInt(st['currentHealthy']) ?? 0;
    final desiredHealthy = asInt(st['desiredHealthy']) ?? 0;
    final expected = asInt(st['expectedPods']) ?? 0;
    final disrupted = asMap(st['disruptedPods']);
    final (headline, sev) = allowed == null
        ? ('No status yet', Severity.neutral)
        : allowed == 0
        ? ('Blocks voluntary evictions', Severity.warn)
        : ('Allows $allowed disruption${allowed == 1 ? '' : 's'}', Severity.ok);
    final budget = spec['minAvailable'] != null
        ? 'minAvailable ${spec['minAvailable']}'
        : spec['maxUnavailable'] != null
        ? 'maxUnavailable ${spec['maxUnavailable']}'
        : 'none (minAvailable 1 implied)';

    return [
      WorkloadStatusHeader(
        headline: headline,
        severity: sev,
        detail: budget,
        figures: [
          WorkloadFigure(allowed == null ? '—' : '$allowed', 'allowed', severity: allowed == 0 ? Severity.warn : Severity.neutral, tooltip: 'disruptions allowed now'),
          WorkloadFigure('$currentHealthy', 'healthy', of: '/$desiredHealthy', severity: currentHealthy < desiredHealthy ? Severity.error : Severity.neutral, tooltip: 'current / desired healthy'),
          WorkloadFigure('$expected', 'expected', tooltip: 'expected pods'),
        ],
        insights: [
          if (allowed == 0)
            const WorkloadInsight(
              Severity.warn,
              '0 disruptions allowed',
              detail: 'kubectl drain and node upgrades will hang on these pods until more are healthy.',
            ),
        ],
        facts: [
          ?ownerFact(ctx.object),
          ('Budget', budget),
          ('Unhealthy', spec['unhealthyPodEvictionPolicy'] as String? ?? 'IfHealthyBudget (default)'),
          if (disrupted.isNotEmpty)
            (
              'Evicting',
              Wrap(spacing: 8, children: [
                for (final n in disrupted.keys) ResourceLink(ObjectRef(kind: 'Pod', name: n, namespace: ctx.namespace), label: n),
              ]),
            ),
        ],
      ),
      PodsList(
        key: ValueKey('pods-${ctx.uid}'),
        api: ctx.api,
        namespace: ctx.namespace,
        selector: spec['selector'],
        refreshKey: workloadRefreshKey(ctx),
        actionCtx: ctx,
        sectionTitle: 'Matched pods',
      ),
      conditionsSection(context, st),
      selectorSection(spec['selector'], extra: [('Observed gen', st['observedGeneration'] == null ? null : '${st['observedGeneration']}')]),
    ];
  }
}
