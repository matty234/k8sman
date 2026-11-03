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
  late Future<List<Json>> _pods;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  void _fetch() {
    final ns = widget.ctx.namespace;
    _pods = widget.ctx.api.items(const ResourceRef(resource: 'pods'), namespace: ns);
  }

  @override
  void didUpdateWidget(UsedBySection old) {
    super.didUpdateWidget(old);
    if (old.ctx.name != widget.ctx.name || old.ctx.namespace != widget.ctx.namespace) _fetch();
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<Json>>(
      future: _pods,
      builder: (context, snap) {
        final usages = snap.hasData ? findUsages(snap.data!, kind: widget.kind, name: widget.ctx.name, namespace: widget.ctx.namespace) : null;
        final missing = usages == null ? const <MissingKey>[] : missingKeys(usages, widget.existingKeys);
        return DetailSection(
          title: 'Used by',
          icon: Icons.link,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (missing.isNotEmpty)
              CountPill('${missing.length} missing key${missing.length == 1 ? '' : 's'}',
                  severity: missing.every((m) => m.allOptional) ? Severity.warn : Severity.error),
            if (usages != null) CountPill('${usages.length} pod${usages.length == 1 ? '' : 's'}'),
            RefreshButton(() => setState(_fetch)),
          ]),
          child: () {
            if (snap.hasError) return InlineMessage('Could not list pods: ${snap.error}', isError: true);
            if (usages == null) {
              return const Padding(
                padding: EdgeInsets.all(8),
                child: Center(child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))),
              );
            }
            return _UsageList(usages: usages, missing: missing, existingKeys: widget.existingKeys, kindLabel: widget.kind == RefKind.configMap ? 'ConfigMap' : 'Secret');
          }(),
        );
      },
    );
  }
}

class _UsageList extends StatelessWidget {
  final List<PodUsage> usages;
  final List<MissingKey> missing;
  final Set<String> existingKeys;
  final String kindLabel;
  const _UsageList({required this.usages, required this.missing, required this.existingKeys, required this.kindLabel});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (usages.isEmpty) return InlineMessage('No pods in this namespace reference this $kindLabel.');
    final groups = groupIdentical(usages);
    final err = severityColor(context, Severity.error);
    final warn = severityColor(context, Severity.warn);
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
      for (var gi = 0; gi < groups.length; gi++) ...[
        if (gi > 0 || missing.isNotEmpty) const Divider(height: 12),
        Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Icon(Icons.view_in_ar, size: 14, color: theme.hintColor),
          for (final pu in groups[gi]) _PodLink(pu),
        ]),
        const SizedBox(height: 3),
        for (final u in groups[gi].first.usages)
          Padding(
            padding: const EdgeInsets.only(left: 18, top: 2),
            child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(usageIcon(u.kind), size: 13, color: theme.hintColor)),
              const SizedBox(width: 6),
              Expanded(
                child: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  SegmentText(u.segments),
                  if (u.optional) const StatusBadge('optional', dense: true, severity: Severity.info),
                  if (u.keys.any((k) => !existingKeys.contains(k)))
                    StatusBadge('missing key', dense: true, severity: u.optional ? Severity.warn : Severity.error),
                ]),
              ),
            ]),
          ),
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
