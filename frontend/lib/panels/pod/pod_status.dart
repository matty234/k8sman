import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/inspector/inspector.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/pod.dart';
import '../panel.dart';
import 'pod_logic.dart';
import '../../ui/widgets/atoms.dart';

/// The top of the pod inspector: is this pod OK, and if not, why? A status
/// line, a row of large figures (ready, restarts, init; the age is in the inspector's identity strip), the insights
/// explaining any problem, then where it runs (node, IPs, service account,
/// usage) as one quiet line.
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
    final insights = podInsights(pod);
    final worst = insights.any((i) => i.severity == Severity.error)
        ? Severity.error
        : insights.isNotEmpty
            ? Severity.warn
            : null;
    final succeeded = phase == 'Succeeded';
    final healthy = worst == null && (phase == 'Running' || succeeded);

    final detail = [
      if (effective != phase && phase.isNotEmpty) 'phase $phase',
      if (healthy && !succeeded) main.length == 1 ? 'Healthy: its container is running and ready' : 'Healthy: all ${main.length} containers running and ready',
      if (healthy && succeeded) 'Completed: all containers exited successfully',
    ].join(' · ');

    Severity readySev() => succeeded || ready == main.length ? Severity.neutral : (ready == 0 ? Severity.error : Severity.warn);
    return InspectorHeader(
      mark: healthy ? Severity.ok : (worst ?? Severity.neutral),
      headline: effective,
      headlineKey: const ValueKey('pod-status-headline'),
      detail: detail,
      figures: [
        if (main.isNotEmpty) InspectorFigure('$ready', 'ready', of: '/${main.length}', severity: readySev(), tooltip: '$ready of ${main.length} containers ready'),
        InspectorFigure('$restarts', restarts == 1 ? 'restart' : 'restarts', severity: restarts > 0 ? Severity.warn : Severity.neutral),
        if (inits.isNotEmpty)
          InspectorFigure('$initsDone', 'init done',
              of: initsDone == inits.length ? null : '/${inits.length}',
              severity: initsDone == inits.length ? Severity.neutral : Severity.warn,
              tooltip: '$initsDone of ${inits.length} init containers completed'),
      ],
      insights: insights,
      factsKeyWidth: 64,
      facts: _facts(context),
    );
  }

  /// Its owner, then where the pod runs, as caption/value pairs that wrap:
  /// node, pod and host IPs, service account, host namespaces and live usage.
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

    return [
      ?ownerFact(ctx.object),
      (
        'Node',
        node == null
            ? Text(status['nominatedNodeName'] != null ? 'unscheduled (nominated ${status['nominatedNodeName']})' : 'unscheduled', style: small?.copyWith(color: warn))
            : ResourceLink(ObjectRef(kind: 'Node', name: node), label: node),
      ),
      if (ips.isNotEmpty || hostIp != null)
        (
          'IP',
          InlineWrap([
            for (final ip in ips) Chipish(text: ip, copyValue: ip),
            if (hostIp != null)
              Tooltip(
                message: 'Host IP (the node\'s address)',
                child: Row(mainAxisSize: MainAxisSize.min, children: [const HintText('host '), Chipish(text: hostIp, copyValue: hostIp)]),
              ),
          ]),
        ),
      if (sa != null) ('Account', ResourceLink(ObjectRef(kind: 'ServiceAccount', name: sa, namespace: ctx.namespace), label: sa)),
      if (hostNs.isNotEmpty) ('Host', InlineWrap([for (final h in hostNs) Chipish(text: h, color: warn)])),
    ];
  }
}
