import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../argocd/argo_common.dart' show Hint;
import '../panel.dart';
import 'wf_actions.dart';
import 'wf_common.dart';
import 'wf_graph.dart';
import 'wf_graph_view.dart';
import 'wf_spec.dart';
import '../../ui/inspector/inspector.dart' show Callout;

/// argoproj.io Workflow: status header, failed steps, parameters, the node
/// graph with per-step details and logs, and the spec.
class WorkflowPanel extends ResourcePanel {
  const WorkflowPanel();

  @override
  Set<String> get kinds => {'argoproj.io/Workflow'};

  @override
  List<ResourceAction> actions(PanelContext ctx) {
    // Warm the argo-server status so Retry hides when it isn't usable.
    ArgoWFApi.of(ctx.api).status(ctx.app.currentContext);
    return workflowActions(ctx);
  }

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final stored = asMap(dig(ctx.status, ['storedWorkflowTemplateSpec']));
    final templates = asMapList(ctx.spec['templates']).isNotEmpty ? asMapList(ctx.spec['templates']) : asMapList(stored['templates']);
    final conds = ctx.status['conditions'];
    return [
      DetailSection(title: 'Workflow', icon: Icons.account_tree_outlined, card: true, child: WorkflowSummary(ctx)),
      DetailSection(title: 'Parameters', icon: Icons.tune, child: WorkflowParams(ctx.object)),
      DetailSection(
        title: 'Steps',
        icon: Icons.schema_outlined,
        child: WorkflowNodesView(key: ValueKey('nodes-${ctx.uid}'), workflow: ctx.object, api: ctx.api),
      ),
      if (conds is List && conds.isNotEmpty) DetailSection(title: 'Conditions', icon: Icons.checklist, child: ConditionsTable(conds)),
      DetailSection(
        title: 'Spec',
        icon: Icons.description_outlined,
        initiallyExpanded: false,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SpecSummary({...stored, ...ctx.spec}, namespace: ctx.namespace),
          if (templates.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text('Templates', style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).hintColor)),
            const SizedBox(height: 4),
            TemplateList(templates, entrypoint: (ctx.spec['entrypoint'] ?? stored['entrypoint']) as String?),
          ],
        ]),
      ),
    ];
  }
}

/// Phase, progress, timing, origin, and what went wrong.
class WorkflowSummary extends StatelessWidget {
  final PanelContext ctx;
  const WorkflowSummary(this.ctx, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final wf = ctx.object;
    final status = ctx.status;
    final phase = workflowPhase(wf);
    final progress = '${status['progress'] ?? ''}';
    final m = RegExp(r'^(\d+)/(\d+)$').firstMatch(progress);
    final done = m == null ? 0 : int.parse(m.group(1)!);
    final total = m == null ? 0 : int.parse(m.group(2)!);
    final dur = runDuration(status['startedAt'], status['finishedAt']);
    final msg = status['message'] as String?;
    final labels = asMap(ctx.metadata['labels']);
    final tref = asMap(ctx.spec['workflowTemplateRef']);
    final cron = labels[labelCronWorkflow] as String?;
    final from = labels[labelResubmittedFrom] as String?;
    final nodes = parseNodes(wf);
    final waiting = nodes.values.where((n) => n.isWaiting).toList();
    final shutdown = ctx.spec['shutdown'] as String?;
    final s = wfPhaseStyle(context, phase);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        PhaseBadge(phase, large: true),
        const SizedBox(width: 12),
        if (total > 0) ...[
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(value: done / total, minHeight: 6, color: s.color, backgroundColor: s.color.withValues(alpha: 0.15)),
              ),
              const SizedBox(height: 3),
              Text('$done of $total steps', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ]),
          ),
        ] else
          const Spacer(),
        const SizedBox(width: 12),
        if (dur != null)
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(formatDuration(dur, style: DurationStyle.padded), style: monoStyle(context, size: 14).copyWith(fontWeight: FontWeight.w600)),
            Text(status['finishedAt'] == null ? 'running' : 'duration', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ]),
      ]),
      const SizedBox(height: 10),
      if (shutdown != null && !workflowCompleted(wf))
        Callout(severity: Severity.warn, icon: Icons.stop_circle_outlined, title: 'Shutting down: spec.shutdown is $shutdown.'),
      for (final n in waiting)
        Callout(
          severity: Severity.warn,
          icon: Icons.pause_circle_outline,
          title: 'Waiting at ${n.displayName}',
          body: n.message ?? 'A suspend step is waiting to be resumed (approved).',
          action: ctx.app.readOnly
              ? null
              : ActionButton(ctx,
                  action: 'argowf-resume',
                  label: 'Resume',
                  icon: Icons.play_arrow,
                  title: 'Resume workflow ${ctx.name}?',
                  message: 'Marks the waiting suspend step${waiting.length > 1 ? 's' : ''} as succeeded so the workflow continues.'),
        ),
      if (msg != null && msg.isNotEmpty)
        Callout(
          severity: phase == 'Failed' || phase == 'Error' ? Severity.error : Severity.info,
          icon: phase == 'Failed' || phase == 'Error' ? Icons.error_outline : Icons.info_outline,
          title: msg,
        ),
      FailedSteps(workflow: wf, nodes: nodes, uid: ctx.uid, api: ctx.api),
      if ((phase == 'Failed' || phase == 'Error') && !ctx.app.readOnly)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: FutureBuilder<ArgoWFStatus>(
            future: ArgoWFApi.of(ctx.api).status(ctx.app.currentContext),
            builder: (context, snap) => snap.hasData ? ArgoServerLine(snap.data!) : const SizedBox.shrink(),
          ),
        ),
      KeyValueTable([
        (
          'From',
          tref.isNotEmpty
              ? ResourceLink(
                  ObjectRef(
                    group: wfGroup,
                    kind: tref['clusterScope'] == true ? 'ClusterWorkflowTemplate' : 'WorkflowTemplate',
                    name: '${tref['name']}',
                    namespace: tref['clusterScope'] == true ? null : ctx.namespace,
                  ),
                  label: '${tref['clusterScope'] == true ? 'ClusterWorkflowTemplate' : 'WorkflowTemplate'} ${tref['name']}',
                )
              : null,
        ),
        ('Scheduled by', cron == null ? null : ResourceLink(ObjectRef(group: wfGroup, kind: 'CronWorkflow', name: cron, namespace: ctx.namespace), label: 'CronWorkflow $cron')),
        ('Resubmitted from', from == null ? null : ResourceLink(ObjectRef(group: wfGroup, kind: 'Workflow', name: from, namespace: ctx.namespace), label: from)),
        ('Started', status['startedAt'] == null ? null : formatLocalTime(parseTime(status['startedAt']))),
        ('Finished', status['finishedAt'] == null ? null : formatLocalTime(parseTime(status['finishedAt']))),
        ('Estimated', status['estimatedDuration'] is num && status['finishedAt'] == null ? formatDuration(Duration(seconds: (status['estimatedDuration'] as num).toInt()), style: DurationStyle.padded) : null),
        ('Resources', formatResourcesDuration(status['resourcesDuration'])),
        ('Creator', labels[labelCreator] as String? ?? dig<String>(ctx.metadata, ['annotations', 'workflows.argoproj.io/creator'])),
        ('Archived', labels['workflows.argoproj.io/workflow-archiving-status'] as String?),
        ('Pod names', dig<String>(ctx.metadata, ['annotations', annotationPodNameFormat])),
      ], keyWidth: 120),
    ]);
  }
}

/// Failed leaf steps (pods, retries, suspends): what failed and why, with
/// links into the graph and their logs.
class FailedSteps extends StatelessWidget {
  final Json workflow;
  final Map<String, WfNode> nodes;
  final String uid;
  const FailedSteps({super.key, required this.workflow, required this.nodes, required this.uid, required this.api});
  final ApiClient api;

  @override
  Widget build(BuildContext context) {
    final attempts = {for (final n in nodes.values.where((n) => n.isRetry)) ...retryAttempts(n, nodes).map((a) => a.id)};
    final failed = nodes.values.where((n) => n.failed && !n.isContainer && !n.isJunction && !attempts.contains(n.id)).toList()
      ..sort((a, b) => (a.finishedAt ?? DateTime(0)).compareTo(b.finishedAt ?? DateTime(0)));
    if (failed.isEmpty) return const SizedBox.shrink();
    final shown = failed.take(6).toList();
    return Callout(
      severity: Severity.error,
      title: '${failed.length} failed step${failed.length == 1 ? '' : 's'}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        for (final n in shown) _row(context, n),
        if (failed.length > shown.length) Hint('… and ${failed.length - shown.length} more (see Steps)'),
      ]),
    );
  }

  Widget _row(BuildContext context, WfNode n) {
    final theme = Theme.of(context);
    final pod = podNodeFor(n, nodes);
    final exit = pod.exitCode;
    final msg = pod.message ?? n.message;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: PhaseBadge(n.phase, iconOnly: true)),
        const SizedBox(width: 6),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Hoverable(
              onTap: () => WorkflowSelection.of(uid).value = n.id,
              builder: (h) => Text(n.displayName,
                  style: theme.textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: theme.colorScheme.primary,
                    decoration: h ? TextDecoration.underline : null,
                    decorationColor: theme.colorScheme.primary,
                  )),
            ),
            if (msg != null || exit != null)
              Text([?msg, if (exit != null && !(msg ?? '').contains('exit code')) 'exit code $exit'].join(' · '),
                  maxLines: 3, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall),
          ]),
        ),
        if (pod.isPod)
          IconButton(
            tooltip: 'Logs',
            visualDensity: VisualDensity.compact,
            iconSize: 15,
            icon: const Icon(Icons.notes),
            onPressed: () => openNodeLogs(context, api, workflow, pod),
          ),
      ]),
    );
  }
}

/// Arguments the workflow runs with: its own, then the template's
/// defaults it didn't override.
class WorkflowParams extends StatelessWidget {
  final Json workflow;
  const WorkflowParams(this.workflow, {super.key});

  @override
  Widget build(BuildContext context) {
    final own = asMapList(dig(workflow, ['spec', 'arguments', 'parameters']));
    final names = {for (final p in own) p['name']};
    final defaults = [
      for (final p in asMapList(dig(workflow, ['status', 'storedWorkflowTemplateSpec', 'arguments', 'parameters'])))
        if (!names.contains(p['name'])) p,
    ];
    final artifacts = [
      ...asMapList(dig(workflow, ['spec', 'arguments', 'artifacts'])),
    ];
    if (own.isEmpty && defaults.isEmpty && artifacts.isEmpty) return const Hint('No parameters');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ParamTable([...own, ...defaults], defaulted: {for (final p in defaults) '${p['name']}'}),
      if (artifacts.isNotEmpty) ...[
        const SizedBox(height: 6),
        KeyValueTable([for (final a in artifacts) ('artifact ${a['name']}', artifactLocation(a))], keyWidth: 150),
      ],
    ]);
  }
}
