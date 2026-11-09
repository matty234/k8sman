import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../../ui/inspector/inspector.dart';
import '../panel.dart';
import 'usage.dart';
import 'values.dart';

/// Values longer than this are trimmed behind "Show all N lines".
const kCollapseLines = 30;
const kCollapseChars = 3000;

/// Small refresh button for section trailers.
class RefreshButton extends StatelessWidget {
  final VoidCallback onPressed;
  const RefreshButton(this.onPressed, {super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        iconSize: 16,
        visualDensity: VisualDensity.compact,
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh),
        onPressed: onPressed,
      );
}

/// A refresh icon small enough for a section header's summary.
class HeaderRefresh extends StatelessWidget {
  final VoidCallback onTap;
  const HeaderRefresh(this.onTap, {super.key});

  @override
  Widget build(BuildContext context) => Padding(padding: const EdgeInsets.only(left: 6), child: RowAction(icon: Icons.refresh, tooltip: 'Refresh', onTap: onTap));
}

/// Count pill for section trailers.
class CountPill extends StatelessWidget {
  final String text;
  final Severity severity;
  const CountPill(this.text, {super.key, this.severity = Severity.neutral});

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(right: 4),
        child: StatusBadge(text, dense: true, severity: severity),
      );
}

/// Renders text segments where `true` parts are monospace.
class SegmentText extends StatelessWidget {
  final List<(String, bool)> segments;
  final Color? color;
  const SegmentText(this.segments, {super.key, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodySmall?.copyWith(color: color);
    final mono = monoStyle(context, size: 11.5, color: color ?? theme.colorScheme.onSurface);
    return Text.rich(TextSpan(children: [
      for (final (t, code) in segments)
        if (code)
          TextSpan(text: t, style: mono)
        else
          // Arrows render in the mono font: the UI font may lack the glyphs.
          for (final part in t.split(RegExp(r'(?=[→←])|(?<=[→←])')))
            TextSpan(text: part, style: part == '→' || part == '←' ? mono.copyWith(color: theme.hintColor) : base),
    ]));
  }
}

IconData usageIcon(UsageKind k) => switch (k) {
      UsageKind.serviceAccount => Icons.badge_outlined,
      UsageKind.volume || UsageKind.projected => Icons.folder_outlined,
      UsageKind.env => Icons.code,
      UsageKind.envFrom => Icons.input,
      UsageKind.imagePullSecret => Icons.cloud_download_outlined,
    };

/// "1.2 KiB" as a big figure: the number, then its unit small.
InspectorFigure sizeFigure(int bytes, String label) {
  final parts = formatSize(bytes).split(' ');
  return InspectorFigure(parts.first, label, of: parts.length > 1 ? ' ${parts.sublist(1).join(' ')}' : null, tooltip: '$bytes bytes');
}

// ---------------------------------------------------------------------------
// Used by: one fetch shared by the header's count and the section
// ---------------------------------------------------------------------------

/// The [SharedFetch] key of the Used by report of [ctx].
String usageKey(PanelContext ctx, RefKind kind) => 'usage:${identityHashCode(ctx.api)}:${kind.name}:${ctx.namespace}/${ctx.name}';

/// Pods in the namespace that reference the object, grouped under the
/// workloads that own them. Pods are required; the rest are best-effort
/// (RBAC may forbid them).
Future<UsageReport> fetchUsageReport(ApiClient api, {required RefKind kind, required String name, String? namespace}) async {
  Future<List<Json>> list(String group, String resource) => api.items(ResourceRef(group: group, resource: resource), namespace: namespace).catchError((_) => <Json>[]);
  final r = await Future.wait([
    api.items(const ResourceRef(resource: 'pods'), namespace: namespace),
    list('apps', 'replicasets'),
    list('apps', 'deployments'),
    list('apps', 'statefulsets'),
    list('apps', 'daemonsets'),
    list('batch', 'jobs'),
    list('batch', 'cronjobs'),
  ]);
  return buildUsageReport(
    pods: r[0],
    replicaSets: r[1],
    templates: {'Deployment': r[2], 'StatefulSet': r[3], 'DaemonSet': r[4], 'Job': r[5], 'CronJob': r[6]},
    kind: kind,
    name: name,
    namespace: namespace,
  );
}

/// Builds from the shared Used by report of [ctx].
class UsageReportBuilder extends StatelessWidget {
  final PanelContext ctx;
  final RefKind kind;
  final Widget Function(BuildContext context, AsyncSnapshot<UsageReport> snap) builder;
  const UsageReportBuilder({super.key, required this.ctx, required this.kind, required this.builder});

  @override
  Widget build(BuildContext context) => SharedFetchBuilder<UsageReport>(
        fetchKey: usageKey(ctx, kind),
        fetch: () => fetchUsageReport(ctx.api, kind: kind, name: ctx.name, namespace: ctx.namespace),
        builder: builder,
      );
}

/// The Used by figures for a header: pods, and the workloads they belong
/// to (placeholders while loading).
List<InspectorFigure> usedByFigures(AsyncSnapshot<UsageReport> snap) {
  final r = snap.data;
  if (snap.hasError) return const [InspectorFigure('?', 'pods use it', tooltip: 'Could not list pods')];
  final pods = r?.pods.length;
  final workloads = r?.workloads.length;
  return [
    InspectorFigure(pods == null ? null : '$pods', pods == 1 ? 'pod uses it' : 'pods use it'),
    InspectorFigure(workloads == null ? null : '$workloads', workloads == 1 ? 'workload' : 'workloads',
        tooltip: r == null || r.workloads.isEmpty ? null : r.workloads.map((w) => '${w.ref.kind}/${w.ref.name}').join('\n')),
  ];
}

/// Keys referenced by pods but missing from the object, as insights.
List<Widget> missingKeyInsights(AsyncSnapshot<UsageReport> snap, Set<String> existingKeys, String kindLabel) {
  final r = snap.data;
  if (r == null) return const [];
  return [
    for (final m in missingKeys(r.all, existingKeys))
      InsightLine(
        m.allOptional ? Severity.warn : Severity.error,
        'Key ${m.key} is referenced but missing from this $kindLabel',
        detail: '${m.allOptional ? 'Optional ref, so the value is silently absent' : 'Pods will fail with CreateContainerConfigError'} · ${plural(m.pods.length, 'pod')}: ${m.pods.join(', ')}',
      ),
  ];
}

/// "Used by": every workload and pod in the namespace that references the
/// ConfigMap, Secret or ServiceAccount, as compact rows (the workload or
/// pod, then how it uses it).
class UsedBySection extends StatelessWidget {
  final PanelContext ctx;
  final RefKind kind;

  /// Keys present in the object (data + binaryData/stringData).
  final Set<String> existingKeys;

  const UsedBySection({super.key, required this.ctx, required this.kind, required this.existingKeys});

  @override
  Widget build(BuildContext context) {
    return UsageReportBuilder(
      ctx: ctx,
      kind: kind,
      builder: (context, snap) {
        final report = snap.data;
        final missing = report == null ? const <MissingKey>[] : missingKeys(report.all, existingKeys);
        final summary = report == null
            ? ''
            : [
                if (report.workloads.isNotEmpty) plural(report.workloads.length, 'workload'),
                plural(report.pods.length, 'pod'),
                if (missing.isNotEmpty) plural(missing.length, 'missing key'),
              ].join(' · ');
        return InspectorSection(
          id: 'usedby-${kind.name}',
          title: 'Used by',
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            Flexible(
              child: SectionSummary(summary,
                  color: missing.isEmpty ? null : severityColor(context, missing.every((m) => m.allOptional) ? Severity.warn : Severity.error)),
            ),
            HeaderRefresh(() => SharedFetch.invalidate(usageKey(ctx, kind))),
          ]),
          child: () {
            if (snap.hasError) return InlineMessage('Could not list pods: ${snap.error}', isError: true);
            if (report == null) return const SectionSpinner();
            return _UsageList(
              report: report,
              existingKeys: existingKeys,
              uid: ctx.uid,
              namespace: ctx.namespace ?? '',
            );
          }(),
        );
      },
    );
  }
}

class _UsageList extends StatelessWidget {
  final UsageReport report;
  final Set<String> existingKeys;
  final String uid;
  final String namespace;
  const _UsageList({required this.report, required this.existingKeys, required this.uid, required this.namespace});

  Widget _usageRow(BuildContext context, ConfigUsage u) {
    final theme = Theme.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 1), child: Icon(usageIcon(u.kind), size: 12, color: theme.hintColor)),
      const SizedBox(width: 6),
      Expanded(
        child: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          SegmentText(u.segments),
          if (u.optional && u.kind != UsageKind.serviceAccount) Text('optional', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          if (u.keys.any((k) => !existingKeys.contains(k)))
            Text('missing key',
                style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, u.optional ? Severity.warn : Severity.error), fontWeight: FontWeight.w600)),
        ]),
      ),
    ]);
  }

  bool _missing(List<ConfigUsage> us) => us.any((u) => u.keys.any((k) => !existingKeys.contains(k)));

  @override
  Widget build(BuildContext context) {
    if (report.isEmpty) {
      return InlineMessage('Not used by any pod in $namespace (Deployment, StatefulSet, DaemonSet, Job and CronJob templates checked too).');
    }
    final groups = groupIdentical(report.standalone);
    final total = report.workloads.length + groups.length;
    // Few rows: show how each uses it; many: one line each, open on demand.
    final open = total <= 3;
    Widget pods(List<PodUsage> ps) => Wrap(spacing: 10, runSpacing: 2, children: [for (final pu in ps) _PodLink(pu)]);
    final rows = <Widget>[
      for (final w in report.workloads)
        InspectorRow(
          key: ValueKey('usedby-${w.ref.kind}/${w.ref.name}'),
          memoryId: 'usedby:$uid/${w.ref.kind}/${w.ref.name}',
          leading: const Icon(Icons.account_tree_outlined),
          problem: _missing(w.usages),
          initiallyExpanded: open || _missing(w.usages),
          title: ResourceLink(w.ref, label: w.ref.name, singleLine: true),
          subtitle: Text('${w.ref.kind} · ${w.pods.isEmpty ? 'no pods running' : plural(w.pods.length, 'pod')} · ${_how(w.usages)}'),
          details: (context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (w.pods.isNotEmpty) ...[pods(w.pods), const SizedBox(height: 6)],
            for (final u in w.usages) Padding(padding: const EdgeInsets.only(bottom: 2), child: _usageRow(context, u)),
          ]),
        ),
      for (final g in groups)
        InspectorRow(
          key: ValueKey('usedby-pod-${g.first.name}'),
          memoryId: 'usedby:$uid/pod/${g.first.name}',
          leading: const Icon(Icons.view_in_ar),
          problem: _missing(g.first.usages),
          initiallyExpanded: open || _missing(g.first.usages),
          title: g.length == 1
              ? _PodLink(g.first)
              : Text.rich(TextSpan(children: [
                  WidgetSpan(alignment: PlaceholderAlignment.middle, child: _PodLink(g.first)),
                  TextSpan(text: '  +${g.length - 1}', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor)),
                ])),
          subtitle: Text('${g.length == 1 ? 'Pod' : plural(g.length, 'pod')} · ${_how(g.first.usages)}'),
          details: (context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (g.length > 1) ...[pods(g), const SizedBox(height: 6)],
            for (final u in g.first.usages) Padding(padding: const EdgeInsets.only(bottom: 2), child: _usageRow(context, u)),
          ]),
        ),
    ];
    return TrimmedList(rows, keep: 6, trimAbove: 8);
  }

  /// "volume, env" — how a row uses the object, for its subtitle.
  static String _how(List<ConfigUsage> us) {
    final kinds = <String>{
      for (final u in us)
        switch (u.kind) {
          UsageKind.volume || UsageKind.projected => 'volume',
          UsageKind.env => 'env',
          UsageKind.envFrom => 'envFrom',
          UsageKind.imagePullSecret => 'image pull',
          UsageKind.serviceAccount => 'service account',
        },
    };
    return kinds.join(', ');
  }
}

class _PodLink extends StatelessWidget {
  final PodUsage pu;
  const _PodLink(this.pu);

  @override
  Widget build(BuildContext context) {
    final phase = dig<String>(pu.pod, ['status', 'phase']);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      Flexible(child: ResourceLink(pu.ref, label: pu.name, singleLine: true)),
      if (phase != null && phase != 'Running') ...[const SizedBox(width: 4), StatusBadge(phase, dense: true)],
    ]);
  }
}

// ---------------------------------------------------------------------------
// Values
// ---------------------------------------------------------------------------

/// A (pretty-printed) value in a code block, trimmed past
/// [kCollapseLines] lines behind "Show all N lines".
class LongValue extends StatefulWidget {
  final String text;
  const LongValue(this.text, {super.key});

  @override
  State<LongValue> createState() => _LongValueState();
}

class _LongValueState extends State<LongValue> {
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lines = widget.text.split('\n');
    final long = lines.length > kCollapseLines || widget.text.length > kCollapseChars;
    var shown = widget.text;
    if (long && !_showAll) {
      shown = lines.take(kCollapseLines).join('\n');
      if (shown.length > kCollapseChars) shown = shown.substring(0, kCollapseChars);
      shown = '$shown\n…';
    }
    if (widget.text.isEmpty) return Text('(empty)', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      CodeBlock(shown),
      if (long) ShowMoreLink(_showAll ? 'Show less' : 'Show all ${lines.length} lines', onTap: () => setState(() => _showAll = !_showAll)),
    ]);
  }
}
