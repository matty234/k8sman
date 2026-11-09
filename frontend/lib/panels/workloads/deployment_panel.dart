import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../api/models.dart';
import '../../metrics/workload_usage.dart';
import '../../prometheus/metric_history_chart.dart';
import '../../ui/inspector/inspector.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../ui/logs/open_logs.dart';
import '../../ui/terminal/open_terminal.dart';
import '../panel.dart';
import 'rollout.dart';
import 'widgets/pods_list.dart';
import 'widgets/scaling.dart';
import 'widgets/sections.dart';
import 'widgets/status_header.dart';
import 'widgets/util.dart';

class DeploymentPanel extends ResourcePanel {
  const DeploymentPanel();

  @override
  bool get showsOwned => true;

  @override
  bool get ownerInHeader => true;

  @override
  Set<String> get kinds => const {'apps/Deployment'};

  @override
  List<ResourceAction> actions(PanelContext ctx) => [workloadLogsAction(ctx), workloadTerminalAction(ctx)];

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final st = ctx.status;
    final head = deploymentHeadline(ctx.object);
    final strategy = asMap(spec['strategy']);
    final ru = asMap(strategy['rollingUpdate']);
    final desired = asInt(spec['replicas']) ?? 1;
    final ready = asInt(st['readyReplicas']) ?? 0;
    final updated = asInt(st['updatedReplicas']) ?? 0;
    final available = asInt(st['availableReplicas']) ?? 0;
    final unavailable = asInt(st['unavailableReplicas']) ?? (desired - available).clamp(0, desired);
    final key = workloadRefreshKey(ctx);
    final rev = dig<String>(ctx.metadata, ['annotations', revisionAnnotation]);
    final paused = spec['paused'] == true;
    final recreate = strategy['type'] == 'Recreate';

    return [
      // Is it rolled out and available, and if not, why?
      InspectorHeader(
        headline: head.text,
        mark: head.severity,
        detail: head.detail,
        progress: head.progress == null
            ? null
            : InspectorProgress(head.progress!, tooltip: '$updated of $desired replicas on the new template'),
        figures: [
          InspectorFigure.count(ready, desired, 'ready', zeroIsError: true),
          InspectorFigure('$updated', 'updated', of: '/$desired', tooltip: 'on the latest pod template'),
          InspectorFigure.count(available, desired, 'available', zeroIsError: true),
          InspectorFigure('$unavailable', 'unavailable', severity: unavailable > 0 ? Severity.warn : Severity.neutral),
        ],
        insights: [
          if (paused)
            Insight.rich(
              Severity.warn,
              'Rollout paused',
              detail: 'Template changes will not roll out until resumed.',
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
            ),
          ...conditionInsights(asMapList(st['conditions'])),
        ],
        extraInsights: [HpaOverrideNote(ctx, key: ValueKey('hpa-${ctx.uid}'))],
        facts: [?ownerFact(ctx.object), replicasFact(ctx)],
      ),
      PodsList(
        key: ValueKey('pods-${ctx.uid}'),
        api: ctx.api,
        namespace: ctx.namespace,
        selector: spec['selector'],
        ownerUid: ctx.uid,
        viaReplicaSets: true,
        refreshKey: key,
        actionCtx: ctx,
        sectionTitle: 'Pods',
      ),
      workloadUsageSection(ctx),
      workloadHistory(ctx),
      // Reference detail, collapsed behind a one-line summary.
      InspectorSection(
        key: const ValueKey('workload-section-history'),
        id: 'workload-history',
        title: 'Rollout history',
        initiallyExpanded: false,
        trailing: _HistorySummary(ctx: ctx, refreshKey: key, revision: rev),
        child: RolloutHistory(key: ValueKey('hist-${ctx.uid}'), ctx: ctx, refreshKey: key),
      ),
      workloadSection(
        'strategy',
        'Strategy',
        recreate ? 'Recreate' : 'RollingUpdate · ${ru['maxSurge'] ?? '25%'} surge · ${ru['maxUnavailable'] ?? '25%'} unavailable',
        KeyValueTable([
          (
            'Strategy',
            recreate
                ? 'Recreate (all pods killed before new ones start)'
                : 'RollingUpdate · maxSurge ${ru['maxSurge'] ?? '25%'} · maxUnavailable ${ru['maxUnavailable'] ?? '25%'}',
          ),
          ('Min ready', '${spec['minReadySeconds'] ?? 0}s'),
          ('Progress deadline', spec['progressDeadlineSeconds'] == null ? null : '${spec['progressDeadlineSeconds']}s'),
          ('History limit', '${spec['revisionHistoryLimit'] ?? 10} revisions'),
          ('Revision', rev),
          ('Generation', '${ctx.metadata['generation'] ?? '?'} (observed ${st['observedGeneration'] ?? '?'})'),
        ], keyWidth: 120),
      ),
      podTemplateSection(asMap(spec['template']), ctx.namespace, uid: ctx.uid),
      schedulingSection(asMap(dig(spec, ['template', 'spec']))),
      conditionsSection(context, st),
      selectorSection(spec['selector']),
    ];
  }
}

/// The Deployment's ReplicaSets (newest first), one fetch per client, uid
/// and refresh key, shared by the history section and its summary.
final _historyCache = <String, (String, Future<List<Json>>)>{};

Future<List<Json>> _history(PanelContext ctx, String refreshKey) {
  final id = '${identityHashCode(ctx.api)}/${ctx.uid}';
  final hit = _historyCache[id];
  if (hit != null && hit.$1 == refreshKey) return hit.$2;
  if (_historyCache.length > 32) _historyCache.clear();
  final deployment = ctx.object;
  final sel = selectorToString(dig(deployment, ['spec', 'selector']));
  final f = ctx.api.items(replicaSetsRef, namespace: ctx.namespace, labelSelector: sel.isEmpty ? null : sel).then((rs) => rolloutHistory(rs, ctx.uid));
  _historyCache[id] = (refreshKey, f);
  return f;
}

/// "revision 7 · 3 kept".
class _HistorySummary extends StatelessWidget {
  final PanelContext ctx;
  final String refreshKey;
  final String? revision;
  const _HistorySummary({required this.ctx, required this.refreshKey, required this.revision});

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Json>>(
        future: _history(ctx, refreshKey),
        builder: (context, snap) => SectionSummary([
          if (revision != null) 'revision $revision',
          if (snap.data != null) '${snap.data!.length} kept',
        ].join(' · ')),
      );
}

/// ReplicaSets owned by a Deployment, newest revision first, with image
/// changes vs the previous revision highlighted.
class RolloutHistory extends StatelessWidget {
  final PanelContext ctx;
  final String refreshKey;
  const RolloutHistory({super.key, required this.ctx, required this.refreshKey});

  Widget _rollbackButton(Json current, Json target) {
    final rev = revisionOf(target);
    return ActionButton(
      ctx,
      action: 'rollback',
      body: {'revision': rev},
      label: 'Roll back',
      icon: Icons.history,
      title: 'Roll back ${ctx.name} to revision $rev?',
      message: rollbackSummary(current, target),
      destructive: true,
    );
  }

  @override
  Widget build(BuildContext context) => KeepingAsync<List<Json>>(
    future: _history(ctx, refreshKey),
    builder: (context, history) {
      if (history.isEmpty) return const InlineMessage('No ReplicaSets owned by this Deployment');
      return TrimmedList([
        for (var i = 0; i < history.length; i++)
          _RevisionRow(
            rs: history[i],
            previous: i + 1 < history.length ? history[i + 1] : null,
            current: i == 0,
            action: i == 0 || ctx.app.readOnly ? null : _rollbackButton(history.first, history[i]),
          ),
      ], gap: 2, indent: 0);
    },
  );
}

/// One revision: its number, ReplicaSet, ready count and age, then its
/// images (changes from the revision before in amber); roll back on hover.
class _RevisionRow extends StatelessWidget {
  final Json rs;
  final Json? previous;
  final bool current;
  final Widget? action;
  const _RevisionRow({required this.rs, required this.previous, required this.current, this.action});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
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
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor, fontFeatures: const [FontFeature.tabularFigures()]);

    return Hoverable(
      builder: (hovered) => Container(
        decoration: BoxDecoration(color: hovered ? colors.hover : null, borderRadius: BorderRadius.circular(5)),
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Row(children: [
            SizedBox(
              width: 34,
              child: Text(
                '#${revisionOf(rs)}',
                style: small?.copyWith(fontWeight: FontWeight.w600, color: current ? theme.colorScheme.onSurface : theme.hintColor),
              ),
            ),
            Expanded(child: OneLineLink(ObjectRef(group: 'apps', kind: 'ReplicaSet', name: name, namespace: ns))),
            if (current) ...[Text('current', style: hint), const SizedBox(width: 10)],
            if (action != null)
              IgnorePointer(
                ignoring: !hovered,
                child: Opacity(opacity: hovered ? 1 : 0, child: Padding(padding: const EdgeInsets.only(right: 10), child: CompactButtons(child: action!))),
              ),
            Tooltip(
              message: 'ready / desired',
              child: Text('$ready/$desired', style: hint?.copyWith(color: desired > 0 && ready < desired ? warn : null)),
            ),
            SizedBox(width: 34, child: Align(alignment: Alignment.centerRight, child: AgeText(dig(rs, ['metadata', 'creationTimestamp']), style: hint))),
          ]),
          Padding(
            padding: const EdgeInsets.only(left: 34, top: 2),
            child: Wrap(spacing: 10, runSpacing: 2, children: [
              for (final e in images.entries)
                () {
                  final was = prevImages[e.key];
                  final changed = previous != null && was != e.value;
                  return Tooltip(
                    message: changed ? (was == null ? '${e.key}: added in this revision' : '${e.key}: was $was') : e.key,
                    child: HoverCopy(copy: e.value, child: Text(shortImageRef(e.value), style: monoStyle(context, size: 11, color: changed ? warn : theme.hintColor))),
                  );
                }(),
            ]),
          ),
          if (cause != null)
            Padding(
              padding: const EdgeInsets.only(left: 34, top: 2),
              child: Text(cause, style: hint, maxLines: 2, overflow: TextOverflow.ellipsis),
            ),
        ]),
      ),
    );
  }
}
