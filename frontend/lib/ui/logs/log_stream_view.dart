import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../panels/pod/pod_logic.dart';
import '../../panels/pod/pod_widgets.dart';
import '../../state/log_dock.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Severity shown by a stream's status dot (tab strip, status text).
Severity logPhaseSeverity(LogStream s) => switch (s.phase) {
  LogPhase.connecting => Severity.info,
  LogPhase.streaming => s.follow ? Severity.ok : Severity.neutral,
  LogPhase.eof => Severity.neutral,
  LogPhase.error => Severity.error,
  LogPhase.notStarted => Severity.warn,
};

String logPhaseLabel(LogStream s) => switch (s.phase) {
  LogPhase.connecting => 'connecting',
  LogPhase.streaming => s.follow ? 'live' : 'loading',
  LogPhase.eof => 'ended',
  LogPhase.error => 'error',
  LogPhase.notStarted => 'not started',
};

/// One-line summary for the active stream (shown in the dock's tab strip).
String logStreamSummary(LogStream s) => [
  '${s.lines.length} line${s.lines.length == 1 ? '' : 's'}',
  if (s.dropped > 0) '${s.dropped} older dropped',
  if (s.previous) 'previous instance',
].join(' · ');

/// Toolbar + virtualised log list for one [LogStream]. Key it by the stream
/// (`ObjectKey(stream)`); the stream itself owns the subscription, so this
/// widget can come and go without interrupting it.
class LogStreamView extends StatefulWidget {
  final LogStream stream;
  const LogStreamView({super.key, required this.stream});

  @override
  State<LogStreamView> createState() => _LogStreamViewState();
}

class _LogStreamViewState extends State<LogStreamView> {
  late final _search = TextEditingController(text: widget.stream.query);
  final _scroll = ScrollController();
  final _hScroll = ScrollController();
  bool _pinned = true;
  String? _seenView;

  LogStream get s => widget.stream;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
    s.addListener(_onStream);
    _jumpToEndSoon();
  }

  @override
  void didUpdateWidget(LogStreamView old) {
    super.didUpdateWidget(old);
    if (old.stream != s) {
      old.stream.removeListener(_onStream);
      s.addListener(_onStream);
    }
  }

  @override
  void dispose() {
    s.removeListener(_onStream);
    _scroll.dispose();
    _hScroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onStream() {
    if (!mounted) return;
    setState(() {});
    // New lines, or a different visible set (filter / wrap): follow the tail
    // when pinned, otherwise keep the offset within the new extent.
    final view = '${s.lines.length}|${s.onlyMatching}|${s.onlyMatching ? s.query : ''}|${s.wrap}';
    if (view != _seenView) {
      _seenView = view;
      if (s.lines.isEmpty) _pinned = true;
      if (_pinned) {
        _jumpToEndSoon();
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_scroll.hasClients) return;
          final p = _scroll.position;
          if (p.pixels > p.maxScrollExtent) _scroll.jumpTo(p.maxScrollExtent);
        });
      }
    }
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final atBottom = p.pixels >= p.maxScrollExtent - 24;
    if (atBottom != _pinned) setState(() => _pinned = atBottom);
  }

  void _jumpToEndSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final showOnly = s.onlyMatching && s.query.isNotEmpty;
    final indices = showOnly ? s.matching : null;
    final count = indices?.length ?? s.lines.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _Toolbar(stream: s, search: _search),
        Container(height: 1, color: colors.separator),
        if (s.phase == LogPhase.error && s.lines.isNotEmpty)
          Padding(padding: const EdgeInsets.fromLTRB(10, 6, 10, 6), child: InlineMessage(s.error ?? 'error', isError: true)),
        Expanded(
          child: ColoredBox(color: theme.colorScheme.surface, child: s.lines.isEmpty ? _emptyState(context) : _logList(context, indices, count)),
        ),
      ],
    );
  }

  Widget _emptyState(BuildContext context) {
    final c = s.current;
    final Widget body;
    switch (s.phase) {
      case LogPhase.connecting:
        body = const Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Text('Connecting…'),
          ],
        );
      case LogPhase.notStarted:
        final w = c?.waiting ?? const {};
        body = InlineMessage(
          'Container ${c?.name ?? s.container} has not started yet'
          '${w['reason'] != null ? ': ${w['reason']}' : ''}'
          '${w['message'] != null ? '\n${w['message']}' : ''}',
          icon: Icons.hourglass_empty,
        );
      case LogPhase.error:
        body = InlineMessage(s.error ?? 'error', isError: true);
      case LogPhase.eof || LogPhase.streaming:
        final hint = !s.previous && (c?.restarts ?? 0) > 0 ? ' — the container has restarted; try "Previous"' : '';
        body = InlineMessage('No log output$hint', icon: Icons.notes);
    }
    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(padding: const EdgeInsets.all(12), child: body),
      ),
    );
  }

  Widget _logList(BuildContext context, List<int>? indices, int count) {
    final style = monoStyle(context, size: 12);
    const lineHeight = 17.0;
    final q = s.query.toLowerCase();
    final list = Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemExtent: s.wrap ? null : lineHeight,
        itemCount: count,
        itemBuilder: (context, i) {
          final idx = indices == null ? i : indices[i];
          final text = s.lines[idx];
          return _LogLine(
            text: text,
            query: s.query,
            timestamps: s.timestamps,
            wrap: s.wrap,
            style: style,
            highlight: q.isNotEmpty && text.toLowerCase().contains(q),
          );
        },
      ),
    );
    final body = s.wrap
        ? list
        : LayoutBuilder(
            builder: (context, box) {
              final charW =
                  (TextPainter(
                    text: TextSpan(text: 'MMMMMMMMMM', style: style),
                    textDirection: TextDirection.ltr,
                  )..layout()).width /
                  10;
              final width = math.max(box.maxWidth, s.maxLen * charW + 24);
              return Scrollbar(
                controller: _hScroll,
                child: SingleChildScrollView(
                  controller: _hScroll,
                  scrollDirection: Axis.horizontal,
                  child: SizedBox(width: width, height: box.maxHeight, child: list),
                ),
              );
            },
          );
    // Stay pinned when the viewport or content size changes (resize, wrap toggle).
    final pinnedBody = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) {
        if (_pinned && n.metrics.axis == Axis.vertical && n.metrics.pixels < n.metrics.maxScrollExtent) _jumpToEndSoon();
        return false;
      },
      child: body,
    );
    return Stack(
      children: [
        Positioned.fill(child: SelectionArea(child: pinnedBody)),
        if (!_pinned)
          Positioned(
            right: 16,
            bottom: 10,
            child: FilledButton.tonalIcon(
              style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
              icon: const Icon(Icons.arrow_downward, size: 15),
              label: const Text('Jump to latest'),
              onPressed: () {
                setState(() => _pinned = true);
                _jumpToEndSoon();
              },
            ),
          ),
      ],
    );
  }
}

/// Single-row toolbar: options scroll horizontally when the dock is narrow;
/// search and copy/clear stay pinned to the right.
class _Toolbar extends StatelessWidget {
  final LogStream stream;
  final TextEditingController search;
  const _Toolbar({required this.stream, required this.search});

  @override
  Widget build(BuildContext context) {
    final s = stream;
    final theme = Theme.of(context);
    final c = s.current;
    final matchCount = s.query.isEmpty ? null : s.matching.length;
    return LayoutBuilder(
      builder: (context, box) {
        final compact = box.maxWidth < 820;
        final searchW = (box.maxWidth * 0.34).clamp(120.0, 260.0);
        final options = <Widget>[
          _box(
            context,
            DropdownButton<String>(
              value: c?.name,
              isDense: true,
              underline: const SizedBox(),
              focusColor: Colors.transparent,
              style: monoStyle(context, size: 12),
              hint: Text(s.container, style: monoStyle(context, size: 12)),
              items: [
                for (final x in s.containers)
                  DropdownMenuItem(
                    value: x.name,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 8, color: severityColor(context, x.severity)),
                        const SizedBox(width: 6),
                        Text(x.name, style: monoStyle(context, size: 12)),
                        if (x.kind != ContainerKind.regular) ...[const SizedBox(width: 6), KindTag(x.kind)],
                        if (x.restarts > 0) ...[
                          const SizedBox(width: 6),
                          Text('${x.restarts}×', style: TextStyle(fontSize: 11, color: severityColor(context, Severity.warn))),
                        ],
                      ],
                    ),
                  ),
              ],
              onChanged: (v) => v == null ? null : context.read<LogDock>().switchContainer(s, v),
            ),
            tooltip: 'Container',
          ),
          _box(
            context,
            DropdownButton<int>(
              value: s.tail,
              isDense: true,
              underline: const SizedBox(),
              focusColor: Colors.transparent,
              style: theme.textTheme.bodySmall,
              items: [
                for (final n in const [100, 500, 2000, -1]) DropdownMenuItem(value: n, child: Text(n < 0 ? 'all lines' : 'last $n')),
              ],
              onChanged: (v) => s.setOptions(tail: v ?? 500),
            ),
            tooltip: 'Initial lines',
          ),
          _Toggle(
            label: 'Follow',
            icon: Icons.play_arrow_rounded,
            value: s.follow,
            compact: compact,
            onChanged: (v) => s.setOptions(follow: v),
          ),
          _Toggle(
            label: 'Previous',
            icon: Icons.history,
            value: s.previous,
            compact: compact,
            tooltip: s.canPrevious ? 'Logs of the previous (crashed) instance' : 'No restarts: no previous instance',
            onChanged: s.canPrevious || s.previous ? (v) => s.setOptions(previous: v) : null,
          ),
          _Toggle(
            label: 'Timestamps',
            icon: Icons.schedule,
            value: s.timestamps,
            compact: compact,
            onChanged: (v) => s.setOptions(timestamps: v),
          ),
          _Toggle(
            label: 'Wrap',
            icon: Icons.wrap_text,
            value: s.wrap,
            compact: compact,
            onChanged: (v) => s.setView(wrap: v),
          ),
        ];
        return SizedBox(
          height: 36,
          child: Row(
            children: [
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.only(left: 8, right: 6),
                  child: Row(
                    children: [
                      for (final (i, w) in options.indexed) ...[if (i > 0) const SizedBox(width: 4), w],
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: searchW,
                height: 26,
                child: TextField(
                  controller: search,
                  style: monoStyle(context, size: 12),
                  decoration: InputDecoration(
                    hintText: 'Search',
                    hintStyle: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).faint),
                    prefixIcon: const Icon(Icons.search, size: 14),
                    suffixIcon: s.query.isEmpty
                        ? null
                        : IconButton(
                            tooltip: 'Clear search',
                            iconSize: 12,
                            icon: const Icon(Icons.close),
                            onPressed: () {
                              search.clear();
                              s.setQuery('');
                            },
                          ),
                    suffixText: matchCount == null || searchW < 170 ? null : '$matchCount',
                    suffixStyle: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontSize: 11),
                    contentPadding: const EdgeInsets.symmetric(vertical: 5, horizontal: 6),
                  ),
                  onChanged: s.setQuery,
                ),
              ),
              const SizedBox(width: 4),
              _Toggle(
                label: 'Only matching',
                icon: Icons.filter_list,
                value: s.onlyMatching,
                compact: true,
                tooltip: matchCount == null ? 'Show only matching lines' : 'Show only matching lines ($matchCount match${matchCount == 1 ? '' : 'es'})',
                onChanged: (v) => s.setView(onlyMatching: v),
              ),
              IconButton(
                tooltip: 'Copy all',
                icon: const Icon(Icons.copy_all_outlined, size: 15),
                onPressed: s.lines.isEmpty ? null : () => copyToClipboard(context, s.lines.join('\n'), label: '${s.lines.length} log lines'),
              ),
              IconButton(tooltip: 'Clear', icon: const Icon(Icons.block, size: 15), onPressed: s.lines.isEmpty ? null : s.clear),
              const SizedBox(width: 6),
            ],
          ),
        );
      },
    );
  }

  Widget _box(BuildContext context, Widget child, {String? tooltip}) {
    final w = Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Center(widthFactor: 1, child: child),
    );
    return tooltip == null ? w : Tooltip(message: tooltip, child: w);
  }
}

class _Toggle extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool value;
  final bool compact;
  final String? tooltip;
  final ValueChanged<bool>? onChanged;
  const _Toggle({required this.label, required this.icon, required this.value, this.onChanged, this.tooltip, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final enabled = onChanged != null;
    final on = value && enabled;
    final fg = !enabled ? colors.faint : (on ? theme.colorScheme.primary : theme.hintColor);
    final chip = Hoverable(
      onTap: enabled ? () => onChanged!(!value) : null,
      cursor: SystemMouseCursors.basic,
      builder: (h) => Container(
        height: 24,
        padding: EdgeInsets.symmetric(horizontal: compact ? 5 : 7),
        decoration: BoxDecoration(
          color: on ? theme.colorScheme.primary.withValues(alpha: 0.13) : (h && enabled ? colors.hover : null),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            if (!compact) ...[
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 12, color: on ? theme.colorScheme.primary : (enabled ? theme.colorScheme.onSurface : colors.faint))),
            ],
          ],
        ),
      ),
    );
    return Semantics(
      label: label,
      toggled: value,
      button: true,
      child: Tooltip(message: tooltip ?? label, child: chip),
    );
  }
}

final _errRe = RegExp(r'\b(error|err|fatal|panic|exception|fail(ed|ure)?)\b', caseSensitive: false);
final _warnRe = RegExp(r'\b(warn(ing)?)\b', caseSensitive: false);
final _tsRe = RegExp(r'^\d{4}-\d\d-\d\dT[\d:.]+(Z|[+-]\d\d:\d\d) ');

class _LogLine extends StatelessWidget {
  final String text;
  final String query;
  final bool timestamps;
  final bool wrap;
  final bool highlight;
  final TextStyle style;
  const _LogLine({required this.text, required this.query, required this.timestamps, required this.wrap, required this.style, required this.highlight});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    var body = text;
    String? ts;
    if (timestamps) {
      final m = _tsRe.firstMatch(text);
      if (m != null) {
        ts = m.group(0);
        body = text.substring(m.end);
      }
    }
    final head = body.length > 300 ? body.substring(0, 300) : body;
    final level = _errRe.hasMatch(head) ? Severity.error : (_warnRe.hasMatch(head) ? Severity.warn : null);
    final base = level == null ? style : style.copyWith(color: severityColor(context, level).withValues(alpha: 0.95));
    final spans = <InlineSpan>[
      if (ts != null)
        TextSpan(
          text: ts,
          style: style.copyWith(color: theme.hintColor),
        ),
      ..._highlight(body, base),
    ];
    return Container(
      color: highlight ? theme.colorScheme.primary.withValues(alpha: 0.07) : null,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: wrap ? null : Alignment.centerLeft,
      child: Text.rich(
        TextSpan(children: spans),
        softWrap: wrap,
        maxLines: wrap ? null : 1,
        overflow: wrap ? null : TextOverflow.clip,
      ),
    );
  }

  List<InlineSpan> _highlight(String s, TextStyle base) {
    if (query.isEmpty) return [TextSpan(text: s, style: base)];
    final lower = s.toLowerCase();
    final q = query.toLowerCase();
    final out = <InlineSpan>[];
    var start = 0;
    while (true) {
      final i = lower.indexOf(q, start);
      if (i < 0) break;
      if (i > start) out.add(TextSpan(text: s.substring(start, i), style: base));
      out.add(
        TextSpan(
          text: s.substring(i, i + q.length),
          style: base.copyWith(backgroundColor: Colors.amber.withValues(alpha: 0.85), color: Colors.black),
        ),
      );
      start = i + q.length;
    }
    if (start < s.length) out.add(TextSpan(text: s.substring(start), style: base));
    return out;
  }
}
