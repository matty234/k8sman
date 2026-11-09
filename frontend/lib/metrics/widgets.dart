import 'package:flutter/material.dart';

import '../addons/addons.dart';
import '../ui/theme.dart';
import '../util/k8s.dart';
import 'metrics_api.dart';
import 'quantity.dart';

/// Fill colour for a utilisation fraction: neutral below 70%, amber ≥ 70%,
/// red ≥ 90% (colour is reserved for thresholds).
Color meterColor(BuildContext context, double? frac) {
  final sev = thresholdSeverity(frac);
  if (sev == Severity.neutral) return Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.42);
  return severityColor(context, sev);
}

/// Text colour for a percentage readout (plain text below the thresholds).
Color? percentColor(BuildContext context, double? frac) {
  final sev = thresholdSeverity(frac);
  return sev == Severity.neutral ? null : severityColor(context, sev);
}

/// A two-layer bar: actual usage filled, requests outlined, limit as a tick.
///
/// `label  [▓▓▓▓░[    ]░░░|░░]  valueText  42%`
///
/// [scale] is the bar's full width in the same unit (e.g. node allocatable);
/// when null it fits the largest of used/requested/limit. The percentage is
/// `used / percentBase` and drives the threshold colour.
class ResourceMeter extends StatelessWidget {
  final String label;
  final double? used;
  final double? requested;
  final double? limit;
  final double? scale;
  final double? percentBase;

  /// What [percentBase] is, for the tooltip ("allocatable", "request", "limit").
  final String percentOf;
  final String valueText;
  final String Function(double) format;
  final double labelWidth;
  final double valueWidth;
  final bool compact;

  const ResourceMeter({
    super.key,
    required this.label,
    required this.used,
    this.requested,
    this.limit,
    this.scale,
    this.percentBase,
    this.percentOf = 'capacity',
    required this.valueText,
    required this.format,
    this.labelWidth = 100,
    this.valueWidth = 130,
    this.compact = false,
  });

  double get _scale {
    final s = scale;
    if (s != null && s > 0) return s;
    final m = [used ?? 0, requested ?? 0, limit ?? 0].reduce((a, b) => a > b ? a : b);
    return m <= 0 ? 1 : m * 1.15;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final frac = fraction(used, percentBase);
    final small = compact ? 10.5 : 11.0;
    final tip = [
      if (used != null) 'Used ${format(used!)}',
      if (requested != null && requested! > 0) 'Requested ${format(requested!)}',
      if (limit != null && limit! > 0) 'Limit ${format(limit!)}',
      if (scale != null) '${percentOf[0].toUpperCase()}${percentOf.substring(1)} ${format(scale!)}',
      if (frac != null) '${formatPercent(frac)} of $percentOf',
    ].join('\n');
    final labelText = Text(
      label,
      overflow: TextOverflow.ellipsis,
      style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontSize: compact ? 11 : null),
    );
    final bar = Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: SizedBox(
        height: compact ? 10 : 12,
        child: CustomPaint(
          painter: _MeterPainter(
            used: used == null ? null : used! / _scale,
            requested: requested == null || requested! <= 0 ? null : requested! / _scale,
            limit: limit == null || limit! <= 0 ? null : limit! / _scale,
            fill: meterColor(context, frac),
            track: theme.colorScheme.surfaceContainerHighest,
            outline: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            tick: theme.colorScheme.onSurface.withValues(alpha: 0.75),
            barHeight: compact ? 6 : 8,
          ),
        ),
      ),
    );
    final valueLabel = Text(valueText, textAlign: TextAlign.right, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: small));
    final pct = Text(
      frac == null ? '' : formatPercent(frac),
      textAlign: TextAlign.right,
      style: monoStyle(context, size: small, color: percentColor(context, frac) ?? theme.hintColor).copyWith(fontWeight: FontWeight.w600),
    );
    return Padding(
      padding: EdgeInsets.symmetric(vertical: compact ? 2 : 3),
      child: LayoutBuilder(builder: (context, box) {
        // Narrow (a slim inspector): label, value and percent on one line,
        // the bar full width beneath, rather than overflowing the row.
        if (box.maxWidth < labelWidth + valueWidth + 40 + 8 + 60) {
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              labelText,
              const SizedBox(width: 8),
              Expanded(child: valueLabel),
              SizedBox(width: 40, child: pct),
            ]),
            const SizedBox(height: 2),
            bar,
          ]);
        }
        return Row(children: [
          SizedBox(width: labelWidth, child: labelText),
          Expanded(child: bar),
          const SizedBox(width: 8),
          SizedBox(width: valueWidth, child: valueLabel),
          SizedBox(width: 40, child: pct),
        ]);
      }),
    );
  }
}

class _MeterPainter extends CustomPainter {
  final double? used;
  final double? requested;
  final double? limit;
  final Color fill;
  final Color track;
  final Color outline;
  final Color tick;
  final double barHeight;
  const _MeterPainter({
    this.used,
    this.requested,
    this.limit,
    required this.fill,
    required this.track,
    required this.outline,
    required this.tick,
    required this.barHeight,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final top = (size.height - barHeight) / 2;
    final r = Radius.circular(barHeight / 2.5);
    final w = size.width;
    canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, top, w, barHeight), r), Paint()..color = track);
    final u = used;
    if (u != null && u > 0) {
      final x = (u.clamp(0.0, 1.0) * w).clamp(2.0, w);
      canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromLTWH(0, top, x, barHeight), r), Paint()..color = fill);
    }
    final q = requested;
    if (q != null) {
      final x = (q.clamp(0.0, 1.0) * w).clamp(2.0, w);
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromLTWH(0.5, top + 0.5, x - 1, barHeight - 1), r),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1
          ..color = outline,
      );
    }
    final l = limit;
    if (l != null && l <= 1) {
      final x = (l * w).clamp(1.0, w - 1);
      canvas.drawRect(Rect.fromLTWH(x - 1, 0, 2, size.height), Paint()..color = tick);
    }
  }

  @override
  bool shouldRepaint(_MeterPainter o) =>
      o.used != used || o.requested != requested || o.limit != limit || o.fill != fill || o.track != track || o.outline != outline;
}

/// Tiny legend for [ResourceMeter]: used / requested / limit.
class MeterLegend extends StatelessWidget {
  final bool showLimit;
  const MeterLegend({super.key, this.showLimit = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    final ink = theme.colorScheme.onSurface;
    Widget swatch({required bool filled}) => Container(
      width: 12,
      height: 7,
      decoration: BoxDecoration(
        color: filled ? ink.withValues(alpha: 0.42) : null,
        border: filled ? null : Border.all(color: ink.withValues(alpha: 0.55)),
        borderRadius: BorderRadius.circular(2),
      ),
    );
    return Wrap(
      spacing: 10,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            swatch(filled: true),
            const SizedBox(width: 4),
            Text('used', style: style),
          ],
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            swatch(filled: false),
            const SizedBox(width: 4),
            Text('requested', style: style),
          ],
        ),
        if (showLimit)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(width: 2, height: 10, color: ink.withValues(alpha: 0.75)),
              const SizedBox(width: 4),
              Text('limit', style: style),
            ],
          ),
      ],
    );
  }
}

/// A subtle one-line note for when resource metrics can't be shown, with an
/// install link when metrics-server is missing.
class MetricsUnavailableNote extends StatelessWidget {
  final Object? error;
  const MetricsUnavailableNote(this.error, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final e = error;
    final notInstalled = e is MetricsUnavailable && e.state == MetricsState.notInstalled;
    final notReady = e is MetricsUnavailable && e.state == MetricsState.notReady;
    final text = notInstalled
        ? 'Metrics unavailable'
        : notReady
        ? 'Metrics not ready yet: metrics-server has no samples'
        : 'Metrics unavailable: $e';
    return Row(
      children: [
        Icon(Icons.query_stats, size: 13, color: theme.hintColor),
        const SizedBox(width: 6),
        Flexible(
          child: Tooltip(
            message: '$e',
            child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: style),
          ),
        ),
        if (notInstalled) ...[Text(' · ', style: style), InstallMetricsServerLink(style: style)],
      ],
    );
  }
}

/// "Install metrics-server" link opening the add-on flow.
class InstallMetricsServerLink extends StatelessWidget {
  final TextStyle? style;
  const InstallMetricsServerLink({super.key, this.style});

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => requestAddon(context, AddonIds.metricsServer),
        child: SelectionContainer.disabled(child: Text('Install metrics-server', style: (style ?? const TextStyle()).copyWith(color: accent))),
      ),
    );
  }
}
