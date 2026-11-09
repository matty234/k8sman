import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../panels/cluster/logic.dart' show podKubectlStatus, isTerminalPod;
import '../../util/k8s.dart';
import '../../util/pod.dart';
import '../nodes/nodes_view.dart' show podHasProblem;
import '../theme.dart';
import '../widgets/common.dart';
import 'parts.dart';
import 'rows.dart';

/// A pod's severity for a row: green when running and ready, grey when
/// done, amber while starting or restarting, red when failing.
Severity podRowSeverity(Json pod) {
  final status = podKubectlStatus(pod);
  if (status == 'Succeeded' || status == 'Completed') return Severity.neutral;
  if (!podHasProblem(pod)) return Severity.ok;
  return status == 'Pending' || status == 'ContainerCreating' || status == 'Terminating' || (status == 'Running' && podReady(pod)) ? Severity.warn : Severity.error;
}

/// Pods ordered problems first, then by namespace and name.
List<Json> problemsFirst(Iterable<Json> pods) {
  int rank(Json p) => switch (podRowSeverity(p)) { Severity.error => 0, Severity.warn => 1, Severity.ok => 2, _ => 3 };
  return [...pods]..sort((a, b) {
      final r = rank(a).compareTo(rank(b));
      if (r != 0) return r;
      final ns = '${dig(a, ['metadata', 'namespace'])}'.compareTo('${dig(b, ['metadata', 'namespace'])}');
      return ns != 0 ? ns : '${dig(a, ['metadata', 'name'])}'.compareTo('${dig(b, ['metadata', 'name'])}');
    });
}

/// A pod as a compact row: dot, linked name, status (coloured when wrong),
/// namespace and restarts; [trailing] on the right (an IP, requests).
class PodLinkRow extends StatelessWidget {
  final Json pod;
  final bool showNamespace;
  final List<Widget> trailing;
  final List<String> extra;
  const PodLinkRow(this.pod, {super.key, this.showNamespace = false, this.trailing = const [], this.extra = const []});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = '${dig(pod, ['metadata', 'name'])}';
    final ns = dig<String>(pod, ['metadata', 'namespace']);
    final sev = podRowSeverity(pod);
    final status = podKubectlStatus(pod);
    final restarts = podRestarts(pod);
    final bad = sev == Severity.error || sev == Severity.warn;
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return InspectorRow(
      key: ValueKey('pod-row-$ns/$name'),
      dot: sev,
      dotTooltip: status,
      title: ResourceLink(ObjectRef(kind: 'Pod', name: name, namespace: ns), label: name, singleLine: true),
      subtitle: Text.rich(
        TextSpan(style: hint, children: [
          TextSpan(text: status, style: bad ? TextStyle(color: severityColor(context, sev), fontWeight: FontWeight.w600) : null),
          if (showNamespace && ns != null) TextSpan(text: ' · $ns'),
          if (restarts > 0) TextSpan(text: ' · ${restarts == 1 ? '1 restart' : '$restarts restarts'}', style: restarts >= 5 ? TextStyle(color: severityColor(context, Severity.warn)) : null),
          for (final e in extra) TextSpan(text: ' · $e'),
        ]),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: trailing,
    );
  }
}

/// Active pods (problems first, trimmed) with a quiet note for the
/// completed or failed ones left out.
class PodRows extends StatelessWidget {
  final List<Json> pods;
  final bool showNamespace;
  final String empty;
  final List<Widget> Function(Json pod)? trailing;
  final bool hideTerminal;
  const PodRows(this.pods, {super.key, this.showNamespace = false, this.empty = 'No pods', this.trailing, this.hideTerminal = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final shown = hideTerminal ? pods.where((p) => !isTerminalPod(p)).toList() : pods;
    final hidden = pods.length - shown.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (shown.isEmpty)
        Padding(padding: const EdgeInsets.only(left: 4), child: Text(empty, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)))
      else
        TrimmedList([for (final p in problemsFirst(shown)) PodLinkRow(p, showNamespace: showNamespace, trailing: trailing?.call(p) ?? const [])], trimAbove: 12, keep: 8),
      if (hidden > 0)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 6, 0, 0),
          child: Text('$hidden completed/failed pods not shown', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ),
    ]);
  }
}
