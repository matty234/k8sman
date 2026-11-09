/// Small text, copy and layout atoms shared by the panels.
library;

import 'dart:convert';

import 'package:flutter/material.dart';

import '../theme.dart';
import 'common.dart';

/// Muted small text. [style] replaces the base (`bodySmall`); [size] overrides
/// the font size; [mono] renders in the monospace face (11.5 unless [size]).
class HintText extends StatelessWidget {
  final String text;
  final TextStyle? style;
  final double? size;
  final bool mono;
  const HintText(this.text, {super.key, this.style, this.size, this.mono = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (mono) return Text(text, style: monoStyle(context, size: size ?? 11.5, color: theme.hintColor));
    return Text(text, style: (style ?? theme.textTheme.bodySmall)?.copyWith(color: theme.hintColor, fontSize: size));
  }
}

/// Monospace text, optionally with a trailing copy icon ([copy], copying
/// [copyValue] when given). [ellipsis] keeps it on one line.
class MonoText extends StatelessWidget {
  final String text;
  final String? copyValue;
  final bool copy;
  final bool ellipsis;
  final Color? color;
  final double size;
  const MonoText(this.text, {super.key, this.copy = false, this.copyValue, this.ellipsis = false, this.color, this.size = 12});

  /// Table-cell flavour (11.5).
  const MonoText.cell(this.text, {super.key, this.color})
      : copy = false,
        copyValue = null,
        ellipsis = false,
        size = 11.5;

  @override
  Widget build(BuildContext context) {
    final t = Text(text, overflow: ellipsis ? TextOverflow.ellipsis : null, style: monoStyle(context, size: size, color: color));
    if (!copy) return t;
    return Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Flexible(child: t),
      CopyIcon(copyValue ?? text),
    ]);
  }
}

class CopyIcon extends StatelessWidget {
  final String value;
  const CopyIcon(this.value, {super.key});

  @override
  Widget build(BuildContext context) => InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => copyToClipboard(context, value),
        child: Tooltip(
          message: 'Copy',
          child: Padding(padding: const EdgeInsets.fromLTRB(6, 2, 2, 2), child: Icon(Icons.copy, size: 12, color: Theme.of(context).hintColor)),
        ),
      );
}

/// A one-line command / name in a tinted box with a copy button.
class CopyLine extends StatelessWidget {
  final String text;
  final String? label;
  const CopyLine(this.text, {super.key, this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 3, 2, 3),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(children: [
        if (label != null) ...[
          SizedBox(width: 74, child: Text(label!, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
        ],
        Expanded(child: Text(text, style: monoStyle(context, size: 11.5))),
        IconButton(
          iconSize: 13,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints.tightFor(width: 24, height: 24),
          style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
          tooltip: 'Copy',
          icon: const Icon(Icons.copy),
          onPressed: () => copyToClipboard(context, text),
        ),
      ]),
    );
  }
}

/// Inline row of small widgets separated by spacing; wraps when narrow.
class InlineWrap extends StatelessWidget {
  final List<Widget> children;
  const InlineWrap(this.children, {super.key});

  @override
  Widget build(BuildContext context) =>
      Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: children);
}

/// Small refresh button for section trailers.
class RefreshButton extends StatelessWidget {
  final VoidCallback onPressed;
  const RefreshButton(this.onPressed, {super.key});

  @override
  Widget build(BuildContext context) => IconButton(
        iconSize: 15,
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 26, height: 26),
        style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
        tooltip: 'Refresh',
        icon: const Icon(Icons.refresh),
        onPressed: onPressed,
      );
}

/// Compact table with a muted header row and hairline separators.
///
/// The default look (widget [headers], content-sized columns) suits free-form
/// cells. [CompactTable.ruled] takes string headers (uppercased) with
/// per-column [flex] (null = size to content) and optional [align].
class CompactTable extends StatelessWidget {
  final List<Widget>? headers;
  final List<String>? labels;
  final List<List<Widget>> rows;
  final List<double?>? flex;
  final List<TextAlign>? align;
  const CompactTable({super.key, required List<Widget> this.headers, required this.rows})
      : labels = null,
        flex = null,
        align = null;
  const CompactTable.ruled({super.key, required List<String> headers, required this.rows, required List<double?> this.flex, this.align})
      : labels = headers,
        headers = null;

  /// Convenience for plain-string headers of the default look.
  static List<Widget> textHeaders(BuildContext context, List<String> h) {
    final theme = Theme.of(context);
    return [
      for (final s in h)
        Text(s, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant, fontWeight: FontWeight.w600)),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (labels != null) return _ruled(theme);
    final line = BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.45));
    Widget pad(Widget w) => Padding(padding: const EdgeInsets.fromLTRB(0, 4, 12, 4), child: Align(alignment: Alignment.centerLeft, child: w));
    return Table(
      defaultColumnWidth: const IntrinsicColumnWidth(flex: 1),
      defaultVerticalAlignment: TableCellVerticalAlignment.top,
      children: [
        TableRow(decoration: BoxDecoration(border: Border(bottom: line)), children: [for (final h in headers!) pad(h)]),
        for (var i = 0; i < rows.length; i++)
          TableRow(
            decoration: BoxDecoration(border: i == rows.length - 1 ? null : Border(bottom: line.copyWith(color: line.color.withValues(alpha: 0.2)))),
            children: [for (final c in rows[i]) pad(c)],
          ),
      ],
    );
  }

  Widget _ruled(ThemeData theme) {
    final head = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w600, letterSpacing: 0.3);
    final line = BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.35));
    Widget cell(Widget w, int i) => Padding(
          padding: const EdgeInsets.fromLTRB(0, 5, 10, 5),
          child: align?[i] == TextAlign.right ? Align(alignment: Alignment.centerRight, child: w) : w,
        );
    return Table(
      columnWidths: {
        for (var i = 0; i < flex!.length; i++) i: flex![i] == null ? const IntrinsicColumnWidth() : FlexColumnWidth(flex![i]!),
      },
      defaultVerticalAlignment: TableCellVerticalAlignment.middle,
      border: TableBorder(horizontalInside: line),
      children: [
        TableRow(children: [for (var i = 0; i < labels!.length; i++) cell(Text(labels![i].toUpperCase(), style: head), i)]),
        for (final r in rows) TableRow(children: [for (var i = 0; i < r.length; i++) cell(r[i], i)]),
      ],
    );
  }
}

/// Runs [load] once (in initState) and re-runs it only when [fetchKey]
/// changes or the user asks for a reload. Build it with a stable key
/// (e.g. `ValueKey('${ctx.uid}/endpoints')`).
class NetFetch<T> extends StatefulWidget {
  final Object fetchKey;
  final Future<T> Function() load;
  final Widget Function(BuildContext context, AsyncSnapshot<T> snap, VoidCallback reload) builder;
  const NetFetch({super.key, required this.fetchKey, required this.load, required this.builder});

  @override
  State<NetFetch<T>> createState() => _NetFetchState<T>();
}

class _NetFetchState<T> extends State<NetFetch<T>> {
  late Future<T> _future = widget.load();

  @override
  void didUpdateWidget(covariant NetFetch<T> old) {
    super.didUpdateWidget(old);
    if (old.fetchKey != widget.fetchKey) _future = widget.load();
  }

  void _reload() => setState(() => _future = widget.load());

  @override
  Widget build(BuildContext context) =>
      FutureBuilder<T>(future: _future, builder: (context, snap) => widget.builder(context, snap, _reload));
}

/// Stable string fingerprint of a JSON value, for [NetFetch.fetchKey].
String fingerprint(Object? v) => jsonEncode(v);
