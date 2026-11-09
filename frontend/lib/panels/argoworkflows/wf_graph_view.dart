/// Renders a workflow's node graph ([layoutWorkflow]) or an indented list,
/// and the details of the selected node (template, parameters, artifacts,
/// timing, exit code, logs).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/editorial.dart';
import '../../util/k8s.dart';
import '../argocd/argo_common.dart' show Hint;
import 'wf_common.dart';
import 'wf_graph.dart';
import '../../ui/inspector/inspector.dart' show Callout;

/// The selected node per workflow uid, shared by the failed-steps summary
/// and the graph. Bounded so it doesn't grow with every opened workflow.
class WorkflowSelection {
  static final Map<String, ValueNotifier<String?>> _byUid = {};
  static ValueNotifier<String?> of(String uid) {
    final hit = _byUid.remove(uid);
    final n = hit ?? ValueNotifier<String?>(null);
    _byUid[uid] = n; // most recent last
    while (_byUid.length > 30) {
      _byUid.remove(_byUid.keys.first);
    }
    return n;
  }
}

/// Graph above details. Above [listThreshold] visible nodes it starts in
/// list mode (a layered graph of hundreds of steps isn't readable).
class WorkflowNodesView extends StatefulWidget {
  final Json workflow;
  final ApiClient api;
  final int listThreshold;
  const WorkflowNodesView({super.key, required this.workflow, required this.api, this.listThreshold = 250});

  @override
  State<WorkflowNodesView> createState() => _WorkflowNodesViewState();
}

class _WorkflowNodesViewState extends State<WorkflowNodesView> {
  late ValueNotifier<String?> _sel;
  bool? _listMode;

  /// Leave Skipped/Omitted steps out of the graph. Defaults on when they
  /// are over 30% of the steps, so the path that ran dominates.
  bool? _hideSkipped;
  String _sig = '';
  WfGraph _graph = WfGraph.empty;
  Map<String, WfNode> _nodes = const {};

  String get _uid => dig<String>(widget.workflow, ['metadata', 'uid']) ?? dig<String>(widget.workflow, ['metadata', 'name']) ?? '';
  String get _name => dig<String>(widget.workflow, ['metadata', 'name']) ?? '';

  @override
  void initState() {
    super.initState();
    _sel = WorkflowSelection.of(_uid);
    _sel.addListener(_onSel);
    _relayout();
  }

  @override
  void didUpdateWidget(covariant WorkflowNodesView old) {
    super.didUpdateWidget(old);
    _relayout();
  }

  @override
  void dispose() {
    _sel.removeListener(_onSel);
    super.dispose();
  }

  void _onSel() => setState(() {});

  /// Re-layouts only when the graph's shape changes (phases don't move nodes).
  void _relayout() {
    _nodes = parseNodes(widget.workflow);
    _hideSkipped ??= skippedShare(_nodes) > 0.3;
    final sig = '${_nodes.length}/${_nodes.values.fold<int>(0, (s, n) => s + n.children.length + n.outbound.length)}/'
        '${_nodes.values.where((n) => n.skipped).length}/$_hideSkipped';
    if (sig != _sig) {
      _sig = sig;
      _graph = layoutWorkflow(_nodes, workflowName: _name, hideSkipped: _hideSkipped!);
    } else {
      // Same shape: refresh the node data (phases, times) in place.
      _graph = WfGraph(
        [
          for (final g in _graph.nodes)
            if (g.node != null && _nodes[g.id] != null)
              (GNode(g.id, g.kind, _nodes[g.id], g.w, g.h, attempts: g.attempts)
                ..layer = g.layer
                ..x = g.x
                ..y = g.y)
            else
              g,
        ],
        _graph.edges,
        _graph.width,
        _graph.height,
        _graph.repOf,
        hidden: _graph.hidden,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (_nodes.isEmpty) return const InlineMessage('No steps yet: the controller has not started this workflow.');
    final visibleCount = _nodes.values.where((n) => !n.isJunction && _graph.repOf[n.id] == n.id).length;
    final skipped = _nodes.values.where((n) => n.skipped).length;
    final list = _listMode ?? visibleCount > widget.listThreshold;
    final selId = _sel.value == null ? null : (_graph.repOf[_sel.value] ?? _sel.value);
    final selected = selId == null ? null : _nodes[selId];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        SegmentedButton<bool>(
          style: const ButtonStyle(visualDensity: VisualDensity.compact),
          showSelectedIcon: false,
          segments: const [
            ButtonSegment(value: false, icon: Icon(Icons.account_tree_outlined, size: 15), label: Text('Graph')),
            ButtonSegment(value: true, icon: Icon(Icons.format_list_bulleted, size: 15), label: Text('List')),
          ],
          selected: {list},
          onSelectionChanged: (s) => setState(() => _listMode = s.first),
        ),
        const Spacer(),
        if (!list && skipped > 0) ...[
          FilterChip(
            visualDensity: VisualDensity.compact,
            showCheckmark: true,
            label: Text('Hide $skipped skipped', style: theme.textTheme.bodySmall),
            tooltip: 'Leave Skipped and Omitted steps out of the graph',
            selected: _hideSkipped ?? false,
            onSelected: (v) => setState(() {
              _hideSkipped = v;
              _relayout();
            }),
          ),
          const SizedBox(width: 6),
        ],
        Text('$visibleCount steps', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        if (!list)
          IconButton(
            tooltip: 'Open the graph in a large window',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            icon: const Icon(Icons.open_in_full),
            onPressed: () => _showLarge(context),
          ),
      ]),
      const SizedBox(height: 8),
      if (list)
        _NodeList(nodes: _nodes, workflowName: _name, selected: selId, onSelect: _select)
      else
        _GraphViewport(key: ValueKey('viewport-$_hideSkipped'), graph: _graph, selected: selId, onSelect: _select),
      if (selected != null) ...[
        const SizedBox(height: 12),
        NodeDetails(key: ValueKey(selected.id), workflow: widget.workflow, node: selected, nodes: _nodes, api: widget.api, onSelect: _select, onClose: () => _select(null)),
      ] else
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Hint(list ? 'Select a step for its details and logs.' : 'Click a step for its details and logs.'),
        ),
    ]);
  }

  void _select(String? id) => _sel.value = id;

  Future<void> _showLarge(BuildContext context) => showDialog<void>(
        context: context,
        builder: (dctx) {
          final size = MediaQuery.sizeOf(dctx);
          return Dialog(
            insetPadding: const EdgeInsets.all(24),
            child: SizedBox(
              width: size.width - 48,
              height: size.height - 48,
              child: ValueListenableBuilder<String?>(
                valueListenable: _sel,
                builder: (context, sel, _) {
                  final id = sel == null ? null : (_graph.repOf[sel] ?? sel);
                  final node = id == null ? null : _nodes[id];
                  return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    Expanded(
                      child: _FittedGraph(
                        graph: _graph,
                        child: WorkflowGraphCanvas(graph: _graph, selected: id, onSelect: _select),
                      ),
                    ),
                    if (node != null)
                      Container(
                        width: 420,
                        decoration: BoxDecoration(border: Border(left: BorderSide(color: Theme.of(context).dividerColor))),
                        child: PageScroll(padding: const EdgeInsets.all(16), children: [
                          NodeDetails(
                              key: ValueKey(node.id), workflow: widget.workflow, node: node, nodes: _nodes, api: widget.api, onSelect: _select, onClose: () => _select(null)),
                        ]),
                      ),
                    Align(
                      alignment: Alignment.topRight,
                      child: IconButton(tooltip: 'Close', icon: const Icon(Icons.close), onPressed: () => Navigator.pop(dctx)),
                    ),
                  ]);
                },
              ),
            ),
          );
        },
      );
}

// ---------------------------------------------------------------------------
// Graph canvas
// ---------------------------------------------------------------------------

/// Fits the graph to the sidebar when it is only a little wider (down to
/// [minScale]); otherwise scrolls sideways, starting centred on the
/// selected node, else the first failed step, else the root.
class _GraphViewport extends StatefulWidget {
  final WfGraph graph;
  final String? selected;
  final ValueChanged<String?> onSelect;

  /// Below this the labels get hard to read, so the graph scrolls instead.
  static const minScale = 0.7;
  const _GraphViewport({super.key, required this.graph, required this.selected, required this.onSelect});

  @override
  State<_GraphViewport> createState() => _GraphViewportState();
}

class _GraphViewportState extends State<_GraphViewport> {
  final _scroll = ScrollController();
  bool _positioned = false;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final g = widget.graph;
    final canvas = WorkflowGraphCanvas(graph: g, selected: widget.selected, onSelect: widget.onSelect);
    return LayoutBuilder(builder: (context, box) {
      final avail = box.maxWidth;
      if (g.width <= avail) return Center(child: canvas);
      final scale = avail / g.width;
      if (scale >= _GraphViewport.minScale) {
        return SizedBox(width: avail, height: g.height * scale, child: FittedBox(fit: BoxFit.contain, alignment: Alignment.topLeft, child: canvas));
      }
      if (!_positioned) {
        _positioned = true;
        final target = initialScrollOffset(g, avail, selected: widget.selected);
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) _scroll.jumpTo(target.clamp(0.0, _scroll.position.maxScrollExtent));
        });
      }
      final canLeft = _scroll.hasClients && _scroll.offset > 1;
      final canRight = !_scroll.hasClients || _scroll.offset < _scroll.position.maxScrollExtent - 1;
      void by(double d) => _scroll.animateTo((_scroll.offset + d).clamp(0.0, _scroll.position.maxScrollExtent),
          duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      return Stack(children: [
        Scrollbar(
          controller: _scroll,
          thumbVisibility: true,
          child: SingleChildScrollView(
            controller: _scroll,
            scrollDirection: Axis.horizontal,
            child: Padding(padding: const EdgeInsets.only(bottom: 14), child: canvas),
          ),
        ),
        if (canLeft) _EdgeFade(left: true, onTap: () => by(-avail * 0.6)),
        if (canRight) _EdgeFade(left: false, onTap: () => by(avail * 0.6)),
      ]);
    });
  }
}

/// Where a scrolling graph starts: centred on the selected node, else the
/// first failed step, else the deepest running step, else the root; then
/// moved to the nearby offset that cuts the fewest nodes at either edge.
double initialScrollOffset(WfGraph g, double viewport, {String? selected}) {
  GNode? focus = selected == null ? null : g.byId(selected);
  final steps = g.nodes.where((n) => n.kind == GKind.node).toList()..sort((a, b) => a.y.compareTo(b.y));
  focus ??= steps.where((n) => n.node!.failed).firstOrNull;
  focus ??= steps.where((n) => n.node!.phase == 'Running').lastOrNull;
  focus ??= g.nodes.where((n) => n.layer == 0 && n.kind != GKind.dummy).firstOrNull;
  if (focus == null) return 0;
  final maxOff = (g.width - viewport).clamp(0.0, double.infinity);
  final centred = (focus.cx - viewport / 2).clamp(0.0, maxOff);
  final boxes = g.nodes.where((n) => n.kind != GKind.dummy).toList();
  bool shows(double o) => focus!.x >= o - 0.5 && focus.x + focus.w <= o + viewport + 0.5;
  int cuts(double o) => boxes.where((n) => (n.x < o && n.x + n.w > o) || (n.x < o + viewport && n.x + n.w > o + viewport)).length;
  // Candidates: centred, and every offset that puts an edge in a gap
  // beside some node.
  final candidates = <double>{
    centred,
    0,
    maxOff,
    for (final n in boxes) ...[(n.x - 6).clamp(0.0, maxOff), (n.x + n.w + 6 - viewport).clamp(0.0, maxOff)],
  }.where(shows).toList();
  if (candidates.isEmpty) return centred;
  candidates.sort((a, b) {
    final c = cuts(a).compareTo(cuts(b));
    return c != 0 ? c : (a - centred).abs().compareTo((b - centred).abs());
  });
  return candidates.first;
}

/// A fade at a scrollable edge with an arrow, so it's clear there's more.
class _EdgeFade extends StatelessWidget {
  final bool left;
  final VoidCallback onTap;
  const _EdgeFade({required this.left, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final bg = AppColors.of(context).inspector;
    return Positioned(
      top: 0,
      bottom: 14,
      left: left ? 0 : null,
      right: left ? null : 0,
      width: 36,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: left ? Alignment.centerLeft : Alignment.centerRight,
            end: left ? Alignment.centerRight : Alignment.centerLeft,
            colors: [bg, bg.withValues(alpha: 0)],
          ),
        ),
        child: Align(
          alignment: Alignment.topCenter,
          child: IconButton(
            tooltip: left ? 'Scroll left' : 'Scroll right',
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            icon: Icon(left ? Icons.chevron_left : Icons.chevron_right),
            onPressed: onTap,
          ),
        ),
      ),
    );
  }
}

/// The laid-out graph at its natural size: edges painted underneath,
/// nodes as positioned widgets.
class WorkflowGraphCanvas extends StatelessWidget {
  final WfGraph graph;
  final String? selected;
  final ValueChanged<String?> onSelect;
  const WorkflowGraphCanvas({super.key, required this.graph, required this.onSelect, this.selected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final byId = {for (final n in graph.nodes) n.id: n};
    return SizedBox(
      width: graph.width,
      height: graph.height,
      child: Stack(clipBehavior: Clip.none, children: [
        Positioned.fill(
          child: CustomPaint(
            painter: _EdgePainter(graph.edges, (id) {
              final n = byId[id]?.node;
              if (n == null) return theme.dividerColor;
              final s = wfPhaseStyle(context, n.phase);
              return n.skipped || n.phase == 'Pending' ? theme.hintColor.withValues(alpha: 0.45) : s.color.withValues(alpha: 0.55);
            }),
          ),
        ),
        for (final n in graph.nodes)
          if (n.kind != GKind.dummy)
            Positioned(
              left: n.x,
              top: n.y,
              width: n.w,
              height: n.h,
              child: _GraphNode(n, selected: n.id == selected, onTap: () => onSelect(n.id == selected ? null : n.id)),
            ),
      ]),
    );
  }
}

class _EdgePainter extends CustomPainter {
  final List<GEdge> edges;
  final Color Function(String toId) colorFor;
  _EdgePainter(this.edges, this.colorFor);

  @override
  void paint(Canvas canvas, Size size) {
    for (final e in edges) {
      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..color = colorFor(e.to);
      final path = Path()..moveTo(e.points.first.$1, e.points.first.$2);
      for (var i = 1; i < e.points.length; i++) {
        final (x0, y0) = e.points[i - 1];
        final (x1, y1) = e.points[i];
        if ((x1 - x0).abs() < 0.5) {
          path.lineTo(x1, y1);
        } else {
          final my = (y0 + y1) / 2;
          path.cubicTo(x0, my, x1, my, x1, y1);
        }
      }
      if (e.dashed) {
        for (final m in path.computeMetrics()) {
          for (var d = 0.0; d < m.length; d += 7) {
            canvas.drawPath(m.extractPath(d, d + 4), paint);
          }
        }
      } else {
        canvas.drawPath(path, paint);
      }
      // Arrow head into the target.
      final (x, y) = e.points.last;
      canvas.drawPath(
          Path()
            ..moveTo(x - 3.5, y - 5)
            ..lineTo(x, y)
            ..lineTo(x + 3.5, y - 5),
          paint);
    }
  }

  @override
  bool shouldRepaint(covariant _EdgePainter old) => old.edges != edges || old.colorFor != colorFor;
}

class _GraphNode extends StatelessWidget {
  final GNode g;
  final bool selected;
  final VoidCallback onTap;
  const _GraphNode(this.g, {required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final n = g.node!;
    final phase = n.isWaiting ? 'Suspended' : n.phase;
    final s = wfPhaseStyle(context, phase);
    final dark = theme.brightness == Brightness.dark;
    final sel = theme.colorScheme.primary;
    final tooltip = [
      n.displayName,
      '${n.type} · $phase',
      if (n.template.isNotEmpty) 'template: ${n.template}',
      if (n.message != null) n.message!,
    ].join('\n');

    if (g.kind == GKind.junction) {
      return Tooltip(
        message: tooltip,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: s.color.withValues(alpha: n.skipped ? 0.3 : 0.8),
              border: selected ? Border.all(color: sel, width: 2) : null,
            ),
          ),
        ),
      );
    }
    if (g.kind == GKind.compact) {
      return Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 300),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: onTap,
            child: SelectionContainer.disabled(child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(11),
                border: Border.all(color: selected ? sel : theme.hintColor.withValues(alpha: 0.35), width: selected ? 2 : 1),
              ),
              child: Row(children: [
                Icon(Icons.remove, size: 11, color: theme.hintColor),
                const SizedBox(width: 3),
                Expanded(
                  child: Text(n.displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontSize: 10.5, height: 1.1)),
                ),
              ]),
            )),
          ),
        ),
      );
    }
    final dur = runDuration(n.raw['startedAt'], n.raw['finishedAt']);
    final container = g.kind == GKind.container;
    final muted = n.skipped;
    final body = Container(
      padding: const EdgeInsets.symmetric(horizontal: 7),
      decoration: BoxDecoration(
        color: container ? Colors.transparent : (dark ? s.color.withValues(alpha: muted ? 0.05 : 0.12) : s.color.withValues(alpha: muted ? 0.04 : 0.09)),
        borderRadius: BorderRadius.circular(container ? 14 : 6),
        border: Border.all(
          color: selected ? sel : s.color.withValues(alpha: muted ? 0.35 : (container ? 0.6 : 0.75)),
          width: selected ? 2 : 1,
          style: BorderStyle.solid,
        ),
      ),
      child: Row(children: [
        Icon(
          container ? (n.type == 'DAG' ? Icons.account_tree_outlined : Icons.format_list_numbered) : (n.isWaiting ? Icons.pause_circle : s.icon),
          size: 15,
          color: s.color,
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(n.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                  fontSize: 11.5,
                  height: 1.2,
                  color: muted ? theme.hintColor : null,
                  decoration: muted ? TextDecoration.lineThrough : null,
                  decorationColor: theme.hintColor,
                )),
            if (!container && (dur != null || n.template.isNotEmpty))
              Text(
                [if (n.type != 'Pod' && n.type != 'Retry') n.type, if (dur != null && !muted) formatRunDuration(dur), if (muted) n.phase.toLowerCase()].join(' · '),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontSize: 10, height: 1.2),
              ),
          ]),
        ),
        if (g.attempts > 1)
          Tooltip(
            message: '${g.attempts} attempts (retryStrategy)',
            child: Container(
              margin: const EdgeInsets.only(left: 3),
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(color: s.color.withValues(alpha: 0.2), borderRadius: BorderRadius.circular(3)),
              child: Text('×${g.attempts}', style: theme.textTheme.labelSmall?.copyWith(color: s.color, fontSize: 10, fontWeight: FontWeight.w700)),
            ),
          ),
      ]),
    );
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(cursor: SystemMouseCursors.click, child: GestureDetector(onTap: onTap, child: SelectionContainer.disabled(child: body))),
    );
  }
}

// ---------------------------------------------------------------------------
// List
// ---------------------------------------------------------------------------

class _NodeList extends StatelessWidget {
  final Map<String, WfNode> nodes;
  final String workflowName;
  final String? selected;
  final ValueChanged<String?> onSelect;
  const _NodeList({required this.nodes, required this.workflowName, required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final rows = nodeTree(nodes, workflowName: workflowName);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (n, depth) in rows)
        Hoverable(
          onTap: () => onSelect(n.id == selected ? null : n.id),
          builder: (h) {
            final dur = runDuration(n.raw['startedAt'], n.raw['finishedAt']);
            final sel = n.id == selected;
            return Container(
              color: sel ? theme.colorScheme.primary.withValues(alpha: 0.14) : (h ? theme.hoverColor : null),
              padding: EdgeInsets.fromLTRB(4.0 + depth * 14, 3, 4, 3),
              child: Row(children: [
                PhaseBadge(n.isWaiting ? 'Suspended' : n.phase, iconOnly: true),
                const SizedBox(width: 6),
                Expanded(
                  child: Text.rich(
                    TextSpan(children: [
                      TextSpan(text: n.displayName, style: TextStyle(fontWeight: n.isContainer ? FontWeight.w600 : FontWeight.w500, color: n.skipped ? theme.hintColor : null)),
                      if (n.template.isNotEmpty && n.template != n.displayName) TextSpan(text: '  ${n.template}', style: TextStyle(color: theme.hintColor)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                if (n.type != 'Pod') Padding(padding: const EdgeInsets.only(left: 6), child: Text(n.type, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor))),
                SizedBox(
                  width: 64,
                  child: Text(dur == null || n.skipped ? '' : formatRunDuration(dur),
                      textAlign: TextAlign.right, style: monoStyle(context, size: 11, color: theme.hintColor)),
                ),
              ]),
            );
          },
        ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Node details
// ---------------------------------------------------------------------------

/// Everything about one node, with Logs for pod steps.
class NodeDetails extends StatelessWidget {
  final Json workflow;
  final WfNode node;
  final Map<String, WfNode> nodes;
  final ApiClient api;
  final ValueChanged<String?> onSelect;
  final VoidCallback onClose;
  const NodeDetails({super.key, required this.workflow, required this.node, required this.nodes, required this.api, required this.onSelect, required this.onClose});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ns = dig<String>(workflow, ['metadata', 'namespace']);
    final podNode = podNodeFor(node, nodes);
    final hasPod = podNode.isPod;
    final attempts = node.isRetry ? retryAttempts(node, nodes) : const <WfNode>[];
    final raw = podNode.raw;
    final dur = runDuration(raw['startedAt'], raw['finishedAt']);
    final tref = node.templateRef ?? podNode.templateRef;
    final inputs = asMapList(dig(raw, ['inputs', 'parameters']));
    final outputs = asMapList(dig(raw, ['outputs', 'parameters']));
    final artifacts = [
      for (final a in asMapList(dig(raw, ['inputs', 'artifacts']))) ('in', a),
      for (final a in asMapList(dig(raw, ['outputs', 'artifacts']))) ('out', a),
    ];
    final msg = podNode.message ?? node.message;
    final phase = node.isWaiting ? 'Suspended' : node.phase;

    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: theme.dividerColor),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Text(node.displayName, maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600)),
          ),
          PhaseBadge(phase),
          IconButton(tooltip: 'Close', visualDensity: VisualDensity.compact, iconSize: 16, icon: const Icon(Icons.close), onPressed: onClose),
        ]),
        const SizedBox(height: 6),
        if (msg != null)
          Callout(
            severity: node.failed ? Severity.error : (node.isWaiting ? Severity.warn : Severity.info),
            icon: node.failed ? Icons.error_outline : Icons.info_outline,
            title: msg,
          ),
        if (hasPod || node.isWaiting)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(spacing: 8, runSpacing: 6, children: [
              if (hasPod)
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
                  icon: const Icon(Icons.notes, size: 16),
                  label: const Text('Logs'),
                  onPressed: () => openNodeLogs(context, api, workflow, podNode),
                ),
              if (hasPod) _PodLink(workflow: workflow, node: podNode, api: api),
            ]),
          ),
        KeyValueTable([
          ('Type', node.type + (attempts.length > 1 ? ' · ${attempts.length} attempts' : '')),
          (
            'Template',
            tref != null
                ? Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Text('${tref['template'] ?? ''}', style: monoStyle(context, size: 11.5)),
                    Text('in', style: TextStyle(color: theme.hintColor)),
                    ResourceLink(
                      ObjectRef(
                        group: wfGroup,
                        kind: tref['clusterScope'] == true ? 'ClusterWorkflowTemplate' : 'WorkflowTemplate',
                        name: '${tref['name']}',
                        namespace: tref['clusterScope'] == true ? null : ns,
                      ),
                      label: '${tref['name']}',
                    ),
                  ])
                : (node.template.isEmpty ? null : node.template),
          ),
          if (raw['startedAt'] != null) ('Started', formatLocalTime(parseTime(raw['startedAt']))),
          if (raw['finishedAt'] != null) ('Finished', formatLocalTime(parseTime(raw['finishedAt']))),
          if (dur != null && !node.skipped) ('Duration', formatRunDuration(dur) + (raw['finishedAt'] == null ? ' (running)' : '')),
          if (formatResourcesDuration(raw['resourcesDuration']).isNotEmpty) ('Resources', formatResourcesDuration(raw['resourcesDuration'])),
          if (podNode.exitCode != null)
            ('Exit code', Text(podNode.exitCode!, style: monoStyle(context, size: 12, color: podNode.exitCode == '0' ? null : severityColor(context, Severity.error)))),
          if (raw['hostNodeName'] != null) ('Node', ResourceLink(ObjectRef(kind: 'Node', name: '${raw['hostNodeName']}'), label: '${raw['hostNodeName']}')),
          if (raw['estimatedDuration'] is num && raw['finishedAt'] == null)
            ('Estimated', formatRunDuration(Duration(seconds: (raw['estimatedDuration'] as num).toInt()))),
          if (raw['memoizationStatus'] is Map) ('Memoized', dig(raw, ['memoizationStatus', 'hit']) == true ? 'cache hit' : 'cache miss'),
        ], keyWidth: 100),
        if (attempts.length > 1) ...[
          _sub(context, 'Attempts'),
          for (final (i, a) in attempts.indexed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(children: [
                PhaseBadge(a.phase, iconOnly: true),
                const SizedBox(width: 6),
                Text('#${i + 1}', style: monoStyle(context, size: 11.5)),
                const SizedBox(width: 8),
                Expanded(child: Text(a.message ?? a.phase, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
                if (a.exitCode != null) Text('exit ${a.exitCode}', style: monoStyle(context, size: 11, color: theme.hintColor)),
                if (a.isPod)
                  IconButton(
                    tooltip: 'Logs of attempt ${i + 1}',
                    visualDensity: VisualDensity.compact,
                    iconSize: 15,
                    icon: const Icon(Icons.notes),
                    onPressed: () => openNodeLogs(context, api, workflow, a),
                  ),
              ]),
            ),
        ],
        if (inputs.isNotEmpty) ...[_sub(context, 'Input parameters'), ParamTable(inputs)],
        if (outputs.isNotEmpty) ...[_sub(context, 'Output parameters'), ParamTable(outputs)],
        if (dig(raw, ['outputs', 'result']) != null) ...[
          _sub(context, 'Result'),
          Text('${dig(raw, ['outputs', 'result'])}', maxLines: 6, style: monoStyle(context, size: 11.5)),
        ],
        if (artifacts.isNotEmpty) ...[
          _sub(context, 'Artifacts'),
          for (final (dir, a) in artifacts)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                SizedBox(width: 28, child: Text(dir, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor))),
                SizedBox(width: 120, child: Text('${a['name']}', maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall)),
                Expanded(child: Text(artifactLocation(a), maxLines: 2, style: monoStyle(context, size: 11, color: theme.hintColor))),
              ]),
            ),
        ],
        if (node.isContainer) ...[
          _sub(context, 'Steps inside'),
          Wrap(spacing: 6, runSpacing: 4, children: [
            for (final c in nodes.values.where((x) => x.boundaryId == node.id && !x.isJunction && !x.name.endsWith(')')).take(40))
              ActionChip(
                visualDensity: VisualDensity.compact,
                avatar: PhaseBadge(c.phase, iconOnly: true),
                label: Text(c.displayName, style: theme.textTheme.bodySmall),
                onPressed: () => onSelect(c.id),
              ),
          ]),
        ],
        const SizedBox(height: 4),
        Align(
          alignment: Alignment.centerLeft,
          child: Text('node ${node.id}', style: monoStyle(context, size: 10.5, color: theme.hintColor)),
        ),
      ]),
    );
  }

  Widget _sub(BuildContext context, String s) => Padding(
        padding: const EdgeInsets.only(top: 10, bottom: 4),
        child: Text(s, style: Theme.of(context).textTheme.labelMedium?.copyWith(color: Theme.of(context).hintColor, fontWeight: FontWeight.w600)),
      );
}

/// Where an artifact lives (key / path only; never credentials).
String artifactLocation(Json a) {
  for (final k in const ['s3', 'gcs', 'azure', 'oss', 'hdfs', 'artifactory', 'http', 'git', 'raw']) {
    final v = asMap(a[k]);
    if (v.isEmpty) continue;
    final key = v['key'] ?? v['blob'] ?? v['path'] ?? v['url'] ?? v['repo'];
    final bucket = v['bucket'] ?? v['container'];
    return [k, if (bucket != null) '$bucket', if (key != null) '$key'].join(': ').replaceFirst(': ', ' ');
  }
  if (a['path'] != null) return 'path ${a['path']}';
  return '';
}

String formatLocalTime(DateTime? t) {
  if (t == null) return '';
  final l = t.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}:${two(l.second)}  (${formatAge(t)} ago)';
}

/// A link to the step's pod once found (looked up once per node).
class _PodLink extends StatefulWidget {
  final Json workflow;
  final WfNode node;
  final ApiClient api;
  const _PodLink({required this.workflow, required this.node, required this.api});

  @override
  State<_PodLink> createState() => _PodLinkState();
}

class _PodLinkState extends State<_PodLink> {
  late final Future<Json?> _pod = fetchWorkflowPods(widget.api, widget.workflow).then((pods) => findNodePod(widget.workflow, widget.node, pods), onError: (_) => null);

  @override
  Widget build(BuildContext context) => FutureBuilder<Json?>(
        future: _pod,
        builder: (context, snap) {
          final theme = Theme.of(context);
          if (snap.connectionState != ConnectionState.done) return const SizedBox(height: 28);
          final pod = snap.data;
          if (pod == null) {
            return Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('pod ${expectedPodName(widget.workflow, widget.node)} is gone', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            );
          }
          final name = '${dig(pod, ['metadata', 'name'])}';
          return Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.view_in_ar_outlined, size: 14, color: theme.hintColor),
              const SizedBox(width: 4),
              Flexible(child: ResourceLink(ObjectRef(kind: 'Pod', name: name, namespace: dig<String>(pod, ['metadata', 'namespace'])), label: name)),
            ]),
          );
        },
      );
}

/// A pannable, zoomable graph that starts fitted and centred in its view,
/// and re-fits when the view resizes (e.g. a details panel opens) until the
/// user pans or zooms; "Fit" puts it back.
class _FittedGraph extends StatefulWidget {
  final WfGraph graph;
  final Widget child;
  const _FittedGraph({required this.graph, required this.child});

  @override
  State<_FittedGraph> createState() => _FittedGraphState();
}

class _FittedGraphState extends State<_FittedGraph> {
  static const _pad = 24.0;
  final _ctrl = TransformationController();
  Size? _view;
  bool _userMoved = false;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _fit(Size view) {
    final w = widget.graph.width + _pad * 2, h = widget.graph.height + _pad * 2;
    if (w <= 0 || h <= 0 || view.isEmpty) return;
    final scale = math.min(1.0, math.min(view.width / w, view.height / h)).clamp(0.2, 1.0);
    final dx = (view.width - w * scale) / 2, dy = (view.height - h * scale) / 2;
    _ctrl.value = Matrix4.identity()
      ..translateByDouble(math.max(0.0, dx), math.max(0.0, dy), 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, box) {
        final view = box.biggest;
        if (view != _view && !_userMoved) {
          _view = view;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) _fit(view);
          });
        }
        _view = view;
        return Stack(children: [
          ClipRect(
            child: InteractiveViewer(
              transformationController: _ctrl,
              constrained: false,
              minScale: 0.2,
              maxScale: 2.5,
              boundaryMargin: const EdgeInsets.all(400),
              onInteractionStart: (_) => _userMoved = true,
              child: Padding(padding: const EdgeInsets.all(_pad), child: widget.child),
            ),
          ),
          Positioned(
            left: 8,
            bottom: 8,
            child: TextButton.icon(
              key: const ValueKey('wf-graph-fit'),
              onPressed: () {
                _userMoved = false;
                _fit(view);
              },
              icon: const Icon(Icons.fit_screen_outlined, size: 16),
              label: const Text('Fit'),
            ),
          ),
        ]);
      });
}
