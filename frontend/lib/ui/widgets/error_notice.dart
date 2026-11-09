import 'package:flutter/material.dart';

import '../../api/error_info.dart';
import '../../util/k8s.dart' show Severity;
import '../theme.dart';
import 'common.dart' show copyToClipboard;

/// A failure, in the inspectors' [Callout] style: a short rounded bar and a
/// small icon in the severity colour, the title in the text colour, one
/// muted line of plain-language detail, and quiet "Details" (the raw
/// message, selectable, with a copy button) and "Retry" actions.
///
/// Pages put it in one place: directly under the page header, full width
/// in the page's content padding; a section's own failure goes at the top
/// of that section. It has no outer padding of its own.
class ErrorNotice extends StatelessWidget {
  final Object? error;

  /// Overrides the described title (e.g. "Refresh failed"); the described
  /// title then leads the detail line.
  final String? title;

  /// Error (red) or warn (amber, for "some data is missing").
  final Severity severity;

  /// Offered when the error is retryable.
  final VoidCallback? onRetry;

  /// Appended to the detail line, e.g. "Showing the last result."
  final String? note;

  /// Partial failures: what failed (e.g. a list name) and why, one notice
  /// listing them in its details.
  final Map<String, Object>? parts;

  const ErrorNotice(Object this.error, {super.key, this.title, this.severity = Severity.error, this.onRetry, this.note}) : parts = null;

  /// Several parts that failed while the rest loaded: amber by default,
  /// "nodes, events: couldn't reach the cluster" on the detail line and
  /// every raw message in the details.
  const ErrorNotice.parts(Map<String, Object> this.parts, {super.key, required String this.title, this.severity = Severity.warn, this.onRetry, this.note})
      : error = null;

  /// What it shows: title, detail line, raw text (null when it says nothing
  /// more) and whether a retry may help.
  ({String title, String detail, String? raw, bool retryable}) get content {
    final parts = this.parts;
    if (parts != null) {
      final infos = {for (final e in parts.entries) e.key: describeError(e.value)};
      final byWhy = <String, List<String>>{};
      for (final e in infos.entries) {
        (byWhy[e.value.kind == ErrorKind.other ? 'failed' : _lower(e.value.title)] ??= []).add(e.key);
      }
      final detail = [for (final e in byWhy.entries) '${e.value.join(', ')}: ${e.key}'].join(' · ');
      return (
        title: title!,
        detail: _sentences([detail, ?note]),
        raw: [for (final e in infos.entries) '${e.key}: ${e.value.raw}'].join('\n'),
        retryable: infos.values.any((i) => i.retryable),
      );
    }
    final info = describeError(error!);
    final lead = title;
    final detail = _sentences([if (lead != null) info.title, info.detail, ?note]);
    final shown = lead ?? info.title;
    final more = info.raw.trim() != shown.trim() && info.raw.trim() != detail.trim() && (info.hasMore || lead != null);
    return (title: shown, detail: detail, raw: more ? info.raw : null, retryable: info.retryable);
  }

  @override
  Widget build(BuildContext context) {
    final c = content;
    return _NoticeBody(
      key: const ValueKey('error-notice'),
      severity: severity,
      title: c.title,
      detail: c.detail,
      raw: c.raw,
      onRetry: c.retryable ? onRetry : null,
    );
  }
}

/// A view that failed to load anything: the [ErrorNotice] content centred,
/// a little larger, with Retry under it.
class LoadFailure extends StatelessWidget {
  final Object error;

  /// e.g. "Couldn't load the overview"; the described title then leads the
  /// detail line.
  final String? title;
  final VoidCallback? onRetry;
  const LoadFailure(this.error, {super.key, this.title, this.onRetry});

  @override
  Widget build(BuildContext context) {
    final c = ErrorNotice(error, title: title).content;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: _NoticeBody(
            key: const ValueKey('load-failure'),
            severity: Severity.error,
            title: c.title,
            detail: c.detail,
            raw: c.raw,
            onRetry: onRetry,
            large: true,
          ),
        ),
      ),
    );
  }
}

/// "a, b" + "c." → "a, b. c.": joins non-empty pieces as sentences.
String _sentences(List<String> pieces) {
  final out = <String>[];
  for (final p in pieces.map((p) => p.trim()).where((p) => p.isNotEmpty)) {
    out.add(RegExp(r'[.!?…]$').hasMatch(p) ? p : '$p.');
  }
  return out.join(' ');
}

String _lower(String s) => s.isEmpty ? s : s[0].toLowerCase() + s.substring(1);

class _NoticeBody extends StatefulWidget {
  final Severity severity;
  final String title;
  final String detail;
  final String? raw;
  final VoidCallback? onRetry;
  final bool large;
  const _NoticeBody({super.key, required this.severity, required this.title, required this.detail, this.raw, this.onRetry, this.large = false});

  @override
  State<_NoticeBody> createState() => _NoticeBodyState();
}

class _NoticeBodyState extends State<_NoticeBody> {
  bool _open = false;

  /// Narrower than this, the actions wrap under the text.
  static const _wrapBelow = 420.0;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = severityColor(context, widget.severity);
    final large = widget.large;
    final raw = widget.raw;
    final buttonStyle = TextButton.styleFrom(
      minimumSize: const Size(0, 24),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      visualDensity: VisualDensity.compact,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      textStyle: theme.textTheme.labelSmall?.copyWith(fontWeight: FontWeight.w600),
    );
    final actions = [
      if (raw != null)
        TextButton(
          key: const ValueKey('error-details'),
          style: buttonStyle.copyWith(foregroundColor: WidgetStatePropertyAll(theme.hintColor)),
          onPressed: () => setState(() => _open = !_open),
          child: Text(_open ? 'Hide details' : 'Details'),
        ),
      if (widget.onRetry != null)
        large
            ? FilledButton.tonal(key: const ValueKey('error-retry'), onPressed: widget.onRetry, child: const Text('Retry'))
            : TextButton(key: const ValueKey('error-retry'), style: buttonStyle, onPressed: widget.onRetry, child: const Text('Retry')),
    ];
    final titleStyle = large
        ? theme.textTheme.titleSmall?.copyWith(color: theme.colorScheme.onSurface, height: 1.3)
        : theme.textTheme.bodySmall?.copyWith(fontSize: 12.5, color: theme.colorScheme.onSurface, height: 1.3);
    final detailStyle = (large ? theme.textTheme.bodyMedium : theme.textTheme.bodySmall)?.copyWith(color: theme.hintColor, height: 1.35);
    final text = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(widget.title, style: titleStyle),
      if (widget.detail.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(widget.detail, style: detailStyle, maxLines: large || _open ? null : 1, overflow: large || _open ? null : TextOverflow.ellipsis),
        ),
      if (_open && raw != null) Padding(padding: const EdgeInsets.only(top: 6), child: _RawDetails(raw)),
    ]);

    if (large) {
      // Centred in an empty view: the mark above, no bar.
      return Column(mainAxisSize: MainAxisSize.min, children: [
        Icon(severityIcon(widget.severity), size: 22, color: color),
        const SizedBox(height: 8),
        Text(widget.title, style: titleStyle, textAlign: TextAlign.center),
        if (widget.detail.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(widget.detail, style: detailStyle, textAlign: TextAlign.center)),
        if (actions.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 14),
            child: Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: actions.reversed.toList()),
          ),
        if (_open && raw != null) Padding(padding: const EdgeInsets.only(top: 12), child: _RawDetails(raw)),
      ]);
    }
    return LayoutBuilder(builder: (context, box) {
      final below = large || box.maxWidth < _wrapBelow;
      final row = actions.isEmpty ? null : Row(mainAxisSize: MainAxisSize.min, children: [for (final (i, a) in actions.indexed) Padding(padding: EdgeInsets.only(left: i == 0 ? 0 : 4), child: a)]);
      // The bar is positioned beside the content (no intrinsic sizes), as
      // in Callout.
      return Stack(children: [
        Padding(
          padding: EdgeInsets.only(left: large ? 14 : 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: EdgeInsets.only(top: large ? 1 : 1.5, right: large ? 9 : 7),
              child: Icon(severityIcon(widget.severity), size: large ? 18 : 14, color: color),
            ),
            Expanded(
              child: below && row != null
                  ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [text, Padding(padding: EdgeInsets.only(top: large ? 12 : 4), child: row)])
                  : text,
            ),
            if (!below && row != null) Padding(padding: const EdgeInsets.only(left: 12), child: row),
          ]),
        ),
        Positioned(
          left: 0,
          top: 1,
          bottom: 1,
          width: 3,
          child: DecoratedBox(decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(2))),
        ),
      ]);
    });
  }
}

/// The raw message, selectable, with a copy button.
class _RawDetails extends StatelessWidget {
  final String raw;
  const _RawDetails(this.raw);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(color: theme.colorScheme.onSurface.withValues(alpha: 0.05), borderRadius: BorderRadius.circular(4)),
      padding: const EdgeInsets.fromLTRB(8, 6, 2, 6),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(child: SelectableText(raw, style: monoStyle(context, size: 11.5, color: theme.colorScheme.onSurfaceVariant))),
        IconButton(
          tooltip: 'Copy',
          iconSize: 14,
          visualDensity: VisualDensity.compact,
          constraints: const BoxConstraints.tightFor(width: 26, height: 26),
          padding: EdgeInsets.zero,
          icon: Icon(Icons.copy, color: theme.hintColor),
          onPressed: () => copyToClipboard(context, raw, label: 'error message'),
        ),
      ]),
    );
  }
}
