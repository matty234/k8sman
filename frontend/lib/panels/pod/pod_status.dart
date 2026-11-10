import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../ui/inspector/inspector.dart';
import '../../ui/logs/open_logs.dart';
import '../../ui/security/security_tab.dart' show SecurityInsight;
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/pod.dart';
import '../panel.dart';
import 'pod_logic.dart';
import '../../ui/widgets/atoms.dart';

/// The top of the pod inspector: is this pod OK, and if not, why? A status
/// line, a row of large figures (ready, restarts, init; the age is in the
/// inspector's identity strip), the insights explaining any problem, then
/// what owns it and where it runs (node, IPs, service account) as quiet
/// facts.
///
/// One colour rule for restarts: the restart pattern's severity
/// ([restartKind]) colours the mark, the restarts figure and the
/// container's dot alike, so clean exits read calmer than crashes.
class PodStatusHeader extends StatelessWidget {
  final PanelContext ctx;
  const PodStatusHeader(this.ctx, {super.key});

  @override
  Widget build(BuildContext context) {
    final pod = ctx.object;
    final status = ctx.status;
    final effective = podStatus(pod);
    final phase = '${status['phase'] ?? ''}';
    final containers = podContainers(pod);
    final main = containers.where((c) => c.kind == ContainerKind.regular || c.kind == ContainerKind.sidecar).toList();
    final ready = main.where((c) => c.ready).length;
    final restarts = containers.fold<int>(0, (a, c) => a + c.restarts);
    final inits = containers.where((c) => c.kind == ContainerKind.init).toList();
    final initsDone = inits.where((c) => c.isTerminated && c.terminated['exitCode'] == 0).length;
    final others = podInsights(pod, restarts: false);
    final insights = [...others, ..._restartInsights(context, containers)];
    final succeeded = phase == 'Succeeded';

    // The worst restart pattern, and whether restarts are all that's wrong.
    final kinds = [for (final c in containers) ?restartKind(c)];
    final worstKind = kinds.isEmpty ? null : kinds.reduce((a, b) => _rank(b.severity) > _rank(a.severity) ? b : a);
    final onlyRestarts = worstKind != null && others.isEmpty && phase == 'Running' && ready == main.length;
    final worst = worstOf(insights);
    final healthy = worst == null && (phase == 'Running' || succeeded);

    final detail = [
      if (effective != phase && phase.isNotEmpty) 'phase $phase',
      if (onlyRestarts) '${main.length == 1 ? 'Ready' : 'All ${main.length} ready'}, but restarting: ${worstKind.short}'
      else if (healthy && !succeeded) main.length == 1 ? 'Healthy: its container is running and ready' : 'Healthy: all ${main.length} containers running and ready',
      if (healthy && succeeded) 'Completed: all containers exited successfully',
    ].join(' · ');

    final Severity mark = onlyRestarts ? worstKind.severity : (healthy ? Severity.ok : (worst ?? Severity.neutral));
    final restartSev = worstKind?.severity ?? Severity.neutral;
    Severity readySev() => succeeded || ready == main.length ? Severity.neutral : (ready == 0 ? Severity.error : Severity.warn);
    return InspectorHeader(
      mark: mark,
      headline: effective,
      headlineKey: const ValueKey('pod-status-headline'),
      detail: detail,
      figures: [
        if (main.isNotEmpty) InspectorFigure('$ready', 'ready', of: '/${main.length}', severity: readySev(), tooltip: '$ready of ${main.length} containers ready'),
        // The only place the count shows; the insight explains the pattern.
        InspectorFigure('$restarts', restarts == 1 ? 'restart' : 'restarts', severity: restartSev == Severity.info ? Severity.neutral : restartSev),
        if (inits.isNotEmpty)
          InspectorFigure('$initsDone', 'init done',
              of: initsDone == inits.length ? null : '/${inits.length}',
              severity: initsDone == inits.length ? Severity.neutral : Severity.warn,
              tooltip: '$initsDone of ${inits.length} init containers completed'),
      ],
      insights: insights,
      extraInsights: [SecurityInsight(ctx)],
      factsKeyWidth: 64,
      facts: _facts(context),
    );
  }

  static int _rank(Severity s) => switch (s) { Severity.error => 3, Severity.warn => 2, Severity.info => 1, _ => 0 };

  /// The restart insights. A single-container pod has no container row
  /// (and so no previous-logs action): its insight carries one.
  List<Insight> _restartInsights(BuildContext context, List<PodContainer> containers) {
    final single = singleMainContainer(containers);
    return [
      for (final (c, i) in podRestartInsights(ctx.object))
        if (single != null && c.name == single.name && c.lastTerminated.isNotEmpty)
          Insight.rich(
            i.severity,
            i.text,
            detail: i.detail,
            action: QuietLink(
              'Previous logs',
              key: const ValueKey('pod-previous-logs'),
              tooltip: 'Logs of the previous (terminated) instance',
              onTap: () => openPodLogs(context, ctx.object, container: single.name, previous: true),
            ),
          )
        else
          i,
    ];
  }

  /// Its owner, then where the pod runs, as caption/value pairs that wrap:
  /// node (with the host IP), the pod's IPs, service account and host
  /// namespaces.
  List<(String, Object?)> _facts(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final spec = ctx.spec;
    final status = ctx.status;
    final node = spec['nodeName'] as String?;
    final ips = [for (final i in asMapList(status['podIPs'])) '${i['ip']}'];
    if (ips.isEmpty && status['podIP'] != null) ips.add('${status['podIP']}');
    final hostIp = status['hostIP'] as String?;
    final sa = (spec['serviceAccountName'] ?? spec['serviceAccount']) as String?;
    final hostNs = [if (spec['hostNetwork'] == true) 'hostNetwork', if (spec['hostPID'] == true) 'hostPID', if (spec['hostIPC'] == true) 'hostIPC'];
    final warn = severityColor(context, Severity.warn);
    // A hostNetwork pod's IP is the host's: the IP row says it once.
    final hostOnNode = hostIp != null && !(ips.length == 1 && ips.single == hostIp);

    return [
      if (OwnerLine.hasOwner(ctx.object)) ('Owner', PodOwnerLine(ctx, key: ValueKey('pod-owner-${ctx.uid}'))),
      (
        'Node',
        node == null
            ? Text(status['nominatedNodeName'] != null ? 'unscheduled (nominated ${status['nominatedNodeName']})' : 'unscheduled', style: small?.copyWith(color: warn))
            : Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(child: ResourceLink(ObjectRef(kind: 'Node', name: node), label: node, singleLine: true)),
                if (hostOnNode) ...[
                  const HintText(' · '),
                  QuietCopy(hostIp, key: const ValueKey('pod-host-ip'), tooltip: 'Host IP (the node\'s address)'),
                ],
              ]),
      ),
      if (ips.isNotEmpty) ('IP', InlineWrap([for (final ip in ips) Chipish(text: ip, copyValue: ip)])),
      if (sa != null) ('Account', ResourceLink(ObjectRef(kind: 'ServiceAccount', name: sa, namespace: ctx.namespace), label: sa)),
      if (hostNs.isNotEmpty) ('Host', InlineWrap([for (final h in hostNs) Chipish(text: h, color: warn)])),
    ];
  }
}

/// The controller you edit, e.g. `Deployment/web`, with the ReplicaSet in
/// between as a quieter link (`rs 66c45d87b7`, the hash only); likewise
/// `CronJob/x · job 2901…`. The ReplicaSet (or Job) is read once per
/// session through [SharedFetch]; until it arrives, or when it can't be
/// read, the direct owner shows as before.
class PodOwnerLine extends StatelessWidget {
  final PanelContext ctx;
  const PodOwnerLine(this.ctx, {super.key});

  /// Resolved parents by fetch key, so a pod seen before draws its owner
  /// at once (no flash when arrowing through rows).
  static final _resolved = <String, ObjectRef?>{};

  static const _parents = {'ReplicaSet': ResourceRef(group: 'apps', resource: 'replicasets'), 'Job': ResourceRef(group: 'batch', resource: 'jobs')};

  @override
  Widget build(BuildContext context) {
    final owners = OwnerLine.ordered(ctx.object);
    final direct = owners.first;
    final res = _parents[direct.kind];
    if (res == null || owners.length > 1) return OwnerLine(ctx.object);
    final key = 'pod-owner/${identityHashCode(ctx.api)}/${direct.namespace}/${direct.kind}/${direct.name}';
    Future<ObjectRef?> fetch() async {
      try {
        final o = await ctx.api.object(res, namespace: direct.namespace, name: direct.name);
        final parent = OwnerLine.ordered(o).firstOrNull;
        return _resolved[key] = parent;
      } catch (_) {
        return _resolved[key] = null; // forbidden or gone: the direct owner
      }
    }

    return FutureBuilder<ObjectRef?>(
      future: SharedFetch.get(key, fetch),
      initialData: _resolved[key],
      builder: (context, snap) {
        final top = snap.data;
        if (top == null) return OwnerLine(ctx.object);
        final hash = direct.name.startsWith('${top.name}-') ? direct.name.substring(top.name.length + 1) : direct.name;
        final short = direct.kind == 'ReplicaSet' ? 'rs' : 'job';
        return Row(key: const ValueKey('owner-line'), mainAxisSize: MainAxisSize.min, children: [
          Flexible(child: ResourceLink(top, singleLine: true)),
          const HintText(' · '),
          QuietLink('$short $hash', tooltip: '${direct.kind}/${direct.name}', onTap: () => context.read<AppState>().openRef(direct)),
        ]);
      },
    );
  }
}

/// Small hint-coloured text that underlines on hover and runs [onTap]: a
/// secondary link that shouldn't compete with the primary one.
class QuietLink extends StatelessWidget {
  final String text;
  final String? tooltip;
  final VoidCallback onTap;
  const QuietLink(this.text, {super.key, this.tooltip, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final link = Hoverable(
      onTap: onTap,
      builder: (h) => Text(text,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.bodySmall?.copyWith(
            color: h ? theme.colorScheme.primary : theme.hintColor,
            decoration: h ? TextDecoration.underline : TextDecoration.none,
            decorationColor: theme.colorScheme.primary.withValues(alpha: 0.6),
          )),
    );
    return tooltip == null ? link : Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 400), child: link);
  }
}

/// Quiet mono text that copies itself on click.
class QuietCopy extends StatelessWidget {
  final String text;
  final String? tooltip;
  const QuietCopy(this.text, {super.key, this.tooltip});

  @override
  Widget build(BuildContext context) => QuietLink(text, tooltip: [?tooltip, 'Click to copy'].join(' · '), onTap: () => copyToClipboard(context, text));
}
