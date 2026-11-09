import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../metrics/pod_usage.dart';
import '../../ui/detail/owner_line.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/pod.dart';
import '../panel.dart';
import 'pod_logic.dart';
import 'pod_widgets.dart';

const _tabular = [FontFeature.tabularFigures()];

/// The top of the pod inspector: is this pod OK, and if not, why? A status
/// line, a row of large figures (ready, restarts, init, up), the insights
/// explaining any problem, then where it runs (node, IPs, service account,
/// usage) as one quiet line.
class PodStatusHeader extends StatelessWidget {
  final PanelContext ctx;
  const PodStatusHeader(this.ctx, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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

    final hint = theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor, fontSize: 12.5);
    final title = theme.textTheme.titleLarge?.copyWith(fontSize: 18, fontWeight: FontWeight.w600, letterSpacing: -0.2, height: 1.2);
    final detail = [
      if (effective != phase && phase.isNotEmpty) 'phase $phase',
      if (healthy && !succeeded) main.length == 1 ? 'Healthy: its container is running and ready' : 'Healthy: all ${main.length} containers running and ready',
      if (healthy && succeeded) 'Completed: all containers exited successfully',
    ].join(' · ');

    Severity readySev() => succeeded || ready == main.length ? Severity.neutral : (ready == 0 ? Severity.error : Severity.warn);
    final figures = <_Figure>[
      if (main.isNotEmpty) _Figure('$ready', '/${main.length}', 'ready', readySev(), tooltip: '$ready of ${main.length} containers ready'),
      _Figure('$restarts', null, restarts == 1 ? 'restart' : 'restarts', restarts > 0 ? Severity.warn : Severity.neutral),
      if (inits.isNotEmpty)
        _Figure('$initsDone', initsDone == inits.length ? null : '/${inits.length}', 'init done', initsDone == inits.length ? Severity.neutral : Severity.warn,
            tooltip: '$initsDone of ${inits.length} init containers completed'),
      if (status['startTime'] != null) _Figure.age(status['startTime'], 'up'),
    ];

    return Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
            SizedBox(width: 20, child: Align(alignment: Alignment.centerLeft, child: _mark(context, healthy ? Severity.ok : (worst ?? Severity.neutral)))),
            Flexible(child: Text(effective, key: const ValueKey('pod-status-headline'), maxLines: 1, overflow: TextOverflow.ellipsis, style: title)),
          ]),
          if (detail.isNotEmpty) Padding(padding: const EdgeInsets.only(left: 20, top: 2), child: Text(detail, style: hint)),
          const SizedBox(height: 14),
          _FigureRow(figures),
          if (insights.isNotEmpty) ...[const SizedBox(height: 14), InsightList(insights)],
          const SizedBox(height: 14),
          _Facts(ctx),
        ],
      ),
    );
  }

  /// A check when healthy, else a dot in the worst severity.
  static Widget _mark(BuildContext context, Severity s) {
    if (s == Severity.ok) return Icon(Icons.check_circle, size: 15, color: severityColor(context, Severity.ok));
    final c = severityColor(context, s);
    return Container(width: 9, height: 9, decoration: BoxDecoration(color: s == Severity.neutral ? null : c, shape: BoxShape.circle, border: Border.all(color: c, width: 1.5)));
  }
}

class _Figure {
  final String value;
  final String? of;
  final String label;
  final Severity severity;
  final String? tooltip;
  final dynamic since;
  const _Figure(this.value, this.of, this.label, this.severity, {this.tooltip}) : since = null;
  const _Figure.age(this.since, this.label)
      : value = '',
        of = null,
        severity = Severity.neutral,
        tooltip = null;
}

/// Large light numerals over small captions, divided by hairlines; colour
/// only when the number is a problem.
class _FigureRow extends StatelessWidget {
  final List<_Figure> figures;
  const _FigureRow(this.figures);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final separator = AppColors.of(context).separator;
    return LayoutBuilder(builder: (context, box) {
      final width = (box.maxWidth / figures.length).clamp(60.0, 104.0);
      return IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var i = 0; i < figures.length; i++)
            Container(
              width: width,
              padding: EdgeInsets.only(left: i == 0 ? 0 : 12, right: 6),
              decoration: i == 0 ? null : BoxDecoration(border: Border(left: BorderSide(color: separator))),
              child: _cell(context, theme, figures[i]),
            ),
        ]),
      );
    });
  }

  Widget _cell(BuildContext context, ThemeData theme, _Figure f) {
    final bad = f.severity == Severity.error || f.severity == Severity.warn;
    final big = theme.textTheme.headlineSmall?.copyWith(
      fontSize: 24,
      height: 1.1,
      fontWeight: FontWeight.w300,
      letterSpacing: -0.4,
      fontFeatures: _tabular,
      color: bad ? severityColor(context, f.severity) : theme.colorScheme.onSurface,
    );
    final Widget number = f.since != null
        ? AgeText(f.since, style: big)
        : Text.rich(
            TextSpan(children: [
              TextSpan(text: f.value, style: big),
              if (f.of != null) TextSpan(text: f.of, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w400, color: theme.hintColor, fontFeatures: _tabular)),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          );
    final cell = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      SizedBox(height: 28, child: Align(alignment: Alignment.centerLeft, child: number)),
      const SizedBox(height: 1),
      Text(f.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
    ]);
    return f.tooltip == null ? cell : Tooltip(message: f.tooltip!, child: cell);
  }
}

/// Its owner, then where the pod runs, as caption/value pairs that wrap:
/// node, pod and host IPs, service account, host namespaces and live usage.
class _Facts extends StatelessWidget {
  final PanelContext ctx;
  const _Facts(this.ctx);

  @override
  Widget build(BuildContext context) {
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

    return KeyValueTable(keyWidth: 64, [
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
                child: Row(mainAxisSize: MainAxisSize.min, children: [const Hint('host '), Chipish(text: hostIp, copyValue: hostIp)]),
              ),
          ]),
        ),
      if (sa != null) ('Account', ResourceLink(ObjectRef(kind: 'ServiceAccount', name: sa, namespace: ctx.namespace), label: sa)),
      if (hostNs.isNotEmpty) ('Host', InlineWrap([for (final h in hostNs) Chipish(text: h, color: warn)])),
      ('Usage', PodUsageSummary(pod: ctx.object)),
    ]);
  }
}
