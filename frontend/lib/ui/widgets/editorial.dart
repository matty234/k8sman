/// The open, card-free page style first used by the Overview: a status line,
/// a strip of large light numerals divided by hairlines, sections headed by a
/// small label with a hairline running to their count, problems grouped per
/// area with small severity bars, and unboxed cells with a left hairline.
/// Colour only where something is wrong.
library;

import 'package:flutter/material.dart';

import '../../util/k8s.dart' show Severity;
import '../theme.dart';
import 'common.dart' show Hoverable;

/// Tabular figures, so counts and percentages don't shift as they change.
const tabularFigures = [FontFeature.tabularFigures()];

// ---------------------------------------------------------------------------
// Sections
// ---------------------------------------------------------------------------

/// A section heading: a small semibold label, a hairline running to
/// [trailing], nothing boxed.
class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;

  /// Shows a chevron on hover (and when collapsed).
  final bool? expanded;
  final bool hovered;
  const SectionHeader({super.key, required this.title, this.trailing, this.expanded, this.hovered = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    return SizedBox(
      height: 26,
      child: Row(children: [
        Flexible(
          flex: 0,
          child: Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: sectionTitleStyle(context),
          ),
        ),
        if (expanded != null)
          AnimatedRotation(
            turns: expanded! ? 0.25 : 0,
            duration: const Duration(milliseconds: 120),
            child: Icon(Icons.chevron_right, size: 15, color: hovered || !expanded! ? theme.hintColor : Colors.transparent),
          ),
        const SizedBox(width: 10),
        Expanded(child: Container(height: 1, color: colors.separator.withValues(alpha: 0.75))),
        if (trailing != null) ...[
          const SizedBox(width: 12),
          DefaultTextStyle.merge(style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontFeatures: tabularFigures), child: trailing!),
        ],
      ]),
    );
  }
}

/// The label style of [SectionHeader].
TextStyle? sectionTitleStyle(BuildContext context) {
  final theme = Theme.of(context);
  return theme.textTheme.labelLarge?.copyWith(fontSize: 12.5, fontWeight: FontWeight.w600, letterSpacing: 0.2, color: theme.colorScheme.onSurface.withValues(alpha: 0.86));
}

/// A titled block: [SectionHeader] over [child], collapsible from the header
/// when [collapsible]. [top] is the space above the header.
class EditorialSection extends StatefulWidget {
  final String title;
  final Widget? trailing;
  final Widget child;
  final bool collapsible;
  final bool initiallyExpanded;
  final double top;
  const EditorialSection({
    super.key,
    required this.title,
    required this.child,
    this.trailing,
    this.collapsible = true,
    this.initiallyExpanded = true,
    this.top = 28,
  });

  @override
  State<EditorialSection> createState() => _EditorialSectionState();
}

class _EditorialSectionState extends State<EditorialSection> {
  late bool _expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final header = widget.collapsible
        ? Hoverable(
            onTap: () => setState(() => _expanded = !_expanded),
            builder: (h) => SectionHeader(title: widget.title, trailing: widget.trailing, expanded: _expanded, hovered: h),
          )
        : SectionHeader(title: widget.title, trailing: widget.trailing);
    return Padding(
      padding: EdgeInsets.only(top: widget.top),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        header,
        if (_expanded) Padding(padding: const EdgeInsets.only(top: 8), child: widget.child),
      ]),
    );
  }
}

/// A quiet grey bar standing in for a value that is still loading.
class SkeletonBar extends StatelessWidget {
  final double? width;
  final double height;
  const SkeletonBar({super.key, this.width, this.height = 12});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: Theme.of(context).colorScheme.outlineVariant.withValues(alpha: 0.4), borderRadius: BorderRadius.circular(4)),
    );
  }
}

/// A thin horizontal bar: [frac] of the track filled with [color], and
/// optionally [under] (e.g. requests behind usage) in a fainter tint.
class HairlineBar extends StatelessWidget {
  final double frac;
  final double? under;
  final Color color;
  final double height;
  const HairlineBar({super.key, required this.frac, required this.color, this.under, this.height = 3});

  @override
  Widget build(BuildContext context) {
    final track = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    Widget fill(double f, Color c) => FractionallySizedBox(
          alignment: Alignment.centerLeft,
          widthFactor: f.clamp(0.0, 1.0),
          child: DecoratedBox(decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(height))),
        );
    return ClipRRect(
      borderRadius: BorderRadius.circular(height),
      child: SizedBox(
        height: height,
        child: Stack(fit: StackFit.expand, children: [
          ColoredBox(color: track),
          if (under != null) fill(under!, color.withValues(alpha: 0.35)),
          fill(frac, color),
        ]),
      ),
    );
  }
}

/// Lays [children] out in rows of [cols] equal-width cells, each row as tall
/// as its tallest cell.
Widget evenGrid(List<Widget> children, int cols, {double gap = 10, double runGap = 10}) {
  return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    for (var r = 0; r < children.length; r += cols) ...[
      if (r > 0) SizedBox(height: runGap),
      IntrinsicHeight(
        child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (var c = 0; c < cols; c++) ...[
            if (c > 0) SizedBox(width: gap),
            Expanded(child: r + c < children.length ? children[r + c] : const SizedBox.shrink()),
          ],
        ]),
      ),
    ],
  ]);
}

// ---------------------------------------------------------------------------
// Status line
// ---------------------------------------------------------------------------

/// How a page's subject is: a mark, a headline ("All healthy", "Needs
/// attention"), a detail beside it ("13 critical · 17 warnings") and an
/// optional quiet line under it.
class StatusLine extends StatelessWidget {
  final Widget mark;
  final String headline;
  final Widget? detail;
  final String? note;

  /// Draws [note] in the faint colour rather than the hint one, e.g. for
  /// what is fine listed beside problems.
  final bool faintNote;
  const StatusLine({super.key, required this.mark, required this.headline, this.detail, this.note, this.faintNote = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = theme.textTheme.titleLarge?.copyWith(fontSize: 19, fontWeight: FontWeight.w600, letterSpacing: -0.2, height: 1.2);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(crossAxisAlignment: CrossAxisAlignment.center, children: [
        SizedBox(width: 22, child: Align(alignment: Alignment.centerLeft, child: mark)),
        Flexible(flex: 0, child: Text(headline, maxLines: 1, overflow: TextOverflow.ellipsis, style: title)),
        if (detail != null) ...[
          const SizedBox(width: 14),
          Flexible(
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: DefaultTextStyle.merge(maxLines: 1, overflow: TextOverflow.ellipsis, style: statusDetailStyle(context), child: detail!),
            ),
          ),
        ],
      ]),
      if (note != null && note!.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 22, top: 4),
          child: Text(note!, style: theme.textTheme.bodySmall?.copyWith(color: faintNote ? AppColors.of(context).faint : theme.hintColor)),
        ),
    ]);
  }
}

/// The style of a [StatusLine]'s detail.
TextStyle? statusDetailStyle(BuildContext context) {
  final theme = Theme.of(context);
  return theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor, fontFeatures: tabularFigures);
}

/// The mark of a [StatusLine]: a check when [severity] is ok; a hollow ring
/// for neutral/info (still checking); a dot in the severity colour
/// otherwise. An error dot sends out a few slow rings when it appears (none
/// with reduced motion), then rests: nothing animates on an idle page.
class StatusMark extends StatefulWidget {
  final Severity severity;
  const StatusMark({super.key, required this.severity});

  @override
  State<StatusMark> createState() => _StatusMarkState();
}

class _StatusMarkState extends State<StatusMark> with SingleTickerProviderStateMixin {
  static const _rings = 3;
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1800 * _rings));

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybePulse(null);
  }

  @override
  void didUpdateWidget(StatusMark old) {
    super.didUpdateWidget(old);
    _maybePulse(old.severity);
  }

  void _maybePulse(Severity? before) {
    final reduce = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.severity == Severity.error && before != Severity.error && !reduce && !_c.isAnimating) _c.forward(from: 0);
    if (widget.severity != Severity.error) _c.stop();
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.severity;
    if (s == Severity.ok) return Icon(Icons.check_circle, size: 16, color: severityColor(context, Severity.ok));
    final hollow = s == Severity.info || s == Severity.neutral;
    final color = hollow ? Theme.of(context).hintColor : severityColor(context, s);
    final dot = Container(width: 9, height: 9, decoration: BoxDecoration(color: hollow ? null : color, shape: BoxShape.circle, border: hollow ? Border.all(color: color, width: 1.5) : null));
    if (s != Severity.error) return dot;
    return SizedBox(
      width: 9,
      height: 9,
      child: AnimatedBuilder(
        animation: _c,
        builder: (context, child) {
          final t = _c.isAnimating ? (_c.value * _rings) % 1 : 0.0;
          return Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
            if (t > 0)
              Positioned(
                left: -6 * t,
                top: -6 * t,
                right: -6 * t,
                bottom: -6 * t,
                child: DecoratedBox(decoration: BoxDecoration(shape: BoxShape.circle, color: color.withValues(alpha: 0.35 * (1 - t)))),
              ),
            child!,
          ]);
        },
        child: dot,
      ),
    );
  }
}

/// "✓ All 7 workloads healthy · No failing jobs".
class HealthyLines extends StatelessWidget {
  final List<String> lines;
  final TextStyle? style;
  const HealthyLines({super.key, required this.lines, this.style});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = this.style ?? theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final ok = severityColor(context, Severity.ok).withValues(alpha: 0.85);
    final faint = AppColors.of(context).faint;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.check, size: 13, color: ok)),
      const SizedBox(width: 8),
      Expanded(
        child: Wrap(runSpacing: 2, children: [
          for (final (i, l) in lines.indexed) ...[
            if (i > 0) Text('  ·  ', style: style?.copyWith(color: faint)),
            Text(l, style: style),
          ],
        ]),
      ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Stat strip
// ---------------------------------------------------------------------------

/// One figure of a [StatStrip].
class StatItem {
  final String label;

  /// The big figure ("12"); null while loading (a placeholder stands in).
  final String? value;

  /// Small after the figure ("/ 14"), e.g. the total of a shortfall.
  final String? of;

  /// After the label, faint ("+3 completed").
  final String? note;

  /// Colours the figure (and the note, with [noteTone]) and draws a short
  /// bar of [frac] under it: Severity.warn or Severity.error. Null: plain.
  final Severity? tone;
  final double? frac;
  final bool noteTone;

  /// Clicking the figure; null: not clickable.
  final VoidCallback? onTap;
  final String? tooltip;

  /// Keys the clickable block (default `stat-<label>`) and the pending one
  /// (default `pending-stat-<label>`).
  final Key? key;
  final Key? pendingKey;

  const StatItem(
    this.label,
    this.value, {
    this.of,
    this.note,
    this.tone,
    this.frac,
    this.noteTone = false,
    this.onTap,
    this.tooltip,
    this.key,
    this.pendingKey,
  });

  bool get pending => value == null;
}

/// One row of large light numerals with small labels, divided by thin
/// vertical hairlines; more than fit flow evenly onto further rows. A
/// healthy figure shows plain; one with a [StatItem.tone] is coloured with a
/// short bar under it.
class StatStrip extends StatelessWidget {
  final List<StatItem> items;
  final double minCell;
  final double maxCell;
  const StatStrip({super.key, required this.items, this.minCell = 124, this.maxCell = 200});

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final separator = AppColors.of(context).separator;
    return LayoutBuilder(builder: (context, box) {
      final n = items.length;
      final fit = (box.maxWidth / minCell).floor().clamp(1, 8);
      // More than fit: spread evenly over the rows. Fewer: each keeps a
      // comfortable width, left-aligned, rather than stretching apart.
      final rows = (n / fit).ceil();
      final cols = (n / rows).ceil();
      final width = rows > 1 ? box.maxWidth / cols : (box.maxWidth / n).clamp(minCell, maxCell);
      return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var r = 0; r < n; r += cols) ...[
          if (r > 0) const SizedBox(height: 14),
          IntrinsicHeight(
            child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (var i = r; i < r + cols && i < n; i++)
                Container(
                  width: width,
                  padding: EdgeInsets.only(left: i == r ? 0 : 16, right: 8),
                  decoration: i == r ? null : BoxDecoration(border: Border(left: BorderSide(color: separator))),
                  child: _StatBlock(item: items[i]),
                ),
            ]),
          ),
        ],
      ]);
    });
  }
}

class _StatBlock extends StatelessWidget {
  final StatItem item;
  const _StatBlock({required this.item});

  @override
  Widget build(BuildContext context) {
    final onTap = item.onTap;
    final block = item.pending || onTap == null
        ? _block(context, hovered: false)
        : Hoverable(
            key: item.key ?? ValueKey('stat-${item.label}'),
            onTap: onTap,
            builder: (hovered) => _block(context, hovered: hovered),
          );
    if (item.pending || item.tooltip == null) return block;
    return Tooltip(message: item.tooltip!, waitDuration: const Duration(milliseconds: 600), child: block);
  }

  Widget _block(BuildContext context, {required bool hovered}) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final tone = item.tone;
    final color = tone == null ? null : severityColor(context, tone);
    final big = theme.textTheme.headlineMedium?.copyWith(
      fontSize: 30,
      height: 1.1,
      fontWeight: FontWeight.w300,
      letterSpacing: -0.5,
      fontFeatures: tabularFigures,
      color: color ?? theme.colorScheme.onSurface,
    );
    final label = theme.textTheme.bodySmall?.copyWith(
      color: hovered ? theme.colorScheme.onSurface : theme.hintColor,
      decoration: hovered ? TextDecoration.underline : null,
      decorationColor: theme.hintColor,
    );
    return Column(
      key: item.pending ? (item.pendingKey ?? ValueKey('pending-stat-${item.label}')) : null,
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          height: 34,
          child: item.pending
              ? const Align(alignment: Alignment.centerLeft, child: SkeletonBar(width: 44, height: 22))
              : Text.rich(
                  TextSpan(children: [
                    TextSpan(text: item.value, style: big),
                    if (item.of != null) TextSpan(text: ' ${item.of}', style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w400, color: theme.hintColor, fontFeatures: tabularFigures)),
                  ]),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
        ),
        const SizedBox(height: 3),
        Text.rich(
          TextSpan(children: [
            TextSpan(text: item.label),
            if (item.note != null) TextSpan(text: ' · ${item.note}', style: TextStyle(color: item.noteTone && color != null ? color : colors.faint, decoration: TextDecoration.none)),
          ]),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: label,
        ),
        // Only a shortfall gets a bar: healthy is the plain number.
        if (color != null && item.frac != null) ...[
          const SizedBox(height: 7),
          SizedBox(width: 56, child: HairlineBar(frac: item.frac!, color: color, height: 2.5)),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Attention: problems grouped per area
// ---------------------------------------------------------------------------

/// Groups (usually [AttentionGroup]s) one under another with hairlines
/// between; wide lists flow them into two columns, each group going to the
/// shorter column. [weights] (one per group, e.g. its row count) balance the
/// columns.
class AttentionList extends StatelessWidget {
  final List<Widget> groups;
  final List<int>? weights;

  /// From this width the groups go into two columns.
  final double twoColumnsFrom;
  const AttentionList({super.key, required this.groups, this.weights, this.twoColumnsFrom = 1040});

  @override
  Widget build(BuildContext context) {
    final separator = AppColors.of(context).separator.withValues(alpha: 0.6);
    return LayoutBuilder(builder: (context, box) {
      final cols = box.maxWidth >= twoColumnsFrom && groups.length > 1 ? 2 : 1;
      final columns = List.generate(cols, (_) => <Widget>[]);
      final heights = List.filled(cols, 0);
      for (final (i, w) in groups.indexed) {
        var c = 0;
        for (var k = 1; k < cols; k++) {
          if (heights[k] < heights[c]) c = k;
        }
        columns[c].add(w);
        heights[c] += weights?[i] ?? 1;
      }
      Widget column(List<Widget> items) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final (i, w) in items.indexed) ...[
              if (i > 0) Divider(height: 1, thickness: 1, color: separator),
              w,
            ],
          ]);
      if (cols == 1) return column(columns[0]);
      return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: column(columns[0])),
        const SizedBox(width: 48),
        Expanded(child: column(columns[1])),
      ]);
    });
  }
}

/// One area of problems: its icon, name and total in a narrow left gutter
/// with its [rows] beside it; when there isn't room, the name sits on top.
class AttentionGroup extends StatelessWidget {
  final IconData icon;
  final String title;

  /// The area's total, in the colour of its worst problem ([countColor]).
  final int? count;
  final Color? countColor;

  /// Clicking the name; [titleKey] keys that click target.
  final VoidCallback? onTitleTap;
  final String? titleTooltip;
  final Key? titleKey;
  final Widget rows;

  /// The gutter's width, and the width below which the name goes on top.
  final double gutter;
  final double stackBelow;
  const AttentionGroup({
    super.key,
    required this.icon,
    required this.title,
    required this.rows,
    this.count,
    this.countColor,
    this.onTitleTap,
    this.titleTooltip,
    this.titleKey,
    this.gutter = 128,
    this.stackBelow = 420,
  });

  Widget _title(BuildContext context) {
    final theme = Theme.of(context);
    Widget row(bool hovered) => Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: hovered ? theme.colorScheme.onSurface : theme.hintColor),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: theme.textTheme.titleSmall?.copyWith(
                fontSize: 13,
                decoration: hovered ? TextDecoration.underline : null,
                decorationColor: theme.hintColor,
              ),
            ),
          ),
        ]);
    if (onTitleTap == null) return row(false);
    return Hoverable(
      key: titleKey,
      onTap: onTitleTap,
      builder: (hovered) => Tooltip(message: titleTooltip ?? 'Open $title', waitDuration: const Duration(milliseconds: 600), child: row(hovered)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = this.count == null
        ? null
        : Text(
            '${this.count}',
            style: theme.textTheme.titleLarge?.copyWith(fontSize: 20, height: 1.1, fontWeight: FontWeight.w300, color: countColor, fontFeatures: tabularFigures),
          );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: LayoutBuilder(builder: (context, box) {
        if (box.maxWidth >= stackBelow) {
          return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: gutter,
              child: Padding(
                padding: const EdgeInsets.only(top: 3, right: 12),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  _title(context),
                  if (count != null) ...[const SizedBox(height: 4), Padding(padding: const EdgeInsets.only(left: 21), child: count)],
                ]),
              ),
            ),
            Expanded(child: rows),
          ]);
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(children: [
              Expanded(child: Align(alignment: Alignment.centerLeft, child: _title(context))),
              ?count,
            ]),
          ),
          rows,
        ]);
      }),
    );
  }
}

/// "▎4  CrashLoopBackOff · 4 pods, 2 workloads": a short severity bar
/// (hollow for info and neutral), a count, a label and a quieter detail
/// that an ellipsis cuts first. [onTap] opens what the row names; [onCount]
/// (when given) makes the count its own target.
class AttentionRow extends StatelessWidget {
  final Severity severity;
  final String? count;
  final String label;
  final String? detail;
  final bool selected;
  final VoidCallback? onTap;
  final VoidCallback? onCount;
  final String? countTooltip;
  final Key? countKey;

  /// A chevron on hover (for rows that open something).
  final bool chevron;

  /// After the text, e.g. a small badge.
  final Widget? trailing;
  const AttentionRow({
    super.key,
    required this.severity,
    required this.label,
    this.count,
    this.detail,
    this.selected = false,
    this.onTap,
    this.onCount,
    this.countTooltip,
    this.countKey,
    this.chevron = false,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final quiet = severity == Severity.info || severity == Severity.neutral;
    final hint = theme.textTheme.bodySmall?.copyWith(color: quiet ? colors.faint : theme.hintColor);
    Widget? countText = count == null
        ? null
        : Text(
            count!,
            style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600, fontFeatures: tabularFigures, color: quiet ? theme.hintColor : null),
          );
    if (countText != null && onCount != null) {
      countText = GestureDetector(key: countKey, behavior: HitTestBehavior.opaque, onTap: onCount, child: countText);
    }
    if (countText != null && countTooltip != null) {
      countText = Tooltip(message: countTooltip!, waitDuration: const Duration(milliseconds: 600), child: countText);
    }
    Widget build(bool hovered) => Container(
          padding: const EdgeInsets.fromLTRB(8, 4, 6, 4),
          decoration: BoxDecoration(
            color: selected ? colors.selection : (hovered && onTap != null ? colors.hover : null),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Row(children: [
            SeverityBar(severity: severity),
            const SizedBox(width: 10),
            if (countText != null) ...[SizedBox(width: 22, child: countText), const SizedBox(width: 4)],
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: label, style: TextStyle(color: quiet ? theme.hintColor : theme.colorScheme.onSurface)),
                  if (detail != null && detail!.isNotEmpty) TextSpan(text: ' · $detail', style: hint),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(fontSize: 12.5),
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 8), trailing!],
            if (chevron) Icon(Icons.chevron_right, size: 14, color: hovered ? theme.hintColor : Colors.transparent),
          ]),
        );
    if (onTap == null) return build(false);
    return Hoverable(onTap: onTap, builder: build);
  }
}

/// The severity marker of an [AttentionRow]: a short bar, hollow for info
/// and neutral.
class SeverityBar extends StatelessWidget {
  final Severity severity;
  final double height;
  const SeverityBar({super.key, required this.severity, this.height = 13});

  @override
  Widget build(BuildContext context) {
    final quiet = severity == Severity.info || severity == Severity.neutral;
    final faint = AppColors.of(context).faint;
    return Container(
      width: 3,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(2),
        color: quiet ? null : severityColor(context, severity),
        border: quiet ? Border.all(color: faint) : null,
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Cells and figures
// ---------------------------------------------------------------------------

/// An unboxed cell: a hairline down the left, in [accent] when something is
/// wrong (separator grey otherwise), with a hover tint when [onTap] is set.
class HairlineCell extends StatelessWidget {
  final Widget child;
  final Color? accent;
  final VoidCallback? onTap;
  final EdgeInsetsGeometry padding;
  const HairlineCell({super.key, required this.child, this.accent, this.onTap, this.padding = const EdgeInsets.fromLTRB(12, 4, 6, 6)});

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    final cell = Container(
      decoration: BoxDecoration(border: Border(left: BorderSide(color: accent ?? colors.separator, width: 2))),
      padding: padding,
      child: child,
    );
    if (onTap == null) return cell;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(onTap: onTap, hoverColor: colors.hover, borderRadius: BorderRadius.circular(4), child: cell),
    );
  }
}

/// A big light figure with its unit after it in small type: "29% in use",
/// "1.8 cores · 15% of allocatable".
class BigFigure extends StatelessWidget {
  final String value;
  final String unit;
  final String? suffix;
  final Color? color;
  const BigFigure(this.value, this.unit, {super.key, this.suffix, this.color});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontFeatures: tabularFigures);
    return Text.rich(
      TextSpan(children: [
        TextSpan(
          text: value,
          style: theme.textTheme.headlineSmall?.copyWith(fontSize: 26, height: 1.15, fontWeight: FontWeight.w300, letterSpacing: -0.4, fontFeatures: tabularFigures, color: color),
        ),
        if (unit.isNotEmpty) TextSpan(text: ' $unit', style: hint?.copyWith(fontSize: 12.5)),
        if (suffix != null) TextSpan(text: '  ·  $suffix', style: hint?.copyWith(fontSize: 12.5)),
      ]),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// The small caption over a [BigFigure] ("CPU", "Memory").
class FigureCaption extends StatelessWidget {
  final String label;
  const FigureCaption(this.label, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600, letterSpacing: 0.3));
  }
}

/// A heading row that fits narrow places: [title], an optional [chevron]
/// after it, and a hairline (when [rule]) running from there to [trailing].
/// [trailing] keeps its width; the title gives way with its own ellipsis.
class TitleRule extends StatelessWidget {
  final Widget title;
  final Widget? chevron;
  final Widget? trailing;
  final bool rule;
  const TitleRule({super.key, required this.title, this.chevron, this.trailing, this.rule = true});

  @override
  Widget build(BuildContext context) {
    return CustomMultiChildLayout(delegate: _TitleRuleLayout(), children: [
      LayoutId(id: _Slot.title, child: title),
      if (chevron != null) LayoutId(id: _Slot.chevron, child: chevron!),
      if (rule) LayoutId(id: _Slot.rule, child: Container(height: 1, color: AppColors.of(context).separator.withValues(alpha: 0.75))),
      if (trailing != null) LayoutId(id: _Slot.trailing, child: trailing!),
    ]);
  }
}

enum _Slot { title, chevron, rule, trailing }

class _TitleRuleLayout extends MultiChildLayoutDelegate {
  @override
  void performLayout(Size size) {
    final w = size.width;
    final h = size.height;
    double centre(Size s) => (h - s.height) / 2;
    var right = w;
    if (hasChild(_Slot.trailing)) {
      final s = layoutChild(_Slot.trailing, BoxConstraints(maxWidth: w * 0.7, maxHeight: h));
      positionChild(_Slot.trailing, Offset(w - s.width, centre(s)));
      right = w - s.width - 10;
    }
    Size? chevron;
    if (hasChild(_Slot.chevron)) chevron = layoutChild(_Slot.chevron, BoxConstraints(maxWidth: w, maxHeight: h));
    final t = layoutChild(_Slot.title, BoxConstraints(maxWidth: (right - (chevron?.width ?? 0)).clamp(0.0, w), maxHeight: h));
    positionChild(_Slot.title, Offset(0, centre(t)));
    var x = t.width;
    if (chevron != null) {
      positionChild(_Slot.chevron, Offset(x, centre(chevron)));
      x += chevron.width;
    }
    if (hasChild(_Slot.rule)) {
      final left = x + 6;
      layoutChild(_Slot.rule, BoxConstraints.tightFor(width: (right - left).clamp(0.0, w), height: 1));
      positionChild(_Slot.rule, Offset(left, (h - 1) / 2));
    }
  }

  @override
  bool shouldRelayout(_TitleRuleLayout oldDelegate) => false;
}
