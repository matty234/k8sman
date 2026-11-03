import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../ui/theme.dart';
import '../../../util/k8s.dart';
import 'util.dart';

/// Visual of desired / current / updated / ready / available / unavailable
/// replicas. Each replica is one cell (or a proportional bar for big counts):
/// green = available, teal = ready but not yet available (minReadySeconds),
/// amber = running but not ready, empty = desired but missing.
/// A thin strip underneath shows how many are on the latest template.
class ReplicaStatusBar extends StatelessWidget {
  final int desired;

  /// Pods that exist (status.replicas). May exceed desired during surge.
  final int current;
  final int? updated;
  final int ready;
  final int? available;

  /// Explicit unavailable count (else derived as desired - available).
  final int? unavailable;

  /// Extra trailing legend entries, e.g. ('misscheduled', 1, Severity.warn).
  final List<(String, int, Severity)> extra;
  final String unit;

  /// Shown at the right of the headline row (e.g. a ScaleControl).
  final Widget? trailing;

  const ReplicaStatusBar({
    super.key,
    required this.desired,
    required this.current,
    required this.ready,
    this.updated,
    this.available,
    this.unavailable,
    this.extra = const [],
    this.unit = 'replicas',
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final okC = severityColor(context, Severity.ok);
    final readyC = const Color(0xFF2DD4BF);
    final warnC = severityColor(context, Severity.warn);
    final errC = severityColor(context, Severity.error);
    final emptyC = theme.colorScheme.outlineVariant;

    final avail = available ?? ready;
    final unavail = unavailable ?? math.max(0, desired - avail);
    final total = math.max(desired, current);
    final headline = desired == 0 && current == 0 ? 'Scaled to 0' : '$ready/$desired ready';
    final headSev = desired == 0
        ? Severity.neutral
        : (ready >= desired && avail >= desired ? Severity.ok : (ready == 0 ? Severity.error : Severity.warn));

    // Cell colours, in order.
    final cells = <Color>[];
    for (var i = 0; i < total; i++) {
      if (i < math.min(avail, ready)) {
        cells.add(okC);
      } else if (i < ready) {
        cells.add(readyC);
      } else if (i < current) {
        cells.add(warnC);
      } else {
        cells.add(emptyC.withValues(alpha: 0.35));
      }
    }

    Widget bar;
    if (total == 0) {
      bar = Container(
        height: 12,
        decoration: BoxDecoration(color: emptyC.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(3)),
      );
    } else if (total <= 40) {
      bar = Row(
        children: [
          for (var i = 0; i < total; i++) ...[
            if (i > 0) const SizedBox(width: 2),
            Expanded(
              child: Container(
                height: 12,
                decoration: BoxDecoration(
                  color: cells[i],
                  borderRadius: BorderRadius.circular(2),
                  border: i >= desired ? Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.5)) : null,
                ),
              ),
            ),
          ],
        ],
      );
    } else {
      // Proportional segments for large counts.
      final counts = <(Color, int)>[];
      for (final c in cells) {
        if (counts.isNotEmpty && counts.last.$1 == c) {
          counts[counts.length - 1] = (c, counts.last.$2 + 1);
        } else {
          counts.add((c, 1));
        }
      }
      bar = ClipRRect(
        borderRadius: BorderRadius.circular(3),
        child: Row(
          children: [
            for (final (c, n) in counts)
              Expanded(
                flex: n,
                child: Container(height: 12, color: c),
              ),
          ],
        ),
      );
    }

    final upd = updated;
    Widget? updatedStrip;
    if (upd != null && total > 0) {
      final frac = (upd / math.max(1, desired)).clamp(0.0, 1.0);
      updatedStrip = Padding(
        padding: const EdgeInsets.only(top: 3),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: SizedBox(
            height: 3,
            child: Row(
              children: [
                if (frac > 0)
                  Expanded(
                    flex: (frac * 1000).round(),
                    child: Container(color: theme.colorScheme.primary),
                  ),
                if (frac < 1)
                  Expanded(
                    flex: ((1 - frac) * 1000).round(),
                    child: Container(color: emptyC.withValues(alpha: 0.3)),
                  ),
              ],
            ),
          ),
        ),
      );
    }

    final small = theme.textTheme.bodySmall;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Text(
              headline,
              style: theme.textTheme.titleSmall?.copyWith(color: severityColor(context, headSev), fontWeight: FontWeight.w700),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                current != desired ? '$current $unit exist · $desired desired' : '$desired desired',
                style: small?.copyWith(color: theme.hintColor),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: 6),
        bar,
        ?updatedStrip,
        const SizedBox(height: 6),
        Wrap(
          spacing: 12,
          runSpacing: 4,
          children: [
            LegendDot(okC, 'available ${available ?? ready}'),
            if (ready > avail) LegendDot(readyC, 'ready $ready'),
            if (ready <= avail) LegendDot(readyC, 'ready $ready', hollow: true),
            if (current > ready) LegendDot(warnC, 'not ready ${current - ready}'),
            if (upd != null) LegendDot(theme.colorScheme.primary, 'updated $upd${upd < desired ? '/$desired' : ''}'),
            _Count(label: 'unavailable', n: unavail, color: unavail > 0 ? errC : theme.hintColor),
            for (final (l, n, s) in extra) _Count(label: l, n: n, color: n > 0 ? severityColor(context, s) : theme.hintColor),
          ],
        ),
      ],
    );
  }
}

class _Count extends StatelessWidget {
  final String label;
  final int n;
  final Color color;
  const _Count({required this.label, required this.n, required this.color});

  @override
  Widget build(BuildContext context) => Text(
    '$label $n',
    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: color, fontWeight: n > 0 ? FontWeight.w600 : null),
  );
}
