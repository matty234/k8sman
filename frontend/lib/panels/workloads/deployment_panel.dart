import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../api/models.dart';
import '../../metrics/workload_usage.dart';
import '../../prometheus/metric_history_chart.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../ui/logs/open_logs.dart';
import '../../ui/terminal/open_terminal.dart';
import '../panel.dart';
import 'rollout.dart';
import 'widgets/pod_template.dart';
import 'widgets/pods_list.dart';
import 'widgets/replica_bar.dart';
import 'widgets/scaling.dart';
import 'widgets/util.dart';

class DeploymentPanel extends ResourcePanel {
  const DeploymentPanel();

  @override
  bool get showsOwned => true;

  @override
  Set<String> get kinds => const {'apps/Deployment'};

  @override
  List<ResourceAction> actions(PanelContext ctx) => [workloadLogsAction(ctx), workloadTerminalAction(ctx)];

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final st = ctx.status;
    final rollout = deriveRolloutStatus(ctx.object);
    final strategy = asMap(spec['strategy']);
    final ru = asMap(strategy['rollingUpdate']);
    final desired = asInt(spec['replicas']) ?? 1;
    final key = workloadRefreshKey(ctx);
    return [
      DetailSection(
        title: 'Rollout',
        icon: Icons.rocket_launch_outlined,
        trailing: StatusBadge(rollout.text, severity: rollout.severity, dense: true),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (spec['paused'] == true)
              Callout(
                severity: Severity.warn,
                icon: Icons.pause_circle_outline,
                action: ctx.app.readOnly
                    ? null
                    : ActionButton(
                        ctx,
                        action: 'resume',
                        label: 'Resume',
                        icon: Icons.play_arrow,
                        title: 'Resume rollout of ${ctx.name}?',
                        message: 'Pending pod template changes start rolling out.',
                      ),
                child: Text(
                  'Paused: template changes will not roll out until resumed. '
                  '${st['updatedReplicas'] ?? 0} of $desired replicas updated.',
                ),
              )
            else if (rollout.detail != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: InlineMessage(rollout.detail!, isError: rollout.severity == Severity.error),
              ),
            ReplicaStatusBar(
              desired: desired,
              current: asInt(st['replicas']) ?? 0,
              updated: asInt(st['updatedReplicas']) ?? 0,
              ready: asInt(st['readyReplicas']) ?? 0,
              available: asInt(st['availableReplicas']) ?? 0,
              unavailable: asInt(st['unavailableReplicas']),
              trailing: scaleControlFor(ctx),
            ),
            HpaOverrideNote(ctx, key: ValueKey('hpa-${ctx.uid}')),
            const SizedBox(height: 10),
            KeyValueTable([
              (
                'Strategy',
                strategy['type'] == 'Recreate'
                    ? 'Recreate (all pods killed before new ones start)'
                    : 'RollingUpdate · maxSurge ${ru['maxSurge'] ?? '25%'} · maxUnavailable ${ru['maxUnavailable'] ?? '25%'}',
              ),
              ('Min ready', '${spec['minReadySeconds'] ?? 0}s'),
              ('Progress deadline', spec['progressDeadlineSeconds'] == null ? null : '${spec['progressDeadlineSeconds']}s'),
              ('History limit', '${spec['revisionHistoryLimit'] ?? 10} revisions'),
              ('Revision', dig<String>(ctx.metadata, ['annotations', revisionAnnotation])),
              ('Generation', '${ctx.metadata['generation'] ?? '?'} (observed ${st['observedGeneration'] ?? '?'})'),
              ('Selector', SelectorChips(spec['selector'])),
            ], keyWidth: 120),
          ],
        ),
      ),
      DetailSection(title: 'Conditions', icon: Icons.checklist, child: ConditionsTable(st['conditions'] as List?)),
      DetailSection(
        title: 'Rollout history',
        icon: Icons.history,
        child: RolloutHistory(key: ValueKey('hist-${ctx.uid}'), ctx: ctx, refreshKey: key),
      ),
      workloadUsageSection(ctx),
      workloadHistory(ctx),
      DetailSection(
        title: 'Pods',
        icon: Icons.view_in_ar,
        child: PodsList(
          key: ValueKey('pods-${ctx.uid}'),
          api: ctx.api,
          namespace: ctx.namespace,
          selector: spec['selector'],
          ownerUid: ctx.uid,
          viaReplicaSets: true,
          refreshKey: key,
          actionCtx: ctx,
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

/// ReplicaSets owned by a Deployment, newest revision first, with image
/// changes vs the previous revision highlighted.
class RolloutHistory extends StatefulWidget {
  final PanelContext ctx;
  final String refreshKey;
  const RolloutHistory({super.key, required this.ctx, required this.refreshKey});

  @override
  State<RolloutHistory> createState() => _RolloutHistoryState();
}

class _RolloutHistoryState extends State<RolloutHistory> {
  late Future<List<Json>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(RolloutHistory old) {
    super.didUpdateWidget(old);
    if (old.refreshKey != widget.refreshKey) _future = _load(); // build() follows didUpdateWidget
  }

  Future<List<Json>> _load() async {
    final deployment = widget.ctx.object;
    final sel = selectorToString(dig(deployment, ['spec', 'selector']));
    final ns = dig<String>(deployment, ['metadata', 'namespace']);
    final uid = dig<String>(deployment, ['metadata', 'uid']) ?? '';
    final rs = await widget.ctx.api.items(replicaSetsRef, namespace: ns, labelSelector: sel.isEmpty ? null : sel);
    return rolloutHistory(rs, uid);
  }

  Widget _rollbackButton(Json current, Json target) {
    final rev = revisionOf(target);
    return ActionButton(
      widget.ctx,
      action: 'rollback',
      body: {'revision': rev},
      label: 'Roll back',
      icon: Icons.history,
      title: 'Roll back ${widget.ctx.name} to revision $rev?',
      message: rollbackSummary(current, target),
      destructive: true,
    );
  }

  @override
  Widget build(BuildContext context) => KeepingAsync<List<Json>>(
    future: _future,
    builder: (context, history) {
      if (history.isEmpty) return const InlineMessage('No ReplicaSets owned by this Deployment');
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < history.length; i++)
            _RevisionRow(
              rs: history[i],
              previous: i + 1 < history.length ? history[i + 1] : null,
              current: i == 0,
              action: i == 0 || widget.ctx.app.readOnly ? null : _rollbackButton(history.first, history[i]),
            ),
        ],
      );
    },
  );
}

class _RevisionRow extends StatelessWidget {
  final Json rs;
  final Json? previous;
  final bool current;
  final Widget? action;
  const _RevisionRow({required this.rs, required this.previous, required this.current, this.action});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = '${dig(rs, ['metadata', 'name'])}';
    final ns = dig<String>(rs, ['metadata', 'namespace']);
    final desired = asInt(dig(rs, ['spec', 'replicas'])) ?? 0;
    final ready = asInt(dig(rs, ['status', 'readyReplicas'])) ?? 0;
    final prevImages = previous == null ? const <String, String>{} : templateImages(previous!);
    final inits = initContainerNames(rs);
    // Init container images only when they changed, to keep rows compact.
    final images = {
      for (final e in templateImages(rs).entries)
        if (!inits.contains(e.key) || (previous != null && prevImages[e.key] != e.value)) e.key: e.value,
    };
    final cause = dig<String>(rs, ['metadata', 'annotations', 'kubernetes.io/change-cause']);
    final warn = severityColor(context, Severity.warn);
    final primary = theme.colorScheme.primary;
    final sev = desired == 0 ? Severity.neutral : (ready >= desired ? Severity.ok : Severity.warn);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: current ? primary.withValues(alpha: 0.10) : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: current ? primary.withValues(alpha: 0.6) : Colors.transparent),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              SizedBox(
                width: 38,
                child: Text(
                  '#${revisionOf(rs)}',
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w700, color: current ? primary : theme.hintColor),
                ),
              ),
              Expanded(
                child: OneLineLink(ObjectRef(group: 'apps', kind: 'ReplicaSet', name: name, namespace: ns)),
              ),
              if (current) ...[const StatusBadge('current', severity: Severity.info, dense: true), const SizedBox(width: 8)],
              if (action != null) ...[CompactButtons(child: action!), const SizedBox(width: 10)],
              Tooltip(message: 'ready / desired', child: coloredCount(context, '$ready/$desired', sev)),
              const SizedBox(width: 10),
              SizedBox(
                width: 36,
                child: Align(alignment: Alignment.centerRight, child: AgeText(dig(rs, ['metadata', 'creationTimestamp']))),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 38),
            child: Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                for (final e in images.entries)
                  () {
                    final was = prevImages[e.key];
                    final changed = previous != null && was != e.value;
                    return ImageChip(
                      e.value,
                      highlight: changed ? warn : null,
                      tooltip: changed ? (was == null ? '${e.key}: added in this revision' : '${e.key}: was $was') : '${e.key} — click to copy',
                    );
                  }(),
              ],
            ),
          ),
          if (cause != null)
            Padding(
              padding: const EdgeInsets.only(left: 38, top: 3),
              child: Text(
                cause,
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }
}
