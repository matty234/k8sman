import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_state.dart';
import '../state/frame_stream.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'hubble_api.dart';

/// The verdict filter's choices: all, or one verdict.
const verdictChoices = <(String?, String)>[
  (null, 'All'),
  ('FORWARDED', 'Forwarded'),
  ('DROPPED', 'Dropped'),
  ('ERROR', 'Error'),
  ('AUDIT', 'Audit'),
];

Severity verdictSeverity(String v) => switch (v) {
      'FORWARDED' => Severity.ok,
      'DROPPED' || 'ERROR' => Severity.error,
      'AUDIT' => Severity.warn,
      _ => Severity.neutral,
    };

String verdictLabel(String v) => switch (v) {
      'FORWARDED' => 'forwarded',
      'DROPPED' => 'dropped',
      'ERROR' => 'error',
      'AUDIT' => 'audit',
      'TRACED' => 'traced',
      'TRANSLATED' => 'translated',
      'REDIRECTED' => 'redirected',
      _ => v.toLowerCase(),
    };

/// A drop reason for people: POLICY_DENIED → "policy denied".
String dropReasonLabel(String? r) => r == null || r.isEmpty ? 'dropped' : r.toLowerCase().replaceAll('_', ' ');

/// Live flows for [query]: a toolbar (verdict filter, pause/follow, clear,
/// counts), the virtualised list and the selected flow's details. Owns its
/// [FrameStream]; changing [query] or the verdict filter restarts it, so
/// the relay filters at the source.
class FlowStreamView extends StatefulWidget {
  final FlowQuery query;
  final HubbleApi api;

  /// Two-line rows for narrow places (the inspector).
  final bool compact;

  /// Shown above the toolbar (the Hubble page's own filters).
  final Widget? filters;

  /// Shown when the stream is live but nothing has arrived.
  final String emptyHint;

  const FlowStreamView({super.key, required this.query, required this.api, this.compact = false, this.filters, this.emptyHint = 'No flows yet'});

  @override
  State<FlowStreamView> createState() => _FlowStreamViewState();
}

class _FlowStreamViewState extends State<FlowStreamView> {
  String? _verdict;
  late FrameStream<HubbleFlow> _stream;
  HubbleFlow? _selected;

  FlowQuery get _query => widget.query.copyWith(verdicts: _verdict == null ? widget.query.verdicts : {_verdict!});

  @override
  void initState() {
    super.initState();
    _stream = widget.api.stream(_query)..start();
  }

  @override
  void didUpdateWidget(FlowStreamView old) {
    super.didUpdateWidget(old);
    if (old.query != widget.query || old.api != widget.api) _restart();
  }

  void _restart() {
    _stream.dispose();
    _selected = null;
    _stream = widget.api.stream(_query)..start();
  }

  @override
  void dispose() {
    _stream.dispose();
    super.dispose();
  }

  void _setVerdict(String? v) {
    if (v == _verdict) return;
    setState(() {
      _verdict = v;
      _restart();
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = AppColors.of(context);
    return ListenableBuilder(
      listenable: _stream,
      builder: (context, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (widget.filters != null) widget.filters!,
        _Toolbar(stream: _stream, verdict: _verdict, onVerdict: _setVerdict, compact: widget.compact),
        Container(height: 1, color: colors.separator),
        Expanded(child: _body(context)),
        if (_selected != null) ...[
          Container(height: 1, color: colors.separator),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: widget.compact ? 220 : 260),
            child: FlowDetails(flow: _selected!, onClose: () => setState(() => _selected = null)),
          ),
        ],
      ]),
    );
  }

  Widget _body(BuildContext context) {
    final s = _stream;
    if (s.items.isEmpty) {
      final Widget msg = switch (s.phase) {
        FramePhase.connecting => const Row(mainAxisSize: MainAxisSize.min, children: [
            SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)),
            SizedBox(width: 8),
            Text('Connecting to Hubble Relay…'),
          ]),
        FramePhase.error => InlineMessage(s.error ?? 'error', isError: true),
        _ => InlineMessage(s.paused && s.pendingCount > 0 ? '${s.pendingCount} new flows while paused' : widget.emptyHint, icon: Icons.swap_horiz),
      };
      return Align(alignment: Alignment.topLeft, child: Padding(padding: const EdgeInsets.all(12), child: msg));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (s.phase == FramePhase.error) Padding(padding: const EdgeInsets.fromLTRB(10, 6, 10, 6), child: InlineMessage(s.error ?? 'error', isError: true)),
      Expanded(
        child: FlowList(
          flows: s.items,
          compact: widget.compact,
          paused: s.paused,
          selected: _selected,
          onSelect: (f) => setState(() => _selected = identical(f, _selected) ? null : f),
          onScrolledAway: s.pause,
          onScrolledBack: s.resume,
        ),
      ),
    ]);
  }
}

class _Toolbar extends StatelessWidget {
  final FrameStream<HubbleFlow> stream;
  final String? verdict;
  final ValueChanged<String?> onVerdict;
  final bool compact;
  const _Toolbar({required this.stream, required this.verdict, required this.onVerdict, required this.compact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = stream;
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final status = [
      '${s.items.length} flow${s.items.length == 1 ? '' : 's'}',
      if (s.lost > 0) '${s.lost} skipped',
      if (s.paused) 'paused${s.pendingCount > 0 ? ', ${s.pendingCount} new' : ''}',
      if (s.phase == FramePhase.ended) 'ended',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
        _VerdictFilter(value: verdict, onChanged: onVerdict),
        Tooltip(
          message: s.paused ? 'Show new flows and follow them' : 'Stop the list moving (new flows wait)',
          child: OutlinedButton.icon(
            key: const ValueKey('flows-pause'),
            style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 8)),
            icon: Icon(s.paused ? Icons.play_arrow : Icons.pause, size: 15),
            label: Text(s.paused ? 'Follow' : 'Pause'),
            onPressed: s.paused ? s.resume : s.pause,
          ),
        ),
        IconButton(tooltip: 'Clear', iconSize: 16, visualDensity: VisualDensity.compact, icon: const Icon(Icons.clear_all), onPressed: s.clear),
        Tooltip(
          message: 'Skipped flows went past the rate the app shows (1,000 a second) or were lost by the relay. Narrow the filters to see them all.',
          child: Text(status, key: const ValueKey('flows-status'), style: small),
        ),
      ]),
    );
  }
}

class _VerdictFilter extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;
  const _VerdictFilter({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      decoration: BoxDecoration(border: Border.all(color: theme.dividerColor), borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        for (final (v, label) in verdictChoices)
          Hoverable(
            onTap: () => onChanged(v),
            builder: (h) {
              final on = v == value;
              final c = v == null ? theme.colorScheme.primary : severityColor(context, verdictSeverity(v));
              return Container(
                key: ValueKey('verdict-${v ?? 'all'}'),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: on ? c.withValues(alpha: 0.16) : (h ? theme.colorScheme.onSurface.withValues(alpha: 0.05) : null),
                  borderRadius: BorderRadius.circular(5),
                ),
                child: Text(label, style: theme.textTheme.bodySmall?.copyWith(color: on ? c : null, fontWeight: on ? FontWeight.w600 : null)),
              );
            },
          ),
      ]),
    );
  }
}

/// Fixed-height, virtualised rows of [flows], newest at the bottom. Scrolling
/// up calls [onScrolledAway] (so the owner can pause the list under the
/// reader); scrolling back to the newest calls [onScrolledBack].
class FlowList extends StatefulWidget {
  final List<HubbleFlow> flows;
  final bool compact;
  final bool paused;
  final HubbleFlow? selected;
  final ValueChanged<HubbleFlow>? onSelect;
  final VoidCallback? onScrolledAway;
  final VoidCallback? onScrolledBack;

  const FlowList({
    super.key,
    required this.flows,
    this.compact = false,
    this.paused = false,
    this.selected,
    this.onSelect,
    this.onScrolledAway,
    this.onScrolledBack,
  });

  static double rowHeight(bool compact) => compact ? 40 : 24;

  @override
  State<FlowList> createState() => _FlowListState();
}

class _FlowListState extends State<FlowList> {
  final _scroll = ScrollController();
  bool _away = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_onScroll);
  }

  @override
  void didUpdateWidget(FlowList old) {
    super.didUpdateWidget(old);
    // Follow pressed while scrolled up: back to the newest.
    if (old.paused && !widget.paused && _away && _scroll.hasClients) {
      _away = false;
      _scroll.jumpTo(0);
    }
  }

  void _onScroll() {
    // reverse: offset 0 is the newest row.
    final away = _scroll.offset > 2;
    if (away == _away) return;
    _away = away;
    if (away) {
      widget.onScrolledAway?.call();
    } else {
      widget.onScrolledBack?.call();
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.flows.length;
    return Scrollbar(
      controller: _scroll,
      child: ListView.builder(
        controller: _scroll,
        reverse: true,
        itemExtent: FlowList.rowHeight(widget.compact),
        itemCount: n,
        itemBuilder: (context, i) {
          final f = widget.flows[n - 1 - i];
          return FlowRow(
            key: ObjectKey(f),
            flow: f,
            compact: widget.compact,
            selected: identical(f, widget.selected),
            onTap: widget.onSelect == null ? null : () => widget.onSelect!(f),
          );
        },
      ),
    );
  }
}

/// One flow: time, verdict, source → destination (links to the pods or
/// services), protocol and port, and the drop reason or L7 detail. Drops
/// are tinted, with the reason in the error colour.
class FlowRow extends StatelessWidget {
  final HubbleFlow flow;
  final bool compact;
  final bool selected;
  final VoidCallback? onTap;
  const FlowRow({super.key, required this.flow, this.compact = false, this.selected = false, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final f = flow;
    final err = severityColor(context, Severity.error);
    final bad = f.dropped || f.verdict == 'ERROR';
    final small = theme.textTheme.bodySmall!;
    final faint = small.copyWith(color: colors.faint);
    final time = Text(_time(f.time), style: monoStyle(context, size: 11, color: colors.faint));
    final verdict = SizedBox(width: 78, child: Align(alignment: Alignment.centerLeft, child: StatusBadge(verdictLabel(f.verdict), severity: verdictSeverity(f.verdict), dense: true)));
    final l4 = Text(_l4(f), style: monoStyle(context, size: 11, color: theme.hintColor), maxLines: 1, overflow: TextOverflow.ellipsis);
    final info = _info(f);
    final infoText = info == null
        ? const SizedBox.shrink()
        : Text(info, maxLines: 1, overflow: TextOverflow.ellipsis, style: bad ? small.copyWith(color: err, fontWeight: FontWeight.w600) : faint);
    final route = Row(children: [
      Flexible(child: FlowEndpointText(f.source)),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: Icon(Icons.arrow_forward, size: 12, color: theme.hintColor)),
      Flexible(child: FlowEndpointText(f.destination)),
    ]);
    final Widget body = compact
        ? Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [time, const SizedBox(width: 8), verdict, SizedBox(width: 92, child: l4), Expanded(child: infoText)]),
            const SizedBox(height: 2),
            route,
          ])
        : Row(children: [
            SizedBox(width: 92, child: time),
            verdict,
            Expanded(flex: 5, child: route),
            const SizedBox(width: 8),
            SizedBox(width: 96, child: l4),
            Expanded(flex: 3, child: infoText),
          ]);
    return Material(
      color: selected
          ? colors.selection
          : bad
              ? err.withValues(alpha: theme.brightness == Brightness.dark ? 0.10 : 0.06)
              : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(border: Border(left: BorderSide(color: bad ? err : Colors.transparent, width: 3))),
          padding: const EdgeInsets.fromLTRB(7, 0, 10, 0),
          child: body,
        ),
      ),
    );
  }

  static String _time(DateTime? t) {
    if (t == null) return '';
    final l = t.toLocal();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(l.hour)}:${two(l.minute)}:${two(l.second)}.${l.millisecond.toString().padLeft(3, '0')}';
  }

  static String _l4(HubbleFlow f) {
    final p = f.protocol ?? '';
    final port = f.destination.port;
    return [if (p.isNotEmpty) p, if (port != null && port > 0) ':$port'].join();
  }

  static String? _info(HubbleFlow f) {
    if (f.dropped) return dropReasonLabel(f.dropReason);
    final l7 = f.l7Summary;
    if (l7 != null) return l7;
    final flags = f.tcpFlags.isEmpty ? null : f.tcpFlags.join(',');
    return [if (f.direction != null) f.direction!.toLowerCase(), if (f.isReply) 'reply', ?flags].join(' · ');
  }
}

/// An endpoint's name; pods and services link to their inspector.
class FlowEndpointText extends StatelessWidget {
  final FlowEndpoint e;
  const FlowEndpointText(this.e, {super.key});

  @override
  Widget build(BuildContext context) {
    final ref = e.ref;
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall;
    final label = e.label;
    final tip = [
      if (e.workloadKind != null && e.workloadName != null) '${e.workloadKind}/${e.workloadName}',
      if (e.ip != null) '${e.ip}${e.port != null && e.port! > 0 ? ':${e.port}' : ''}',
      if (e.identity != null) 'identity ${e.identity}',
    ].join('\n');
    final Widget w;
    if (ref == null || !_hasApp(context)) {
      w = Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: e.pod == null && e.service == null ? style?.copyWith(fontStyle: FontStyle.italic) : style);
    } else {
      w = ResourceLink(ref, label: label, singleLine: true);
    }
    return tip.isEmpty ? w : Tooltip(message: tip, waitDuration: const Duration(milliseconds: 500), child: w);
  }

  static bool _hasApp(BuildContext context) {
    try {
      context.read<AppState>();
      return true;
    } catch (_) {
      return false;
    }
  }
}

/// Every field of one flow, for the row the user clicked.
class FlowDetails extends StatelessWidget {
  final HubbleFlow flow;
  final VoidCallback onClose;
  const FlowDetails({super.key, required this.flow, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final f = flow;
    final err = severityColor(context, Severity.error);
    String side(FlowEndpoint e) => [
          e.label,
          if (e.workloadKind != null && e.workloadName != null) '(${e.workloadKind}/${e.workloadName})',
          if (e.ip != null) '${e.ip}${e.port != null && e.port! > 0 ? ':${e.port}' : ''}',
          if (e.service != null && e.pod != null) 'via service ${e.service}',
          if (e.identity != null) 'identity ${e.identity}',
        ].join('  ');
    return SelectionArea(
      child: ListView(padding: const EdgeInsets.fromLTRB(12, 6, 8, 10), children: [
        Row(children: [
          Text('Flow', style: theme.textTheme.titleSmall),
          const SizedBox(width: 8),
          StatusBadge(verdictLabel(f.verdict), severity: verdictSeverity(f.verdict)),
          const Spacer(),
          IconButton(tooltip: 'Close', iconSize: 16, visualDensity: VisualDensity.compact, icon: const Icon(Icons.close), onPressed: onClose),
        ]),
        KeyValueTable(keyWidth: 110, [
          ('Time', f.time?.toLocal().toIso8601String()),
          if (f.dropped) ('Drop reason', Text(dropReasonLabel(f.dropReason), style: theme.textTheme.bodySmall?.copyWith(color: err, fontWeight: FontWeight.w600))),
          ('Source', side(f.source)),
          ('Destination', side(f.destination)),
          ('Protocol', [f.protocol, if (f.tcpFlags.isNotEmpty) f.tcpFlags.join(',')].whereType<String>().join('  ')),
          ('Direction', [f.direction?.toLowerCase(), if (f.isReply) 'reply'].whereType<String>().join(', ')),
          ('L7', [f.l7Summary, if (f.l7LatencyMs != null && f.l7LatencyMs! > 0) '${f.l7LatencyMs!.toStringAsFixed(1)} ms'].whereType<String>().join('  ')),
          if (f.allowedBy.isNotEmpty) ('Allowed by', f.allowedBy.join(', ')),
          if (f.deniedBy.isNotEmpty) ('Denied by', f.deniedBy.join(', ')),
          ('Observed', [f.event, if (f.node != null) 'on ${f.node}'].whereType<String>().join(' ')),
        ]),
      ]),
    );
  }
}
