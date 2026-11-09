import 'package:flutter/material.dart';

import '../../prometheus/prom_api.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';
import 'alerts_widgets.dart';

/// Silences ending within this window are called out.
const expiringSoon = Duration(hours: 1);

/// Active, pending and recently expired silences, soonest to end first.
class SilencesList extends StatelessWidget {
  final List<Silence> silences;

  /// Current alerts, to show how many each silence mutes.
  final List<PromAlert> alerts;

  /// Null hides Expire (read-only).
  final void Function(Silence s)? onExpire;
  final DateTime? now;

  const SilencesList({super.key, required this.silences, this.alerts = const [], this.onExpire, this.now});

  @override
  Widget build(BuildContext context) {
    final t = now ?? DateTime.now();
    final active = silences.where((s) => s.active).toList();
    final soon = active.where((s) => (s.remaining(t) ?? Duration.zero) <= expiringSoon).toList();
    final later = active.where((s) => !soon.contains(s)).toList();
    final pending = silences.where((s) => s.pending).toList();
    final expired = silences.where((s) => !s.active && !s.pending).take(10).toList();
    final theme = Theme.of(context);

    Widget list(List<Silence> l, {bool muted = false}) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final (i, s) in l.indexed) ...[
            if (i > 0) Divider(height: 1, color: AppColors.of(context).separator),
            SilenceRow(silence: s, alerts: alerts, onExpire: muted ? null : onExpire, now: t, muted: muted),
          ],
        ]);

    if (active.isEmpty && pending.isEmpty) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 28),
          child: Column(children: [
            Icon(Icons.notifications_active_outlined, size: 28, color: theme.hintColor),
            const SizedBox(height: 8),
            Text('No active silences', style: theme.textTheme.bodyMedium),
            const SizedBox(height: 2),
            Text('Silence an alert from the Alerts tab to mute its notifications.', textAlign: TextAlign.center, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ]),
        ),
        if (expired.isNotEmpty)
          DetailSection(title: 'Recently expired', icon: Icons.history, initiallyExpanded: false, trailing: Text('${expired.length}'), child: list(expired, muted: true)),
      ]);
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (soon.isNotEmpty)
        DetailSection(title: 'Expiring within an hour', icon: Icons.timer_outlined, divider: false, trailing: Text('${soon.length}'), child: list(soon)),
      if (later.isNotEmpty)
        DetailSection(title: 'Active', icon: Icons.notifications_off_outlined, divider: soon.isNotEmpty, trailing: Text('${later.length}'), child: list(later)),
      if (pending.isNotEmpty)
        DetailSection(title: 'Scheduled', icon: Icons.schedule, trailing: Text('${pending.length}'), child: list(pending)),
      if (expired.isNotEmpty)
        DetailSection(title: 'Recently expired', icon: Icons.history, initiallyExpanded: false, trailing: Text('${expired.length}'), child: list(expired, muted: true)),
    ]);
  }
}

String _humanDuration(Duration d) {
  if (d.inMinutes < 1) return 'less than a minute';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 48) return d.inMinutes % 60 == 0 ? '${d.inHours}h' : '${d.inHours}h ${d.inMinutes % 60}m';
  return '${d.inDays}d ${d.inHours % 24}h';
}

class SilenceRow extends StatelessWidget {
  final Silence silence;
  final List<PromAlert> alerts;
  final void Function(Silence s)? onExpire;
  final DateTime now;
  final bool muted;
  const SilenceRow({super.key, required this.silence, required this.alerts, required this.now, this.onExpire, this.muted = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final s = silence;
    final remaining = s.remaining(now);
    final end = parseTime(s.endsAt)?.toLocal();
    final start = parseTime(s.startsAt);
    final soon = s.active && remaining != null && remaining <= expiringSoon;
    final muting = alerts.where((a) => a.silencedBy.contains(s.id)).length;
    String two(int n) => n.toString().padLeft(2, '0');
    final endText = end == null ? '' : '${two(end.hour)}:${two(end.minute)}';

    final when = switch (s.state) {
      'active' => remaining == null ? 'ending' : 'ends in ${_humanDuration(remaining)}${endText.isEmpty ? '' : ' ($endText)'}',
      'pending' => start == null ? 'scheduled' : 'starts in ${_humanDuration(start.difference(now))}',
      _ => end == null ? 'expired' : 'ended ${formatAge(end)} ago',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(Icons.notifications_off_outlined, size: 16, color: soon ? severityColor(context, Severity.warn) : theme.hintColor),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final m in s.matchers)
                Container(
                  constraints: const BoxConstraints(maxWidth: 360),
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                  decoration: BoxDecoration(color: chipFill(context), borderRadius: BorderRadius.circular(4)),
                  child: Text('$m', maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11, color: muted ? theme.hintColor : null)),
                ),
            ]),
            if (s.comment.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text(s.comment, style: theme.textTheme.bodySmall?.copyWith(color: muted ? theme.hintColor : null)),
            ],
            const SizedBox(height: 3),
            Wrap(spacing: 10, runSpacing: 2, children: [
              Text(when, style: hint?.copyWith(color: soon ? severityColor(context, Severity.warn) : null, fontWeight: soon ? FontWeight.w500 : null)),
              if (s.createdBy.isNotEmpty) Text('by ${s.createdBy}', style: hint),
              if (s.active) Text(muting == 0 ? 'muting no current alerts' : 'muting $muting alert${muting == 1 ? '' : 's'}', style: hint),
            ]),
          ]),
        ),
        if (onExpire != null && (s.active || s.pending)) ...[
          const SizedBox(width: 8),
          TextRowAction(label: 'Expire', icon: Icons.timer_off_outlined, onPressed: () => onExpire!(s)),
        ],
      ]),
    );
  }
}
