import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'pod_logic.dart';
import 'pod_widgets.dart';

/// Maximum lines kept in memory; older lines are dropped.
const int kMaxLogLines = 10000;

enum _Phase { connecting, streaming, eof, error, notStarted }

/// Streaming log viewer for one pod. Key it by pod uid.
class PodLogsView extends StatefulWidget {
  final PanelContext ctx;
  const PodLogsView({super.key, required this.ctx});

  @override
  State<PodLogsView> createState() => _PodLogsViewState();
}

class _PodLogsViewState extends State<PodLogsView> {
  // Options; changing any of these resubscribes.
  String? _container;
  bool _follow = true;
  bool _previous = false;
  bool _timestamps = false;
  int _tail = 500;

  // View-only options.
  bool _wrap = false;
  bool _onlyMatching = false;
  String _query = '';
  final _search = TextEditingController();

  final List<String> _lines = [];
  final List<String> _pending = [];
  int _dropped = 0;
  int _maxLen = 0;
  List<int>? _filtered;
  Timer? _flushTimer;
  StreamSubscription<LogMessage>? _sub;
  _Phase _phase = _Phase.connecting;
  String? _error;

  final _scroll = ScrollController();
  final _hScroll = ScrollController();
  bool _pinned = true;

  List<PodContainer> get _containers => podContainers(widget.ctx.object);
  PodContainer? get _current {
    for (final c in _containers) {
      if (c.name == _container) return c;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    final cs = _containers;
    final regular = cs.where((c) => c.kind == ContainerKind.regular).toList();
    final troubled = regular.where((c) => c.hasProblem && c.everStarted);
    _container = (troubled.isNotEmpty ? troubled.first : (regular.isNotEmpty ? regular.first : (cs.isNotEmpty ? cs.first : null)))?.name;
    _scroll.addListener(_onScroll);
    _subscribe();
  }

  @override
  void didUpdateWidget(PodLogsView old) {
    super.didUpdateWidget(old);
    // The pod object is live: if our container has since started, connect.
    if (_phase == _Phase.notStarted && (_current?.everStarted ?? false)) _subscribe();
  }

  @override
  void dispose() {
    _flushTimer?.cancel();
    _sub?.cancel();
    _scroll.dispose();
    _hScroll.dispose();
    _search.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (!_scroll.hasClients) return;
    final p = _scroll.position;
    final atBottom = p.pixels >= p.maxScrollExtent - 24;
    if (atBottom != _pinned) setState(() => _pinned = atBottom);
  }

  void _subscribe() {
    _sub?.cancel();
    _sub = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    _lines.clear();
    _pending.clear();
    _dropped = 0;
    _maxLen = 0;
    _filtered = null;
    _error = null;
    _pinned = true;
    final c = _current;
    final ns = widget.ctx.namespace;
    if (c == null || ns == null) {
      _phase = _Phase.error;
      _error = c == null ? 'No container selected' : 'Pod has no namespace';
      return;
    }
    if (!c.everStarted && !_previous) {
      _phase = _Phase.notStarted;
      return;
    }
    _phase = _Phase.connecting;
    _sub = widget.ctx.api
        .logs(
          namespace: ns,
          pod: widget.ctx.name,
          container: c.name,
          tailLines: _tail,
          previous: _previous,
          follow: _follow,
          timestamps: _timestamps,
        )
        .listen(
          _onMessage,
          onError: (Object e) => _finish(_Phase.error, '$e'),
          onDone: () => _finish(_Phase.eof),
        );
  }

  void _onMessage(LogMessage m) {
    if (m.error != null) return _finish(_Phase.error, m.error);
    if (m.eof) return _finish(_Phase.eof);
    final line = m.line;
    if (line == null) return;
    _pending.add(line.endsWith('\n') ? line.substring(0, line.length - (line.endsWith('\r\n') ? 2 : 1)) : line);
    _flushTimer ??= Timer(const Duration(milliseconds: 50), _flush);
  }

  void _finish(_Phase phase, [String? error]) {
    if (!mounted) return;
    if (_phase == _Phase.error || (_phase == _Phase.eof && phase == _Phase.eof)) return;
    _flush();
    setState(() {
      _phase = phase;
      _error = error;
    });
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (!mounted || _pending.isEmpty) return;
    setState(() {
      for (final l in _pending) {
        if (l.length > _maxLen) _maxLen = l.length;
      }
      _lines.addAll(_pending);
      _pending.clear();
      if (_lines.length > kMaxLogLines) {
        final n = _lines.length - kMaxLogLines;
        _lines.removeRange(0, n);
        _dropped += n;
      }
      _filtered = null;
      if (_phase == _Phase.connecting) _phase = _Phase.streaming;
    });
    if (_pinned) _jumpToEndSoon();
  }

  void _jumpToEndSoon() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _setOption(VoidCallback change) {
    setState(() {
      change();
      _subscribe();
    });
  }

  bool _matches(String line) => _query.isNotEmpty && line.toLowerCase().contains(_query.toLowerCase());

  List<int> get _matching {
    if (_filtered != null) return _filtered!;
    final q = _query.toLowerCase();
    return _filtered = [
      for (var i = 0; i < _lines.length; i++)
        if (q.isNotEmpty && _lines[i].toLowerCase().contains(q)) i,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = _current;
    final showOnly = _onlyMatching && _query.isNotEmpty;
    final indices = showOnly ? _matching : null;
    final count = indices?.length ?? _lines.length;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      _toolbar(context, c),
      Divider(height: 1, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
      if (_phase == _Phase.error && _lines.isNotEmpty)
        Padding(padding: const EdgeInsets.fromLTRB(10, 6, 10, 6), child: InlineMessage(_error ?? 'error', isError: true)),
      Expanded(
        child: Container(
          color: theme.colorScheme.surfaceContainerLowest,
          child: _lines.isEmpty ? _emptyState(context, c) : _logList(context, indices, count),
        ),
      ),
      _statusBar(context, c),
    ]);
  }

  Widget _toolbar(BuildContext context, PodContainer? c) {
    final theme = Theme.of(context);
    final canPrevious = (c?.restarts ?? 0) > 0 || (c?.lastTerminated.isNotEmpty ?? false);
    final matchCount = _query.isEmpty ? null : _matching.length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          _box(
            context,
            DropdownButton<String>(
              value: _container,
              isDense: true,
              underline: const SizedBox(),
              style: monoStyle(context, size: 12),
              hint: const Text('container'),
              items: [
                for (final x in _containers)
                  DropdownMenuItem(
                    value: x.name,
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Icon(Icons.circle, size: 8, color: severityColor(context, x.severity)),
                      const SizedBox(width: 6),
                      Text(x.name, style: monoStyle(context, size: 12)),
                      if (x.kind != ContainerKind.regular) ...[const SizedBox(width: 6), KindTag(x.kind)],
                      if (x.restarts > 0) ...[const SizedBox(width: 6), Text('${x.restarts}×', style: TextStyle(fontSize: 11, color: severityColor(context, Severity.warn)))],
                    ]),
                  ),
              ],
              onChanged: (v) => _setOption(() {
                _container = v;
                final nc = _current;
                if (_previous && (nc == null || (nc.restarts == 0 && nc.lastTerminated.isEmpty))) _previous = false;
              }),
            ),
          ),
          _box(
            context,
            DropdownButton<int>(
              value: _tail,
              isDense: true,
              underline: const SizedBox(),
              style: theme.textTheme.bodySmall,
              items: [
                for (final n in const [100, 500, 2000, -1]) DropdownMenuItem(value: n, child: Text(n < 0 ? 'all lines' : 'last $n')),
              ],
              onChanged: (v) => _setOption(() => _tail = v ?? 500),
            ),
          ),
          _Toggle(label: 'Follow', icon: Icons.play_arrow, value: _follow, onChanged: (v) => _setOption(() => _follow = v)),
          _Toggle(
            label: 'Previous',
            icon: Icons.history,
            value: _previous,
            tooltip: canPrevious ? 'Logs of the previous (crashed) instance' : 'No restarts: no previous instance',
            onChanged: canPrevious ? (v) => _setOption(() => _previous = v) : null,
          ),
          _Toggle(label: 'Timestamps', icon: Icons.schedule, value: _timestamps, onChanged: (v) => _setOption(() => _timestamps = v)),
          _Toggle(label: 'Wrap', icon: Icons.wrap_text, value: _wrap, onChanged: (v) => setState(() => _wrap = v)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(
            child: SizedBox(
              height: 30,
              child: TextField(
                controller: _search,
                style: monoStyle(context, size: 12),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Search logs',
                  prefixIcon: const Icon(Icons.search, size: 16),
                  prefixIconConstraints: const BoxConstraints(minWidth: 30),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          iconSize: 14,
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.close),
                          onPressed: () => setState(() {
                            _search.clear();
                            _query = '';
                            _filtered = null;
                          }),
                        ),
                  suffixText: matchCount == null ? null : '$matchCount match${matchCount == 1 ? '' : 'es'}',
                  suffixStyle: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
                  contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                  border: const OutlineInputBorder(),
                ),
                onChanged: (v) => setState(() {
                  _query = v;
                  _filtered = null;
                }),
              ),
            ),
          ),
          const SizedBox(width: 6),
          _Toggle(label: 'Only matching', icon: Icons.filter_list, value: _onlyMatching, onChanged: (v) => setState(() => _onlyMatching = v)),
          IconButton(
            tooltip: 'Copy all',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.copy_all),
            onPressed: _lines.isEmpty ? null : () => copyToClipboard(context, _lines.join('\n')),
          ),
          IconButton(
            tooltip: 'Clear',
            iconSize: 16,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.delete_sweep_outlined),
            onPressed: _lines.isEmpty
                ? null
                : () => setState(() {
                      _dropped += _lines.length;
                      _lines.clear();
                      _filtered = null;
                      _maxLen = 0;
                    }),
          ),
        ]),
      ]),
    );
  }

  Widget _box(BuildContext context, Widget child) => Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Center(widthFactor: 1, child: child),
      );

  Widget _emptyState(BuildContext context, PodContainer? c) {
    final Widget body;
    switch (_phase) {
      case _Phase.connecting:
        body = const Row(mainAxisSize: MainAxisSize.min, children: [
          SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Connecting…'),
        ]);
      case _Phase.notStarted:
        final w = c?.waiting ?? const {};
        body = InlineMessage(
          'Container ${c?.name} has not started yet'
          '${w['reason'] != null ? ': ${w['reason']}' : ''}'
          '${w['message'] != null ? '\n${w['message']}' : ''}',
          icon: Icons.hourglass_empty,
        );
      case _Phase.error:
        body = InlineMessage(_error ?? 'error', isError: true);
      case _Phase.eof || _Phase.streaming:
        final hint = !_previous && (c?.restarts ?? 0) > 0 ? ' — the container has restarted; try "Previous"' : '';
        body = InlineMessage('No log output$hint', icon: Icons.notes);
    }
    return Align(alignment: Alignment.topLeft, child: Padding(padding: const EdgeInsets.all(12), child: body));
  }

  Widget _logList(BuildContext context, List<int>? indices, int count) {
    final style = monoStyle(context, size: 12);
    const lineHeight = 17.0;
    final list = Scrollbar(
      controller: _scroll,
      thumbVisibility: true,
      child: ListView.builder(
        controller: _scroll,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemExtent: _wrap ? null : lineHeight,
        itemCount: count,
        itemBuilder: (context, i) {
          final idx = indices == null ? i : indices[i];
          return _LogLine(
            text: _lines[idx],
            query: _query,
            timestamps: _timestamps,
            wrap: _wrap,
            style: style,
            highlight: _matches(_lines[idx]),
          );
        },
      ),
    );
    final body = _wrap
        ? list
        : LayoutBuilder(builder: (context, box) {
            final charW = (TextPainter(text: TextSpan(text: 'MMMMMMMMMM', style: style), textDirection: TextDirection.ltr)..layout()).width / 10;
            final width = math.max(box.maxWidth, _maxLen * charW + 24);
            return Scrollbar(
              controller: _hScroll,
              child: SingleChildScrollView(
                controller: _hScroll,
                scrollDirection: Axis.horizontal,
                child: SizedBox(width: width, height: box.maxHeight, child: list),
              ),
            );
          });
    // Stay pinned when the viewport or content size changes (resize, wrap toggle).
    final pinnedBody = NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) {
        if (_pinned && n.metrics.axis == Axis.vertical && n.metrics.pixels < n.metrics.maxScrollExtent) _jumpToEndSoon();
        return false;
      },
      child: body,
    );
    return Stack(children: [
      Positioned.fill(child: SelectionArea(child: pinnedBody)),
      if (!_pinned)
        Positioned(
          right: 16,
          bottom: 12,
          child: FilledButton.tonalIcon(
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
            icon: const Icon(Icons.arrow_downward, size: 16),
            label: const Text('Jump to latest'),
            onPressed: () {
              setState(() => _pinned = true);
              _jumpToEndSoon();
            },
          ),
        ),
    ]);
  }

  Widget _statusBar(BuildContext context, PodContainer? c) {
    final theme = Theme.of(context);
    final (label, sev) = switch (_phase) {
      _Phase.connecting => ('connecting', Severity.info),
      _Phase.streaming => (_follow ? 'following' : 'loading', Severity.ok),
      _Phase.eof => ('end of stream', Severity.neutral),
      _Phase.error => ('error', Severity.error),
      _Phase.notStarted => ('not started', Severity.warn),
    };
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontSize: 11);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)))),
      child: Row(children: [
        Icon(Icons.circle, size: 8, color: severityColor(context, sev)),
        const SizedBox(width: 6),
        Text(label, style: small),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            [
              '${_lines.length} line${_lines.length == 1 ? '' : 's'}',
              if (_dropped > 0) '$_dropped older dropped',
              if (_previous) 'previous instance',
              if (c != null) c.name,
            ].join(' · '),
            style: small,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ]),
    );
  }
}

class _Toggle extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool value;
  final String? tooltip;
  final ValueChanged<bool>? onChanged;
  const _Toggle({required this.label, required this.icon, required this.value, this.onChanged, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = onChanged != null;
    final fg = !enabled ? theme.disabledColor : (value ? theme.colorScheme.primary : theme.hintColor);
    final chip = InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: enabled ? () => onChanged!(!value) : null,
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: value && enabled ? theme.colorScheme.primary.withValues(alpha: 0.14) : null,
          border: Border.all(color: value && enabled ? theme.colorScheme.primary.withValues(alpha: 0.6) : theme.colorScheme.outlineVariant),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: fg),
          const SizedBox(width: 4),
          Text(label, style: TextStyle(fontSize: 12, color: fg, fontWeight: value ? FontWeight.w600 : FontWeight.normal)),
        ]),
      ),
    );
    return Semantics(
      toggled: value,
      button: true,
      child: tooltip == null ? chip : Tooltip(message: tooltip!, child: chip),
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
      if (ts != null) TextSpan(text: ts, style: style.copyWith(color: theme.hintColor)),
      ..._highlight(body, base, theme),
    ];
    return Container(
      color: highlight ? theme.colorScheme.primary.withValues(alpha: 0.06) : null,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: wrap ? null : Alignment.centerLeft,
      child: Text.rich(TextSpan(children: spans), softWrap: wrap, maxLines: wrap ? null : 1, overflow: wrap ? null : TextOverflow.clip),
    );
  }

  List<InlineSpan> _highlight(String s, TextStyle base, ThemeData theme) {
    if (query.isEmpty) return [TextSpan(text: s, style: base)];
    final lower = s.toLowerCase();
    final q = query.toLowerCase();
    final out = <InlineSpan>[];
    var start = 0;
    while (true) {
      final i = lower.indexOf(q, start);
      if (i < 0) break;
      if (i > start) out.add(TextSpan(text: s.substring(start, i), style: base));
      out.add(TextSpan(
        text: s.substring(i, i + q.length),
        style: base.copyWith(backgroundColor: Colors.amber.withValues(alpha: 0.85), color: Colors.black),
      ));
      start = i + q.length;
    }
    if (start < s.length) out.add(TextSpan(text: s.substring(start), style: base));
    return out;
  }
}
