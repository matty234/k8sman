import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'usage.dart';

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

/// "Used by" section: fetches pods in the namespace once and lists every
/// pod that references the ConfigMap/Secret, grouped by identical usage.
class UsedBySection extends StatefulWidget {
  final PanelContext ctx;
  final RefKind kind;

  /// Keys present in the object (data + binaryData/stringData).
  final Set<String> existingKeys;

  const UsedBySection({super.key, required this.ctx, required this.kind, required this.existingKeys});

  @override
  State<UsedBySection> createState() => _UsedBySectionState();
}

class _UsedBySectionState extends State<UsedBySection> {
  late Future<UsageReport> _report;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    final ns = widget.ctx.namespace;
    final api = widget.ctx.api;
    // Pods are required; the rest are best-effort (RBAC may forbid them).
    Future<List<Json>> list(String group, String resource) =>
        api.items(ResourceRef(group: group, resource: resource), namespace: ns).catchError((_) => <Json>[]);
    _report = () async {
      final r = await Future.wait([
        api.items(const ResourceRef(resource: 'pods'), namespace: ns),
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
        kind: widget.kind,
        name: widget.ctx.name,
        namespace: ns,
      );
    }();
  }

  @override
  void didUpdateWidget(UsedBySection old) {
    super.didUpdateWidget(old);
    if (old.ctx.name != widget.ctx.name || old.ctx.namespace != widget.ctx.namespace) _fetch();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<UsageReport>(
      future: _report,
      builder: (context, snap) {
        final report = snap.data;
        final missing = report == null ? const <MissingKey>[] : missingKeys(report.all, widget.existingKeys);
        return DetailSection(
          title: 'Used by',
          icon: Icons.link,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (missing.isNotEmpty)
              CountPill('${missing.length} missing key${missing.length == 1 ? '' : 's'}',
                  severity: missing.every((m) => m.allOptional) ? Severity.warn : Severity.error),
            if (report != null) CountPill('${report.pods.length} pod${report.pods.length == 1 ? '' : 's'}'),
            RefreshButton(() => setState(_fetch)),
          ]),
          child: () {
            if (snap.hasError) return InlineMessage('Could not list pods: ${snap.error}', isError: true);
            if (report == null) return const SectionSpinner();
            return _UsageList(
              report: report,
              missing: missing,
              existingKeys: widget.existingKeys,
              kindLabel: switch (widget.kind) { RefKind.configMap => 'ConfigMap', RefKind.secret => 'Secret', RefKind.serviceAccount => 'ServiceAccount' },
              namespace: widget.ctx.namespace ?? '',
            );
          }(),
        );
      },
    );
  }
}

class _UsageList extends StatelessWidget {
  final UsageReport report;
  final List<MissingKey> missing;
  final Set<String> existingKeys;
  final String kindLabel;
  final String namespace;
  const _UsageList({required this.report, required this.missing, required this.existingKeys, required this.kindLabel, required this.namespace});

  Widget _usageRow(BuildContext context, ConfigUsage u) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 18, top: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 1), child: Icon(usageIcon(u.kind), size: 13, color: theme.hintColor)),
        const SizedBox(width: 6),
        Expanded(
          child: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            SegmentText(u.segments),
            if (u.optional && u.kind != UsageKind.serviceAccount) const StatusBadge('optional', dense: true, severity: Severity.info),
            if (u.keys.any((k) => !existingKeys.contains(k)))
              StatusBadge('missing key', dense: true, severity: u.optional ? Severity.warn : Severity.error),
          ]),
        ),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (report.isEmpty) {
      return InlineMessage('Not used by any pod in $namespace (Deployment, StatefulSet, DaemonSet, Job and CronJob templates checked too).');
    }
    final groups = groupIdentical(report.standalone);
    final err = severityColor(context, Severity.error);
    final warn = severityColor(context, Severity.warn);
    var first = missing.isEmpty;
    Widget sep() {
      final w = first ? const SizedBox.shrink() : const Divider(height: 12);
      first = false;
      return w;
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final m in missing)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Icon(Icons.warning_amber_rounded, size: 15, color: m.allOptional ? warn : err),
            const SizedBox(width: 6),
            Expanded(
              child: SegmentText([
                ('Key ', false),
                (m.key, true),
                (' is referenced but missing from this $kindLabel', false),
                (m.allOptional ? ' (optional ref, so the value is silently absent)' : ' (pods will fail with CreateContainerConfigError)', false),
                (' · ${m.pods.length} pod${m.pods.length == 1 ? '' : 's'}', false),
              ], color: m.allOptional ? warn : err),
            ),
          ]),
        ),
      for (final w in report.workloads) ...[
        sep(),
        Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Icon(Icons.account_tree_outlined, size: 14, color: theme.hintColor),
          Text(w.ref.kind, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ResourceLink(w.ref, label: w.ref.name),
          if (w.pods.isEmpty) Text('no pods running', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ]),
        if (w.pods.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 18, top: 2),
            child: Wrap(spacing: 10, runSpacing: 2, children: [for (final pu in w.pods) _PodLink(pu)]),
          ),
        const SizedBox(height: 3),
        for (final u in w.usages) _usageRow(context, u),
      ],
      for (final g in groups) ...[
        sep(),
        Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Icon(Icons.view_in_ar, size: 14, color: theme.hintColor),
          for (final pu in g) _PodLink(pu),
        ]),
        const SizedBox(height: 3),
        for (final u in g.first.usages) _usageRow(context, u),
      ],
    ]);
  }
}

class _PodLink extends StatelessWidget {
  final PodUsage pu;
  const _PodLink(this.pu);

  @override
  Widget build(BuildContext context) {
    final phase = dig<String>(pu.pod, ['status', 'phase']);
    return Row(mainAxisSize: MainAxisSize.min, children: [
      ResourceLink(pu.ref, label: pu.name),
      if (phase != null && phase != 'Running') ...[const SizedBox(width: 4), StatusBadge(phase, dense: true)],
    ]);
  }
}
