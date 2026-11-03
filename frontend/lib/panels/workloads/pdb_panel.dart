import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'widgets/pods_list.dart';
import 'widgets/util.dart';

class PdbPanel extends ResourcePanel {
  const PdbPanel();

  @override
  Set<String> get kinds => const {'policy/PodDisruptionBudget'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final st = ctx.status;
    final theme = Theme.of(context);
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
    final healthySev = currentHealthy >= desiredHealthy ? Severity.ok : Severity.error;
    final budget = spec['minAvailable'] != null
        ? 'minAvailable ${spec['minAvailable']}'
        : spec['maxUnavailable'] != null
        ? 'maxUnavailable ${spec['maxUnavailable']}'
        : 'none (minAvailable 1 implied)';

    return [
      DetailSection(
        title: 'Budget',
        icon: Icons.shield_outlined,
        trailing: StatusBadge(headline, severity: sev, dense: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (allowed == 0)
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: severityColor(context, Severity.warn).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: severityColor(context, Severity.warn).withValues(alpha: 0.5)),
                ),
                child: Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, size: 18, color: severityColor(context, Severity.warn)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '0 disruptions allowed: blocks voluntary evictions. kubectl drain and node upgrades will hang on these pods.',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              children: [
                _Big('disruptions allowed', allowed == null ? '—' : '$allowed', allowed == 0 ? Severity.warn : Severity.ok),
                _Big('healthy', '$currentHealthy / $desiredHealthy', healthySev, hint: 'current / desired healthy'),
                _Big('expected pods', '$expected', Severity.neutral),
              ],
            ),
            const SizedBox(height: 10),
            KeyValueTable([
              ('Budget', budget),
              ('Unhealthy evict', spec['unhealthyPodEvictionPolicy'] as String? ?? 'IfHealthyBudget (default)'),
              ('Selector', SelectorChips(spec['selector'])),
              ('Observed gen', st['observedGeneration'] == null ? null : '${st['observedGeneration']}'),
              if (disrupted.isNotEmpty)
                (
                  'Being evicted',
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final n in disrupted.keys)
                        ResourceLink(
                          ObjectRef(kind: 'Pod', name: n, namespace: ctx.namespace),
                          label: n,
                        ),
                    ],
                  ),
                ),
            ], keyWidth: 120),
          ],
        ),
      ),
      DetailSection(title: 'Conditions', icon: Icons.checklist, child: ConditionsTable(st['conditions'] as List?)),
      DetailSection(
        title: 'Matched pods',
        icon: Icons.view_in_ar,
        child: PodsList(
          key: ValueKey('pods-${ctx.uid}'),
          api: ctx.api,
          namespace: ctx.namespace,
          selector: spec['selector'],
          refreshKey: workloadRefreshKey(ctx),
          actionCtx: ctx,
        ),
      ),
    ];
  }
}

class _Big extends StatelessWidget {
  final String label;
  final String value;
  final Severity sev;
  final String? hint;
  const _Big(this.label, this.value, this.sev, {this.hint});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final w = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
        Text(
          value,
          style: theme.textTheme.titleMedium?.copyWith(color: severityColor(context, sev), fontWeight: FontWeight.w700),
        ),
      ],
    );
    return Expanded(
      child: hint == null ? w : Tooltip(message: hint!, child: w),
    );
  }
}
