import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../api/models.dart';
import '../../prometheus/prom_api.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';

Color alertSeverityColor(BuildContext context, AlertSeverity s) => severityColor(context, s.badge);

IconData alertSeverityIcon(AlertSeverity s) => switch (s) {
      AlertSeverity.critical => Icons.error,
      AlertSeverity.warning => Icons.warning_amber_rounded,
      AlertSeverity.info => Icons.info_outline,
      AlertSeverity.none => Icons.radio_button_unchecked,
    };

String alertStateLabel(AlertState s) => switch (s) {
      AlertState.firing => 'Firing',
      AlertState.pending => 'Pending',
      AlertState.silenced => 'Silenced',
      AlertState.inhibited => 'Inhibited',
    };

/// Colour only for state that needs attention: firing takes the severity's
/// colour; pending is amber-ish; silenced / inhibited stay neutral.
Severity alertStateBadge(AlertState s, AlertSeverity sev) => switch (s) {
      AlertState.firing => sev.badge,
      AlertState.pending => Severity.warn,
      _ => Severity.neutral,
    };

/// Labels shown first on an instance, in this order.
const importantLabels = ['namespace', 'pod', 'container', 'node', 'job', 'deployment', 'statefulset', 'daemonset', 'service', 'instance'];

/// Labels hidden on instances (shown elsewhere or pure noise).
const hiddenLabels = {'alertname', 'severity', 'prometheus', 'prometheus_replica', 'endpoint'};

List<MapEntry<String, String>> orderedLabels(Map<String, String> labels) {
  final out = <MapEntry<String, String>>[];
  for (final k in importantLabels) {
    final v = labels[k];
    if (v != null && v.isNotEmpty) out.add(MapEntry(k, v));
  }
  final rest = labels.entries.where((e) => !importantLabels.contains(e.key) && !hiddenLabels.contains(e.key)).toList()
    ..sort((a, b) => a.key.compareTo(b.key));
  return [...out, ...rest];
}

/// Opens a Kubernetes object from an alert (replaces the sidebar stack).
void openAlertTarget(BuildContext context, ObjectRef ref) {
  final app = context.read<AppState>();
  final t = app.typeFor(ref.group, ref.kind);
  if (t == null) return;
  app.openDetail(DetailTarget(type: t, name: ref.name, namespace: t.namespaced ? ref.namespace : null));
}

Future<void> openUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri != null) await launchUrl(uri);
}

/// Severity name in a quiet pill.
class SeverityPill extends StatelessWidget {
  final AlertSeverity severity;
  final String label;
  const SeverityPill(this.severity, this.label, {super.key});

  @override
  Widget build(BuildContext context) => StatusBadge(label.isEmpty ? 'no severity' : label, dense: true, severity: severity.badge);
}

/// Compact `key=value` chips, the important ones first, collapsed after [max].
class AlertLabelChips extends StatefulWidget {
  final Map<String, String> labels;
  final int max;
  const AlertLabelChips(this.labels, {super.key, this.max = 6});

  @override
  State<AlertLabelChips> createState() => _AlertLabelChipsState();
}

class _AlertLabelChipsState extends State<AlertLabelChips> {
  bool _all = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = orderedLabels(widget.labels);
    final shown = _all ? entries : entries.take(widget.max).toList();
    final small = theme.textTheme.labelSmall;
    return Wrap(spacing: 4, runSpacing: 4, children: [
      for (final e in shown)
        Container(
          constraints: const BoxConstraints(maxWidth: 320),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
          decoration: BoxDecoration(color: chipFill(context), borderRadius: BorderRadius.circular(4)),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '${e.key}=', style: small?.copyWith(color: theme.hintColor)),
              TextSpan(text: e.value, style: small),
            ]),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      if (entries.length > widget.max)
        Hoverable(
          onTap: () => setState(() => _all = !_all),
          builder: (h) => Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1.5),
            child: Text(_all ? 'fewer' : '+${entries.length - widget.max} more',
                style: small?.copyWith(color: h ? theme.colorScheme.primary : theme.hintColor)),
          ),
        ),
    ]);
  }
}

/// "Pod demo/crashy" link to the object an alert is about.
class AlertTargetLink extends StatelessWidget {
  final ObjectRef ref;
  const AlertTargetLink(this.ref, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final known = context.read<AppState>().typeFor(ref.group, ref.kind) != null;
    final name = ref.namespace == null || ref.kind == 'Namespace' ? ref.name : '${ref.namespace}/${ref.name}';
    final text = Text.rich(
      TextSpan(children: [
        TextSpan(text: '${ref.kind} ', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        TextSpan(text: name, style: theme.textTheme.bodySmall?.copyWith(color: known ? theme.colorScheme.primary : null, fontWeight: FontWeight.w500)),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    if (!known) return text;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(onTap: () => openAlertTarget(context, ref), child: Tooltip(message: 'Open ${ref.kind} ${ref.name}', child: text)),
    );
  }
}

/// A small text button for row actions.
class RowAction extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final String? tooltip;
  const RowAction({super.key, required this.label, required this.icon, this.onPressed, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final b = TextButton.icon(
      onPressed: onPressed,
      icon: Icon(icon, size: 14),
      label: Text(label),
      style: TextButton.styleFrom(
        visualDensity: VisualDensity.compact,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        minimumSize: const Size(0, 24),
        textStyle: Theme.of(context).textTheme.bodySmall,
      ),
    );
    return tooltip == null ? b : Tooltip(message: tooltip!, child: b);
  }
}

/// One alertname: header row (expandable) and its instances.
class AlertGroupTile extends StatelessWidget {
  final AlertGroup group;

  /// The instances to show (already filtered).
  final List<PromAlert> alerts;
  final bool expanded;
  final VoidCallback onToggle;

  /// Null hides the Silence… actions (read-only, or no Alertmanager).
  final void Function(String alertname, List<PromAlert> alerts)? onSilenceGroup;
  final void Function(PromAlert alert)? onSilenceAlert;

  const AlertGroupTile({
    super.key,
    required this.group,
    required this.alerts,
    required this.expanded,
    required this.onToggle,
    this.onSilenceGroup,
    this.onSilenceAlert,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final sev = AlertSeverity.parse(alerts.map((a) => a.severityLabel).reduce((a, b) => AlertSeverity.parse(a).index <= AlertSeverity.parse(b).index ? a : b));
    final sevLabel = alerts.map((a) => a.severityLabel).firstWhere((l) => AlertSeverity.parse(l) == sev, orElse: () => '');
    final counts = <AlertState, int>{};
    for (final a in alerts) {
      counts[a.state] = (counts[a.state] ?? 0) + 1;
    }
    final loudest = AlertState.values.firstWhere((s) => (counts[s] ?? 0) > 0, orElse: () => AlertState.firing);
    final muted = loudest == AlertState.silenced || loudest == AlertState.inhibited;
    final iconColor = muted ? theme.hintColor : (loudest == AlertState.pending ? theme.hintColor : alertSeverityColor(context, sev));
    final summary = alerts.map((a) => a.summary ?? a.description).whereType<String>().firstOrNull ?? group.summary;
    final oldest = alerts.map((a) => a.startsAt).whereType<String>().fold<String?>(null, (best, s) {
      final t = parseTime(s), b = parseTime(best);
      return t != null && (b == null || t.isBefore(b)) ? s : best;
    });
    final countText = [
      for (final s in AlertState.values)
        if ((counts[s] ?? 0) > 0) '${counts[s]} ${alertStateLabel(s).toLowerCase()}',
    ].join(' · ');

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InkWell(
        onTap: onToggle,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
          child: LayoutBuilder(builder: (context, box) {
            final narrow = box.maxWidth < 480;
            return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 20, color: theme.hintColor),
              const SizedBox(width: 2),
              Padding(padding: const EdgeInsets.only(top: 1), child: Icon(alertSeverityIcon(sev), size: 17, color: iconColor)),
              const SizedBox(width: 8),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Wrap(spacing: 8, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text(group.alertname, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600, color: muted ? theme.hintColor : null)),
                    SeverityPill(sev, sevLabel),
                    Text(countText, style: hint),
                  ]),
                  if (summary != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 3),
                      child: Text(summary, maxLines: 2, overflow: TextOverflow.ellipsis, style: hint),
                    ),
                ]),
              ),
              const SizedBox(width: 8),
              Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
                if (oldest != null) Tooltip(message: 'Oldest instance started', child: AgeText(oldest, style: hint)),
                if (onSilenceGroup != null && expanded && !narrow && !muted)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: RowAction(
                      label: 'Silence…',
                      icon: Icons.notifications_off_outlined,
                      tooltip: alerts.length > 1 ? 'Silence all ${alerts.length} instances' : null,
                      onPressed: () => onSilenceGroup!(group.alertname, alerts),
                    ),
                  ),
              ]),
            ]);
          }),
        ),
      ),
      if (expanded)
        Padding(
          padding: const EdgeInsets.only(left: 30, bottom: 8),
          child: Container(
            decoration: BoxDecoration(border: Border(left: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.6), width: 2))),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final a in alerts) AlertInstanceRow(alert: a, onSilence: onSilenceAlert),
            ]),
          ),
        ),
    ]);
  }
}

/// One alert instance: state, object link, age, labels, text and actions.
class AlertInstanceRow extends StatelessWidget {
  final PromAlert alert;
  final void Function(PromAlert alert)? onSilence;
  const AlertInstanceRow({super.key, required this.alert, this.onSilence});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final a = alert;
    final desc = a.description;
    final summary = a.summary;
    final silenceable = onSilence != null && (a.state == AlertState.firing || a.state == AlertState.pending);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 7, 4, 7),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 8, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center, children: [
          StatusBadge(alertStateLabel(a.state), dense: true, severity: alertStateBadge(a.state, a.severity)),
          if (a.target != null) AlertTargetLink(a.target!),
          if (a.startsAt != null)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Text(a.state == AlertState.pending ? 'pending for ' : 'active for ', style: hint),
              AgeText(a.startsAt, style: hint),
            ]),
          if (a.source == 'prometheus' && a.state != AlertState.pending) Text('from Prometheus', style: hint),
        ]),
        const SizedBox(height: 5),
        AlertLabelChips(a.labels),
        if (summary != null && summary != desc) ...[
          const SizedBox(height: 5),
          SelectableText(summary, style: theme.textTheme.bodySmall),
        ],
        if (desc != null) ...[
          const SizedBox(height: 3),
          SelectableText(desc, style: hint),
        ],
        if (a.runbookUrl != null || silenceable)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Wrap(spacing: 4, children: [
              if (a.runbookUrl != null)
                RowAction(label: 'Runbook', icon: Icons.menu_book_outlined, tooltip: a.runbookUrl, onPressed: () => openUrl(a.runbookUrl!)),
              if (silenceable) RowAction(label: 'Silence…', icon: Icons.notifications_off_outlined, onPressed: () => onSilence!(a)),
            ]),
          ),
      ]),
    );
  }
}

/// A calm, toggleable filter chip with an optional colour dot and count.
class FilterPill extends StatelessWidget {
  final String label;
  final int? count;
  final bool selected;
  final Color? dot;
  final VoidCallback onTap;
  const FilterPill({super.key, required this.label, required this.selected, required this.onTap, this.count, this.dot});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    return Hoverable(
      onTap: onTap,
      builder: (h) => Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? chipFill(context, hovered: h) : (h ? colors.hover : null),
          border: Border.all(color: selected ? Colors.transparent : colors.separator),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (dot != null) ...[
            Container(width: 7, height: 7, decoration: BoxDecoration(color: selected ? dot : dot!.withValues(alpha: 0.4), shape: BoxShape.circle)),
            const SizedBox(width: 5),
          ],
          Text(label, style: theme.textTheme.bodySmall?.copyWith(color: selected ? theme.colorScheme.onSurface : theme.hintColor)),
          if (count != null) ...[
            const SizedBox(width: 5),
            Text('$count', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600)),
          ],
        ]),
      ),
    );
  }
}
