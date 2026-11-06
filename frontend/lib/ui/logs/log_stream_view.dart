import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:provider/provider.dart';

import '../../panels/pod/pod_logic.dart';
import '../../panels/pod/pod_widgets.dart';
import '../../state/app_state.dart';
import '../../state/log_dock.dart';
import '../../util/k8s.dart';
import '../theme.dart';
import '../widgets/common.dart';

/// Severity shown by a stream's status dot (tab strip, status text).
Severity logPhaseSeverity(LogSession s) => switch (s.phase) {
  LogPhase.connecting => Severity.info,
  LogPhase.streaming => s.follow ? Severity.ok : Severity.neutral,
  LogPhase.eof => Severity.neutral,
  LogPhase.error => Severity.error,
  LogPhase.notStarted => Severity.warn,
};

String logPhaseLabel(LogSession s) => switch (s.phase) {
  LogPhase.connecting => 'connecting',
  LogPhase.streaming => s.follow ? 'live' : 'loading',
  LogPhase.eof => 'ended',
  LogPhase.error => 'error',
  LogPhase.notStarted => 'not started',
};

/// One-line summary for the active stream (shown in the dock's tab strip).
String logStreamSummary(LogSession s) => [
  if (s is AggregateLogStream) '${s.podCount} pod${s.podCount == 1 ? '' : 's'}',
  '${s.lines.length} line${s.lines.length == 1 ? '' : 's'}',
  if (s.dropped > 0) '${s.dropped} older dropped',
  if (s.previous) 'previous instance',
].join(' · ');

/// Toolbar + virtualised log list for one [LogSession] (a single container's
/// [LogStream] or an [AggregateLogStream]). Key it by the stream
/// (`ObjectKey(stream)`); the stream itself owns the subscription, so this
/// widget can come and go without interrupting it.
class LogStreamView extends StatefulWidget {
  final LogSession stream;
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

  // What the list showed at the last stream notification: the sequence
  // number of its first line, its row count and (when filtered) its rows.
  // Used to keep the rows on screen still when old lines are evicted.
  int _seenFirstSeq = 0;
  int _seenRowCount = 0;
  List<int>? _seenRows;
  String? _seenRowsView;

  static const double _lineHeight = 17;

  /// How close to the end counts as "at the end" when scrolling back down.
  static const double _pinSlop = 4;

  LogSession get s => widget.stream;

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
    _keepRowsInPlace();
    setState(() {});
    // New lines, or a different visible set (filter / wrap): follow the tail
    // when pinned, otherwise keep the offset within the new extent.
    final view = '${s.lines.nextSeq}|${s.visibleRows?.length}|${s.onlyMatching}|${s.onlyMatching ? s.query : ''}|${s.wrap}';
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
    // Any user scroll towards older lines stops following at once, however
    // small: staying pinned would snap the view back to the end on the next
    // flush (and cancel the gesture). Reaching the end again resumes it.
    final pinned = p.userScrollDirection != ScrollDirection.forward && p.pixels >= p.maxScrollExtent - _pinSlop;
    if (pinned != _pinned) setState(() => _pinned = pinned);
  }

  /// While reading further up, the ring buffer evicting the oldest lines
  /// would slide every row up under the reader. Shift the offset by the rows
  /// that left the top instead (fixed-height rows only). A layout correction,
  /// not a jump, so an in-progress drag or fling carries on.
  void _keepRowsInPlace() {
    final rows = s.visibleRows;
    final view = '${s.onlyMatching}|${s.onlyMatching ? s.query : ''}|${s.wrap}|${rows == null}';
    final first = s.lines.firstSeq;
    if (!_pinned && !s.wrap && view == _seenRowsView && first > _seenFirstSeq && s.lines.isNotEmpty && _scroll.hasClients) {
      var gone = 0;
      final old = _seenRows;
      if (old == null) {
        gone = math.min(first - _seenFirstSeq, _seenRowCount);
      } else {
        while (gone < old.length && _seenFirstSeq + old[gone] < first) {
          gone++;
        }
      }
      final p = _scroll.position;
      if (gone > 0 && p.hasPixels) {
        p.correctBy(-math.min(gone * _lineHeight, p.pixels));
        // With the row count unchanged nothing else re-lays out the
        // viewport; listeners (the viewport among them) pick up the offset.
        // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
        p.notifyListeners();
      }
    }
    _seenRowsView = view;
    _seenFirstSeq = first;
    _seenRows = rows;
    _seenRowCount = rows?.length ?? s.lines.length;
  }

  void _openSource(LogSource src) {
    final app = context.read<AppState>();
    final t = app.typeFor('', 'Pod');
    if (t != null) app.openDetail(DetailTarget(type: t, name: src.pod, namespace: s.namespace));
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
    final indices = s.visibleRows;
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
    final c = s is LogStream ? (s as LogStream).current : null;
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
          'Container ${c?.name ?? (s is LogStream ? (s as LogStream).container : '')} has not started yet'
          '${w['reason'] != null ? ': ${w['reason']}' : ''}'
          '${w['message'] != null ? '\n${w['message']}' : ''}',
          icon: Icons.hourglass_empty,
        );
      case LogPhase.error:
        body = InlineMessage(s.error ?? 'error', isError: true);
      case LogPhase.eof || LogPhase.streaming:
        final hint = !s.previous && (c?.restarts ?? 0) > 0 ? ' — the container has restarted; try "Previous"' : '';
        body = InlineMessage(s is AggregateLogStream && (s as AggregateLogStream).podCount == 0 ? 'No running pods match yet' : 'No log output$hint', icon: Icons.notes);
    }
    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: Padding(padding: const EdgeInsets.all(12), child: body),
      ),
    );
  }

  // Monospace advance for the horizontal extent, measured once per style
  // rather than laying out a TextPainter on every flush.
  TextStyle? _charWStyle;
  double _charW = 0;
  double _charWidth(TextStyle style) {
    if (style != _charWStyle) {
      final p = TextPainter(
        text: TextSpan(text: 'MMMMMMMMMM', style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      _charW = p.width / 10;
      p.dispose();
      _charWStyle = style;
    }
    return _charW;
  }

  Widget _logList(BuildContext context, List<int>? indices, int count) {
    final style = monoStyle(context, size: 12);
    const lineHeight = _lineHeight;
    final q = s.query.toLowerCase();
    final session = s;
    final agg = session is AggregateLogStream ? session : null;
    final palette = agg == null ? null : sourcePalette(Theme.of(context).brightness);
    final prefixW = agg == null ? 0.0 : (agg.prefixChars + 1) * _charWidth(style);
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
          final m = agg?.meta[idx];
          final src = m == null ? null : agg!.sources[m.src];
          return _LogLine(
            text: text,
            query: s.query,
            timestamps: s.timestamps,
            wrap: s.wrap,
            style: style,
            highlight: q.isNotEmpty && s.lineMatches(idx, q),
            source: src,
            sourceColor: src == null ? null : palette![src.colorIndex],
            prefixWidth: prefixW,
            ts: m?.ts,
            kind: m?.kind ?? 0,
            onSource: _openSource,
          );
        },
      ),
    );
    final body = s.wrap
        ? list
        : LayoutBuilder(
            builder: (context, box) {
              final charW = _charWidth(style);
              final width = math.max(box.maxWidth, (s.maxLen + s.extraChars) * charW + 24);
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
  final LogSession stream;
  final TextEditingController search;
  const _Toolbar({required this.stream, required this.search});

  @override
  Widget build(BuildContext context) {
    final s = stream;
    final theme = Theme.of(context);
    final ls = s is LogStream ? s : null;
    final session = s;
    final agg = session is AggregateLogStream ? session : null;
    final c = ls?.current;
    final matchCount = s.query.isEmpty ? null : s.matching.length;
    return LayoutBuilder(
      builder: (context, box) {
        final compact = box.maxWidth < 820;
        final searchW = (box.maxWidth * 0.34).clamp(120.0, 260.0);
        void setTimestamps(bool v) => ls != null ? ls.setOptions(timestamps: v) : agg!.setOptions(timestamps: v);
        final options = <Widget>[
          if (agg != null) ...[
            _SourcesMenu(stream: agg),
            _Toggle(
              label: 'All containers',
              icon: Icons.view_agenda_outlined,
              value: agg.allContainers,
              compact: compact,
              tooltip: 'Include every container of each pod (reconnects)',
              onChanged: (v) => agg.setOptions(allContainers: v),
            ),
            _PodCount(stream: agg),
          ],
          if (ls != null)
            _box(
              context,
              MenuSelect<String>(
                value: c?.name,
                hint: Text(ls.container, style: monoStyle(context, size: 12)),
                options: [
                  for (final x in ls.containers)
                    (
                      x.name,
                      Row(
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
                onChanged: (v) => context.read<LogDock>().switchContainer(ls, v),
              ),
              tooltip: 'Container',
            ),
          _box(
            context,
            MenuSelect<int>(
              value: ls?.tail ?? agg!.tail,
              options: [
                for (final n in agg != null ? const [100, 200, 500, 1000] : const [100, 500, 2000, -1])
                  (n, Text(n < 0 ? 'all lines' : (agg != null ? 'last $n each' : 'last $n'), style: theme.textTheme.bodySmall)),
              ],
              onChanged: (v) => ls != null ? ls.setOptions(tail: v) : agg!.setOptions(tail: v),
            ),
            tooltip: agg != null ? 'Initial lines per container' : 'Initial lines',
          ),
          _Toggle(
            label: 'Follow',
            icon: Icons.play_arrow_rounded,
            value: s.follow,
            compact: compact,
            onChanged: (v) => ls != null ? ls.setOptions(follow: v) : agg!.setOptions(follow: v),
          ),
          if (ls != null)
            _Toggle(
              label: 'Previous',
              icon: Icons.history,
              value: ls.previous,
              compact: compact,
              tooltip: ls.canPrevious ? 'Logs of the previous (crashed) instance' : 'No restarts: no previous instance',
              onChanged: ls.canPrevious || ls.previous ? (v) => ls.setOptions(previous: v) : null,
            ),
          _Toggle(label: 'Timestamps', icon: Icons.schedule, value: s.timestamps, compact: compact, onChanged: setTimestamps),
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
                onPressed: s.lines.isEmpty ? null : () => copyToClipboard(context, s.copyText(), label: '${s.lines.length} log lines'),
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

/// Live pod count of an aggregated stream.
class _PodCount extends StatelessWidget {
  final AggregateLogStream stream;
  const _PodCount({required this.stream});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = stream.podCount;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        '$n pod${n == 1 ? '' : 's'}',
        key: const ValueKey('agg-pod-count'),
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontSize: 11.5),
      ),
    );
  }
}

/// "Sources" menu: pods (and their containers) with checkboxes to hide or
/// show each. The menu stays open while toggling.
class _SourcesMenu extends StatelessWidget {
  final AggregateLogStream stream;
  const _SourcesMenu({required this.stream});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hidden = stream.sources.where((s) => s.hidden).length;
    return MenuButton<Object>(
      tooltip: 'Show or hide pods and containers',
      onSelected: (_) {},
      items: () => [_SourcesEntry(stream)],
      builder: (h) => Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: h ? theme.colorScheme.onSurface.withValues(alpha: 0.06) : null,
          border: Border.all(color: theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.filter_list, size: 14, color: hidden > 0 ? theme.colorScheme.primary : theme.hintColor),
            const SizedBox(width: 4),
            Text(hidden > 0 ? 'Sources ($hidden hidden)' : 'Sources', style: const TextStyle(fontSize: 12)),
            const SizedBox(width: 2),
            Icon(Icons.unfold_more, size: 14, color: theme.hintColor),
          ],
        ),
      ),
    );
  }
}

class _SourcesEntry extends PopupMenuEntry<Object> {
  final AggregateLogStream stream;
  const _SourcesEntry(this.stream);

  @override
  double get height => 40;

  @override
  bool represents(Object? value) => false;

  @override
  State<_SourcesEntry> createState() => _SourcesEntryState();
}

class _SourcesEntryState extends State<_SourcesEntry> {
  @override
  Widget build(BuildContext context) {
    final s = widget.stream;
    final theme = Theme.of(context);
    final palette = sourcePalette(theme.brightness);
    final mono = monoStyle(context, size: 12);
    return ListenableBuilder(
      listenable: s,
      builder: (context, _) {
        Widget row(String label, bool? value, ValueChanged<bool?> onChanged, {Color? color, double indent = 0}) => InkWell(
          onTap: () => onChanged(value == false ? true : false),
          child: Padding(
            padding: EdgeInsets.only(left: 8 + indent, right: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 28,
                  height: 26,
                  child: Checkbox(tristate: true, value: value, visualDensity: VisualDensity.compact, onChanged: onChanged),
                ),
                if (color != null) ...[Icon(Icons.circle, size: 8, color: color), const SizedBox(width: 6)],
                Flexible(
                  child: Text(label, overflow: TextOverflow.ellipsis, style: mono),
                ),
              ],
            ),
          ),
        );
        final pods = s.pods;
        return ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360, minWidth: 260),
          child: pods.isEmpty
              ? const Padding(padding: EdgeInsets.all(12), child: Text('No pods yet'))
              : SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      row('All sources', s.sources.every((x) => !x.hidden) ? true : (s.sources.every((x) => x.hidden) ? false : null), (v) {
                        v == false ? [for (final p in pods) s.setPodHidden(p, true)] : s.showAllSources();
                      }),
                      for (final pod in pods) ...[
                        () {
                          final cs = s.sources.where((x) => x.pod == pod).toList();
                          final shown = cs.where((x) => !x.hidden).length;
                          return row(
                            pod,
                            shown == cs.length ? true : (shown == 0 ? false : null),
                            (v) => s.setPodHidden(pod, v == false),
                            color: cs.length == 1 ? palette[cs.first.colorIndex] : null,
                          );
                        }(),
                        if (s.sources.where((x) => x.pod == pod).length > 1)
                          for (final c in s.sources.where((x) => x.pod == pod))
                            row(c.container, !c.hidden, (v) => s.setSourceHidden(c, v == false), color: palette[c.colorIndex], indent: 20),
                      ],
                    ],
                  ),
                ),
        );
      },
    );
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

/// Prefix colours for aggregated log sources: eight hues that stay legible
/// on the light and dark log backgrounds.
List<Color> sourcePalette(Brightness b) => b == Brightness.dark ? _darkSources : _lightSources;

const _darkSources = [
  Color(0xFF6CA8FF), // blue
  Color(0xFF4FD1A5), // green
  Color(0xFFF2B35E), // amber
  Color(0xFFF277A8), // pink
  Color(0xFFB794F6), // violet
  Color(0xFF4DC8E0), // cyan
  Color(0xFFFF9A6B), // orange
  Color(0xFFB5D655), // lime
];

const _lightSources = [
  Color(0xFF1F63D1),
  Color(0xFF0B7D5C),
  Color(0xFF9A5B00),
  Color(0xFFC21F66),
  Color(0xFF6D3FD0),
  Color(0xFF0C7A92),
  Color(0xFFC24A0E),
  Color(0xFF5B7A0A),
];

class _LogLine extends StatelessWidget {
  final String text;
  final String query;
  final bool timestamps;
  final bool wrap;
  final bool highlight;
  final TextStyle style;

  // Aggregated streams: the line's source, its precomputed colour and the
  // prefix column width; [ts] is the timestamp the server sent separately.
  final LogSource? source;
  final Color? sourceColor;
  final double prefixWidth;
  final String? ts;
  final int kind;
  final ValueChanged<LogSource>? onSource;
  const _LogLine({
    required this.text,
    required this.query,
    required this.timestamps,
    required this.wrap,
    required this.style,
    required this.highlight,
    this.source,
    this.sourceColor,
    this.prefixWidth = 0,
    this.ts,
    this.kind = 0,
    this.onSource,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (source != null && kind != 0) {
      // A notice: dim divider (pod started / stopped) or a problem.
      final color = kind == 2 ? severityColor(context, Severity.warn) : theme.hintColor;
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        alignment: wrap ? null : Alignment.centerLeft,
        child: Text(
          text,
          style: style.copyWith(color: color, fontStyle: FontStyle.italic),
          softWrap: wrap,
          maxLines: wrap ? null : 1,
          overflow: wrap ? null : TextOverflow.clip,
        ),
      );
    }
    var body = text;
    String? stamp;
    if (source == null) {
      if (timestamps) {
        final m = _tsRe.firstMatch(text);
        if (m != null) {
          stamp = m.group(0);
          body = text.substring(m.end);
        }
      }
    } else if (timestamps && ts != null && ts!.isNotEmpty) {
      stamp = '$ts ';
    }
    final head = body.length > 300 ? body.substring(0, 300) : body;
    final level = _errRe.hasMatch(head) ? Severity.error : (_warnRe.hasMatch(head) ? Severity.warn : null);
    final base = level == null ? style : style.copyWith(color: severityColor(context, level).withValues(alpha: 0.95));
    final spans = <InlineSpan>[
      if (stamp != null)
        TextSpan(
          text: stamp,
          style: style.copyWith(color: theme.hintColor),
        ),
      ..._highlight(body, base),
    ];
    final content = Text.rich(
      TextSpan(children: spans),
      softWrap: wrap,
      maxLines: wrap ? null : 1,
      overflow: wrap ? null : TextOverflow.clip,
    );
    final src = source;
    return Container(
      color: highlight ? theme.colorScheme.primary.withValues(alpha: 0.07) : null,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: wrap || src != null ? null : Alignment.centerLeft,
      child: src == null
          ? content
          : Row(
              crossAxisAlignment: wrap ? CrossAxisAlignment.start : CrossAxisAlignment.center,
              children: [
                SizedBox(
                  width: prefixWidth,
                  child: Tooltip(
                    message: src.full,
                    waitDuration: const Duration(milliseconds: 400),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: GestureDetector(
                        onTap: onSource == null ? null : () => onSource!(src),
                        child: Text(
                          src.label,
                          maxLines: 1,
                          overflow: TextOverflow.clip,
                          style: style.copyWith(color: sourceColor, fontWeight: FontWeight.w600),
                        ),
                      ),
                    ),
                  ),
                ),
                Expanded(child: content),
              ],
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
