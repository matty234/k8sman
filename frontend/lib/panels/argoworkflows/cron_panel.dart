import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../argocd/argo_common.dart' show Hint;
import '../batch/batch_common.dart' show batchNow, formatRelative, formatSeconds, formatWall;
import '../batch/cron.dart';
import '../panel.dart';
import 'wf_actions.dart';
import 'wf_common.dart';
import 'wf_spec.dart';
import '../../ui/inspector/inspector.dart' show Callout;

/// argoproj.io CronWorkflow: schedules with next runs, policy, active and
/// recent workflows, and the workflow it runs.
class CronWorkflowPanel extends ResourcePanel {
  const CronWorkflowPanel();

  @override
  Set<String> get kinds => {'argoproj.io/CronWorkflow'};

  @override
  List<ResourceAction> actions(PanelContext ctx) => cronWorkflowActions(ctx);

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final wfSpec = asMap(ctx.spec['workflowSpec']);
    final conds = ctx.status['conditions'];
    final active = asMapList(ctx.status['active']);
    return [
      DetailSection(title: 'Schedule', icon: Icons.schedule, card: true, child: CronWorkflowSchedule(ctx.object)),
      DetailSection(title: 'Status & policy', icon: Icons.tune, child: _CronStatus(ctx.object)),
      if (conds is List && conds.isNotEmpty) DetailSection(title: 'Conditions', icon: Icons.checklist, child: ConditionsTable(conds)),
      DetailSection(
        title: 'Workflows',
        icon: Icons.history,
        child: RelatedWorkflows(
          key: ValueKey('cron-${ctx.uid}'),
          api: ctx.api,
          // Refetch when a run starts or ends.
          signature: '${ctx.status['lastScheduledTime']}/${active.map((a) => a['name']).join(',')}/${ctx.status['succeeded']}/${ctx.status['failed']}',
          fetch: (api) => api.items(workflowsRef, namespace: ctx.namespace, labelSelector: '$labelCronWorkflow=${ctx.name}'),
          empty: 'No workflows from this CronWorkflow (history limits: ${ctx.spec['successfulJobsHistoryLimit'] ?? 3} succeeded, ${ctx.spec['failedJobsHistoryLimit'] ?? 1} failed)',
        ),
      ),
      DetailSection(
        title: 'Workflow spec',
        icon: Icons.description_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (wfSpec['workflowTemplateRef'] != null)
            KeyValueTable([
              (
                'Template',
                ResourceLink(
                  ObjectRef(
                    group: wfGroup,
                    kind: dig(wfSpec, ['workflowTemplateRef', 'clusterScope']) == true ? 'ClusterWorkflowTemplate' : 'WorkflowTemplate',
                    name: '${dig(wfSpec, ['workflowTemplateRef', 'name'])}',
                    namespace: dig(wfSpec, ['workflowTemplateRef', 'clusterScope']) == true ? null : ctx.namespace,
                  ),
                  label: '${dig(wfSpec, ['workflowTemplateRef', 'name'])}',
                ),
              ),
            ], keyWidth: 120),
          SpecSummary(wfSpec, namespace: ctx.namespace),
          if (asMapList(dig(wfSpec, ['arguments', 'parameters'])).isNotEmpty) ...[
            _label(context, 'Parameters'),
            DeclaredParams(asMapList(dig(wfSpec, ['arguments', 'parameters']))),
          ],
          if (asMapList(wfSpec['templates']).isNotEmpty) ...[
            _label(context, 'Templates'),
            TemplateList(asMapList(wfSpec['templates']), entrypoint: wfSpec['entrypoint'] as String?),
          ],
        ]),
      ),
    ];
  }
}

Widget _label(BuildContext context, String s) => Padding(
      padding: const EdgeInsets.only(top: 10, bottom: 4),
      child: Text(s, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).hintColor)),
    );

/// CronWorkflow schedules: `spec.schedules` (v3.6+) or `spec.schedule`.
List<String> cronSchedules(Json spec) => [
      for (final s in (spec['schedules'] as List? ?? const [])) '$s',
      if (spec['schedule'] is String && (spec['schedule'] as String).isNotEmpty) spec['schedule'] as String,
    ];

/// Each schedule with its description, the time zone, and the next runs
/// of all schedules merged.
class CronWorkflowSchedule extends StatelessWidget {
  final Json cron;
  const CronWorkflowSchedule(this.cron, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = batchNow();
    final spec = asMap(cron['spec']);
    final suspended = spec['suspend'] == true;
    final exprs = cronSchedules(spec);
    final tzName = (spec['timezone'] as String?)?.isNotEmpty == true ? spec['timezone'] as String : null;
    final parsed = [for (final e in exprs) (e, CronSchedule.tryParse(e))];
    final zoneName = tzName ?? parsed.map((p) => p.$2?.timeZone).whereType<String>().firstOrNull;
    final zone = resolveZone(zoneName);
    final z = zone ?? ZoneRules.utc;
    final runs = <(DateTime, String)>[
      for (final (e, s) in parsed)
        if (s != null)
          for (final r in s.nextRuns(now, count: 5, zone: resolveZone(s.timeZone ?? zoneName) ?? z)) (r, e),
    ]..sort((a, b) => a.$1.compareTo(b.$1));
    final next = <(DateTime, String)>[];
    for (final r in runs) {
      if (next.isEmpty || next.last.$1 != r.$1) next.add(r);
      if (next.length == 6) break;
    }
    String zoneLabel;
    if (zoneName == null) {
      zoneLabel = 'controller local time (no spec.timezone; usually UTC)';
    } else if (zone == null) {
      zoneLabel = '$zoneName (unknown here; showing UTC)';
    } else {
      final off = z.offsetAt(now.toUtc());
      final sign = off.isNegative ? '-' : '+';
      final h = off.abs().inHours, m = off.abs().inMinutes % 60;
      zoneLabel = '$zoneName (${z.abbreviationAt(now.toUtc())}, UTC$sign${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')})';
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (suspended)
        const Callout(
          severity: Severity.warn,
          icon: Icons.pause_circle_outline,
          title: 'Suspended: no new workflows are scheduled',
          body: 'spec.suspend is true. Running workflows are not affected.',
        ),
      if (exprs.isEmpty) const InlineMessage('No schedule'),
      for (final (e, s) in parsed)
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Chipish(text: e, copyValue: e),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                _capital(describeCron(e) ?? (s == null ? 'Unrecognised schedule' : e)),
                style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: suspended ? theme.hintColor : null),
              ),
            ),
          ]),
        ),
      const SizedBox(height: 2),
      Row(children: [
        Icon(Icons.public, size: 13, color: theme.hintColor),
        const SizedBox(width: 4),
        Expanded(child: Hint('Time zone: $zoneLabel')),
      ]),
      if (spec['when'] != null) ...[
        const SizedBox(height: 4),
        Row(children: [
          Icon(Icons.rule, size: 13, color: theme.hintColor),
          const SizedBox(width: 4),
          Expanded(child: Text.rich(TextSpan(style: theme.textTheme.bodySmall, children: [
            TextSpan(text: 'Only when ', style: TextStyle(color: theme.hintColor)),
            TextSpan(text: '${spec['when']}', style: monoStyle(context, size: 11.5)),
          ]))),
        ]),
      ],
      if (dig(spec, ['stopStrategy', 'expression']) != null || dig(spec, ['stopStrategy', 'condition']) != null) ...[
        const SizedBox(height: 4),
        Row(children: [
          Icon(Icons.stop_circle_outlined, size: 13, color: theme.hintColor),
          const SizedBox(width: 4),
          Expanded(child: Text.rich(TextSpan(style: theme.textTheme.bodySmall, children: [
            TextSpan(text: 'Stops when ', style: TextStyle(color: theme.hintColor)),
            TextSpan(text: '${dig(spec, ['stopStrategy', 'expression']) ?? dig(spec, ['stopStrategy', 'condition'])}', style: monoStyle(context, size: 11.5)),
          ]))),
        ]),
      ],
      const SizedBox(height: 10),
      Text(suspended ? 'Next runs (if resumed)' : 'Next runs', style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor)),
      const SizedBox(height: 4),
      if (next.isEmpty)
        const InlineMessage('Cannot compute run times for this schedule.')
      else
        for (final (i, (r, e)) in next.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Opacity(
              opacity: suspended ? 0.5 : 1,
              child: Row(children: [
                SizedBox(
                  width: 18,
                  child: Icon(i == 0 ? Icons.arrow_right : Icons.circle, size: i == 0 ? 16 : 5, color: i == 0 ? theme.colorScheme.primary : theme.hintColor),
                ),
                Text('${formatWall(z.toWall(r))} ${z.abbreviationAt(r)}', style: monoStyle(context, size: 12, color: i == 0 ? null : theme.colorScheme.onSurfaceVariant)),
                const SizedBox(width: 10),
                Text(formatRelative(r, now: now),
                    style: theme.textTheme.bodySmall?.copyWith(color: i == 0 ? theme.colorScheme.primary : theme.hintColor, fontWeight: i == 0 ? FontWeight.w600 : null)),
                if (exprs.length > 1) ...[
                  const Spacer(),
                  Text(e, style: monoStyle(context, size: 11, color: theme.hintColor)),
                ],
              ]),
            ),
          ),
    ]);
  }
}

String _capital(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';

class _CronStatus extends StatelessWidget {
  final Json cron;
  const _CronStatus(this.cron);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = batchNow();
    final spec = asMap(cron['spec']);
    final status = asMap(cron['status']);
    final ns = dig<String>(cron, ['metadata', 'namespace']);
    final active = asMapList(status['active']);
    final last = parseTime(status['lastScheduledTime']);
    final policy = '${spec['concurrencyPolicy'] ?? 'Allow'}';
    final policyHelp = switch (policy) {
      'Forbid' => 'skip a run while one is active',
      'Replace' => 'stop the active run and start the new one',
      _ => 'runs may overlap',
    };
    return KeyValueTable([
      ('Suspend', spec['suspend'] == true ? const Align(alignment: Alignment.centerLeft, child: StatusBadge('Suspended', severity: Severity.warn, dense: true)) : 'false'),
      if (status['phase'] != null) ('Phase', StatusBadge('${status['phase']}', dense: true, severity: status['phase'] == 'Stopped' ? Severity.warn : Severity.ok)),
      (
        'Active',
        active.isEmpty
            ? Text('none', style: TextStyle(color: theme.hintColor))
            : Wrap(spacing: 10, runSpacing: 2, children: [
                for (final a in active)
                  ResourceLink(ObjectRef(group: wfGroup, kind: 'Workflow', name: '${a['name']}', namespace: a['namespace'] as String? ?? ns), label: '${a['name']}'),
              ]),
      ),
      (
        'Last scheduled',
        last == null
            ? Text('never', style: TextStyle(color: theme.hintColor))
            : Wrap(spacing: 6, children: [Text(formatLocal(last)), Text('(${formatRelative(last, now: now)})', style: TextStyle(color: theme.hintColor))]),
      ),
      if (status['succeeded'] != null || status['failed'] != null) ('Runs', '${status['succeeded'] ?? 0} succeeded · ${status['failed'] ?? 0} failed'),
      (
        'Concurrency',
        Text.rich(TextSpan(style: theme.textTheme.bodySmall, children: [
          TextSpan(text: policy, style: const TextStyle(fontWeight: FontWeight.w600)),
          TextSpan(text: ' · $policyHelp', style: TextStyle(color: theme.hintColor)),
        ])),
      ),
      ('Starting deadline', spec['startingDeadlineSeconds'] is num ? formatSeconds((spec['startingDeadlineSeconds'] as num).toInt()) : null),
      ('History limits', '${spec['successfulJobsHistoryLimit'] ?? 3} succeeded · ${spec['failedJobsHistoryLimit'] ?? 1} failed'),
    ], keyWidth: 120);
  }
}

/// Workflows fetched once (and again when [signature] changes or on
/// refresh), shown with [WorkflowList].
class RelatedWorkflows extends StatefulWidget {
  final ApiClient api;
  final Future<List<Json>> Function(ApiClient api) fetch;
  final String signature;
  final String empty;
  const RelatedWorkflows({super.key, required this.api, required this.fetch, this.signature = '', this.empty = 'No workflows'});

  @override
  State<RelatedWorkflows> createState() => _RelatedWorkflowsState();
}

class _RelatedWorkflowsState extends State<RelatedWorkflows> {
  late Future<List<Json>> _future = widget.fetch(widget.api);

  @override
  void didUpdateWidget(covariant RelatedWorkflows old) {
    super.didUpdateWidget(old);
    if (old.signature != widget.signature) _future = widget.fetch(widget.api);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Json>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError) return InlineMessage('${snap.error}', isError: true);
          if (!snap.hasData) {
            return const Padding(padding: EdgeInsets.all(8), child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))));
          }
          return Stack(children: [
            WorkflowList(snap.data!, empty: widget.empty),
            Positioned(
              right: 0,
              top: -6,
              child: IconButton(
                tooltip: 'Refresh',
                visualDensity: VisualDensity.compact,
                iconSize: 15,
                icon: const Icon(Icons.refresh),
                onPressed: () => setState(() => _future = widget.fetch(widget.api)),
              ),
            ),
          ]);
        },
      );
}
