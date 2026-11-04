/// The node graph of an Argo Workflow (`status.nodes`) and a compact
/// layered (Sugiyama-style) top-down layout for it. Pure Dart, so it is
/// unit-testable without widgets.
///
/// Argo records the graph as `children` edges between nodes:
///   * a DAG/Steps node points at its first tasks / first step group;
///   * a task points at the tasks that depend on it (leaves of a nested
///     DAG/Steps point at the nested node's successors);
///   * a StepGroup points at its steps, and each step at the next group;
///   * a Retry node points at its attempts (`name(0)`, `name(1)`, ...).
///
/// The layout keeps DAG/Steps nodes (as group headers), draws StepGroup /
/// TaskGroup bookkeeping nodes as small junction dots, and folds retry
/// attempts into their Retry node (shown with an attempt count).
library;

import 'dart:math' as math;

import '../../api/models.dart';
import '../../util/k8s.dart';

/// One entry of `status.nodes`.
class WfNode {
  final String id;
  final String name;
  final String displayName;
  final String type;
  final String phase;
  final String? templateName;
  final Json? templateRef;
  final String? boundaryId;
  final List<String> children;
  final List<String> outbound;
  final Json raw;

  const WfNode({
    required this.id,
    required this.name,
    required this.displayName,
    required this.type,
    required this.phase,
    this.templateName,
    this.templateRef,
    this.boundaryId,
    this.children = const [],
    this.outbound = const [],
    this.raw = const {},
  });

  factory WfNode.fromJson(String id, Json j) => WfNode(
        id: '${j['id'] ?? id}',
        name: '${j['name'] ?? id}',
        displayName: '${j['displayName'] ?? j['name'] ?? id}',
        type: '${j['type'] ?? ''}',
        phase: '${j['phase'] ?? 'Pending'}',
        templateName: j['templateName'] as String?,
        templateRef: j['templateRef'] is Map ? asMap(j['templateRef']) : null,
        boundaryId: j['boundaryID'] as String?,
        children: [for (final c in (j['children'] as List? ?? const [])) '$c'],
        outbound: [for (final c in (j['outboundNodes'] as List? ?? const [])) '$c'],
        raw: j,
      );

  /// The template that ran: `templateName`, else the referenced template.
  String get template => templateName ?? '${templateRef?['template'] ?? ''}';

  bool get isPod => type == 'Pod';
  bool get isJunction => type == 'StepGroup' || type == 'TaskGroup';
  bool get isContainer => type == 'DAG' || type == 'Steps';
  bool get isRetry => type == 'Retry';

  /// Running suspend step (waiting for `argo resume`).
  bool get isWaiting => type == 'Suspend' && phase == 'Running';
  bool get failed => phase == 'Failed' || phase == 'Error';
  bool get skipped => phase == 'Skipped' || phase == 'Omitted';

  DateTime? get startedAt => parseTime(raw['startedAt']);
  DateTime? get finishedAt => parseTime(raw['finishedAt']);
  String? get message => (raw['message'] as String?)?.isNotEmpty == true ? raw['message'] as String : null;
  String? get exitCode => dig<String>(raw, ['outputs', 'exitCode']);
}

/// `status.nodes` by id.
Map<String, WfNode> parseNodes(Json workflow) {
  final nodes = asMap(dig(workflow, ['status', 'nodes']));
  return {for (final e in nodes.entries) if (e.value is Map) e.key: WfNode.fromJson(e.key, asMap(e.value))};
}

/// Attempts of a Retry node, oldest first.
List<WfNode> retryAttempts(WfNode retry, Map<String, WfNode> nodes) {
  final out = [
    for (final c in retry.children)
      if (nodes[c] != null && nodes[c]!.name.startsWith('${retry.name}(')) nodes[c]!,
  ];
  int n(WfNode x) => int.tryParse(RegExp(r'\((\d+)\)$').firstMatch(x.name)?.group(1) ?? '') ?? 0;
  out.sort((a, b) => n(a).compareTo(n(b)));
  return out;
}

/// The node whose pod is shown for [n]: itself, or a retry's last attempt.
WfNode podNodeFor(WfNode n, Map<String, WfNode> nodes) {
  if (n.isRetry) {
    final a = retryAttempts(n, nodes);
    if (a.isNotEmpty) return podNodeFor(a.last, nodes);
  }
  return n;
}

// ---------------------------------------------------------------------------
// Layout
// ---------------------------------------------------------------------------

/// [compact] is a Skipped/Omitted step, drawn as a small pill so the path
/// that ran dominates.
enum GKind { node, compact, container, junction, dummy }

/// A positioned box. [x], [y] are the top-left corner.
class GNode {
  final String id;
  final GKind kind;

  /// The workflow node (null for dummies).
  final WfNode? node;

  /// Retry attempts folded into this node.
  final int attempts;
  final double w;
  final double h;
  int layer = 0;
  double x = 0;
  double y = 0;
  GNode(this.id, this.kind, this.node, this.w, this.h, {this.attempts = 0});

  double get cx => x + w / 2;
  double get cy => y + h / 2;
}

/// An edge as a polyline: from the bottom of [from], through one waypoint
/// per intermediate layer, to the top of [to].
class GEdge {
  final String from;
  final String to;
  final List<(double, double)> points;

  /// Implicit edges (onExit handler, detached hooks, bypassed skipped steps).
  final bool dashed;
  const GEdge(this.from, this.to, this.points, {this.dashed = false});
}

class WfGraph {
  final List<GNode> nodes;
  final List<GEdge> edges;
  final double width;
  final double height;

  /// Raw node id → id of the visible node that stands for it.
  final Map<String, String> repOf;

  /// Skipped/Omitted steps left out ([layoutWorkflow]'s hideSkipped).
  final int hidden;
  const WfGraph(this.nodes, this.edges, this.width, this.height, this.repOf, {this.hidden = 0});

  static const empty = WfGraph([], [], 0, 0, {});

  GNode? byId(String id) {
    for (final n in nodes) {
      if (n.id == id) return n;
    }
    return null;
  }

  /// Visible (non-dummy) nodes.
  Iterable<GNode> get visible => nodes.where((n) => n.kind != GKind.dummy);
}

/// Sizes used by [layoutWorkflow]; the view draws to the same numbers.
class GraphMetrics {
  final double nodeW;
  final double nodeH;
  final double compactW;
  final double compactH;
  final double containerH;
  final double junction;
  final double dummyW;
  final double hGap;
  final double vGap;
  const GraphMetrics({
    this.nodeW = 150,
    this.nodeH = 36,
    this.compactW = 108,
    this.compactH = 22,
    this.containerH = 28,
    this.junction = 12,
    this.dummyW = 2,
    this.hGap = 12,
    this.vGap = 30,
  });
}

/// Skipped/Omitted share of the steps (junctions and the root excluded).
double skippedShare(Map<String, WfNode> nodes) {
  final steps = nodes.values.where((n) => !n.isJunction && !n.isContainer).toList();
  if (steps.isEmpty) return 0;
  return steps.where((n) => n.skipped).length / steps.length;
}

/// Lays out [nodes] top-down (a layered/Sugiyama layout): longest-path
/// layers, one waypoint per layer on long edges, crossing reduction by
/// median sweeps plus adjacent swaps, then priority placement that keeps
/// long edges in straight vertical channels. [workflowName] identifies the
/// root (whose id is the workflow name) and the onExit handler.
///
/// [hideSkipped] leaves Skipped/Omitted steps out; a step whose every
/// parent was hidden is attached (dashed) to its nearest shown ancestors.
WfGraph layoutWorkflow(
  Map<String, WfNode> nodes, {
  required String workflowName,
  GraphMetrics m = const GraphMetrics(),
  bool hideSkipped = false,
  bool reduceCrossings = true,
}) {
  if (nodes.isEmpty) return WfGraph.empty;

  // 1. Fold retry attempts into their Retry node.
  final rep = <String, String>{};
  final attemptCount = <String, int>{};
  for (final n in nodes.values) {
    if (!n.isRetry) continue;
    final a = retryAttempts(n, nodes);
    attemptCount[n.id] = a.length;
    for (final x in a) {
      rep[x.id] = n.id;
    }
  }
  String resolve(String id) {
    var cur = id;
    for (var i = 0; i < 32 && rep.containsKey(cur); i++) {
      cur = rep[cur]!;
    }
    return cur;
  }

  var visibleIds = [for (final id in nodes.keys) if (resolve(id) == id) id];

  // 2. Edges between visible nodes, in child order (deduplicated).
  final succ = <String, List<String>>{for (final id in visibleIds) id: []};
  final pred = <String, List<String>>{for (final id in visibleIds) id: []};
  final dashed = <(String, String)>{};
  void addEdge(String a, String b, {bool dash = false}) {
    if (a == b || !succ.containsKey(a) || !succ.containsKey(b) || succ[a]!.contains(b)) return;
    succ[a]!.add(b);
    pred[b]!.add(a);
    if (dash) dashed.add((a, b));
  }

  // Children of attempts come after the retry's own, so a retry of a
  // DAG/Steps template keeps its inner nodes attached.
  final order = [...nodes.values]..sort((a, b) => (rep.containsKey(a.id) ? 1 : 0).compareTo(rep.containsKey(b.id) ? 1 : 0));
  for (final n in order) {
    for (final c in n.children) {
      if (nodes.containsKey(c)) addEdge(resolve(n.id), resolve(c));
    }
  }

  // 3. Root, and attach orphans (onExit handler, hooks) with dashed edges
  //    from the root's leaves.
  final rootId = nodes.containsKey(workflowName) ? workflowName : (visibleIds.where((id) => pred[id]!.isEmpty).firstOrNull ?? visibleIds.first);
  final root = nodes[rootId]!;
  final leaves = {for (final o in root.outbound) if (nodes.containsKey(o)) resolve(o)}.toList();
  for (final id in visibleIds) {
    if (id == rootId || pred[id]!.isNotEmpty) continue;
    final b = nodes[id]!.boundaryId;
    if (b != null && b != rootId && nodes.containsKey(b)) {
      // Inside another template invocation but unlinked: hang it off that.
      addEdge(resolve(b), id, dash: true);
      continue;
    }
    final from = leaves.where((l) => l != id).toList();
    if (from.isEmpty) from.add(rootId);
    for (final f in from) {
      addEdge(f, id, dash: true);
    }
  }

  // 4. Optionally hide skipped steps, bridging over them only where a shown
  //    step would otherwise lose all its parents.
  var hiddenCount = 0;
  if (hideSkipped) {
    final hide = {for (final id in visibleIds) if (id != rootId && nodes[id]!.skipped) id};
    hiddenCount = hide.length;
    if (hide.isNotEmpty) {
      final origPred = {for (final e in pred.entries) e.key: [...e.value]};
      for (final h in hide) {
        for (final p in pred[h]!) {
          succ[p]?.remove(h);
        }
        for (final s in succ[h]!) {
          pred[s]?.remove(h);
        }
        succ.remove(h);
        pred.remove(h);
      }
      visibleIds = [for (final id in visibleIds) if (!hide.contains(id)) id];
      for (final id in visibleIds) {
        if (id == rootId || pred[id]!.isNotEmpty || origPred[id]!.isEmpty) continue;
        // Nearest shown ancestors through hidden steps.
        final seen = <String>{};
        final queue = [...origPred[id]!];
        final found = <String>[];
        while (queue.isNotEmpty) {
          final p = queue.removeAt(0);
          if (!seen.add(p)) continue;
          if (hide.contains(p)) {
            queue.addAll(origPred[p] ?? const []);
          } else {
            found.add(p);
          }
        }
        for (final a in found) {
          addEdge(a, id, dash: true);
        }
      }
    }
  }

  // 5. DFS from the root (then any leftovers) for a natural order, dropping
  //    back edges so the graph is acyclic.
  final dfsOrder = <String>[];
  final state = <String, int>{}; // 1 = on stack, 2 = done
  void dfs(String start) {
    final stack = <(String, int)>[(start, 0)];
    state[start] = 1;
    dfsOrder.add(start);
    while (stack.isNotEmpty) {
      final (id, i) = stack.removeLast();
      final out = succ[id]!;
      if (i < out.length) {
        final c = out[i];
        final s = state[c] ?? 0;
        if (s == 1) {
          out.removeAt(i); // back edge
          pred[c]!.remove(id);
          stack.add((id, i));
        } else {
          stack.add((id, i + 1));
          if (s == 0) {
            state[c] = 1;
            dfsOrder.add(c);
            stack.add((c, 0));
          }
        }
      } else {
        state[id] = 2;
      }
    }
  }

  dfs(rootId);
  for (final id in visibleIds) {
    if (!state.containsKey(id)) dfs(id);
  }

  // 6. Longest-path layering (Kahn order).
  final layer = <String, int>{};
  final indeg = {for (final id in visibleIds) id: pred[id]!.length};
  final queue = [for (final id in dfsOrder) if (indeg[id] == 0) id];
  for (final id in queue) {
    layer[id] = 0;
  }
  for (var qi = 0; qi < queue.length; qi++) {
    final id = queue[qi];
    for (final c in succ[id]!) {
      layer[c] = math.max(layer[c] ?? 0, layer[id]! + 1);
      indeg[c] = indeg[c]! - 1;
      if (indeg[c] == 0) queue.add(c);
    }
  }

  // 7. Graph nodes, with a dummy per intermediate layer on long edges.
  final g = <String, GNode>{};
  for (final id in dfsOrder) {
    final n = nodes[id]!;
    final kind = n.isJunction
        ? GKind.junction
        : n.isContainer
            ? GKind.container
            : (n.skipped ? GKind.compact : GKind.node);
    final (w, h) = switch (kind) {
      GKind.junction => (m.junction, m.junction),
      GKind.container => (m.nodeW, m.containerH),
      GKind.compact => (m.compactW, m.compactH),
      _ => (m.nodeW, m.nodeH),
    };
    g[id] = GNode(id, kind, n, w, h, attempts: attemptCount[id] ?? 0)..layer = layer[id] ?? 0;
  }
  final down = <String, List<String>>{for (final id in g.keys) id: []};
  final up = <String, List<String>>{for (final id in g.keys) id: []};
  final chains = <(String, String), List<String>>{};
  var dummyN = 0;
  for (final a in dfsOrder) {
    for (final b in succ[a]!) {
      final la = g[a]!.layer, lb = g[b]!.layer;
      var prev = a;
      final chain = <String>[];
      for (var l = la + 1; l < lb; l++) {
        final d = '\u0000d${dummyN++}';
        g[d] = GNode(d, GKind.dummy, null, m.dummyW, m.nodeH)..layer = l;
        down[d] = [];
        up[d] = [];
        down[prev]!.add(d);
        up[d]!.add(prev);
        chain.add(d);
        prev = d;
      }
      down[prev]!.add(b);
      up[b]!.add(prev);
      chains[(a, b)] = chain;
    }
  }

  // 8. Order within layers.
  final nLayers = g.values.fold<int>(0, (mx, n) => math.max(mx, n.layer + 1));
  final layers = List.generate(nLayers, (_) => <String>[]);
  final placed = <String>{};
  void place(String id) {
    if (!placed.add(id)) return;
    layers[g[id]!.layer].add(id);
    for (final c in down[id]!) {
      if (up[c]!.first == id || up[c]!.every(placed.contains)) place(c);
    }
  }

  for (final id in dfsOrder) {
    place(id);
  }
  for (final id in g.keys) {
    place(id);
  }
  if (reduceCrossings) _reduceCrossings(layers, up, down);

  // 9. X: priority placement. Each pass pulls a layer toward the median of
  //    its neighbours in the previous layer; dummies (long-edge channels)
  //    move first and are never pushed by real nodes, so long edges run
  //    straight down, then nodes by how connected they are.
  double gapBetween(GNode a, GNode b) => (a.kind == GKind.dummy || b.kind == GKind.dummy) ? m.hGap / 2 : m.hGap;
  final cx = <String, double>{};
  for (final l in layers) {
    var x = 0.0;
    for (final (i, id) in l.indexed) {
      final n = g[id]!;
      if (i > 0) x += gapBetween(g[l[i - 1]]!, n);
      cx[id] = x + n.w / 2;
      x += n.w;
    }
  }
  double median(List<String> ids) {
    final xs = [for (final i in ids) cx[i]!]..sort();
    final k = xs.length;
    return k.isOdd ? xs[k ~/ 2] : (xs[k ~/ 2 - 1] + xs[k ~/ 2]) / 2;
  }

  void placeLayer(List<String> ids, Map<String, double> want, Map<String, int> prio) {
    final n = ids.length;
    if (n == 0) return;
    final pos = [for (final id in ids) cx[id]!];
    double minD(int j) => g[ids[j - 1]]!.w / 2 + gapBetween(g[ids[j - 1]]!, g[ids[j]]!) + g[ids[j]]!.w / 2;
    final byPrio = [for (var i = 0; i < n; i++) i]..sort((a, b) => prio[ids[b]]!.compareTo(prio[ids[a]]!));
    final fixed = List<bool>.filled(n, false);
    for (final i in byPrio) {
      final target = want[ids[i]]!;
      if (target > pos[i]) {
        var limit = double.infinity, acc = 0.0;
        for (var j = i + 1; j < n; j++) {
          acc += minD(j);
          if (fixed[j]) {
            limit = pos[j] - acc;
            break;
          }
        }
        final p = math.min(target, limit);
        if (p > pos[i]) {
          pos[i] = p;
          for (var j = i + 1; j < n; j++) {
            pos[j] = math.max(pos[j], pos[j - 1] + minD(j));
          }
        }
      } else if (target < pos[i]) {
        var limit = double.negativeInfinity, acc = 0.0;
        for (var j = i - 1; j >= 0; j--) {
          acc += minD(j + 1);
          if (fixed[j]) {
            limit = pos[j] + acc;
            break;
          }
        }
        final p = math.max(target, limit);
        if (p < pos[i]) {
          pos[i] = p;
          for (var j = i - 1; j >= 0; j--) {
            pos[j] = math.min(pos[j], pos[j + 1] - minD(j + 1));
          }
        }
      }
      fixed[i] = true;
    }
    for (var i = 0; i < n; i++) {
      cx[ids[i]] = pos[i];
    }
  }

  for (var pass = 0; pass < 6; pass++) {
    final downward = pass.isEven;
    final range = downward ? [for (var l = 1; l < nLayers; l++) l] : [for (var l = nLayers - 2; l >= 0; l--) l];
    for (final l in range) {
      final want = <String, double>{};
      final prio = <String, int>{};
      for (final id in layers[l]) {
        final nb = downward ? up[id]! : down[id]!;
        want[id] = nb.isEmpty ? cx[id]! : median(nb);
        prio[id] = g[id]!.kind == GKind.dummy ? 1 << 20 : nb.length;
      }
      placeLayer(layers[l], want, prio);
    }
  }

  // 10. Coordinates.
  var minX = double.infinity, maxX = 0.0;
  for (final n in g.values) {
    minX = math.min(minX, cx[n.id]! - n.w / 2);
  }
  final rowH = m.nodeH;
  for (final n in g.values) {
    n.x = cx[n.id]! - n.w / 2 - minX;
    n.y = n.layer * (rowH + m.vGap) + (rowH - n.h) / 2;
    maxX = math.max(maxX, n.x + n.w);
  }
  final height = nLayers * rowH + (nLayers - 1) * m.vGap;

  // 11. Edge polylines.
  final edges = <GEdge>[];
  for (final MapEntry(key: (a, b), value: chain) in chains.entries) {
    final from = g[a]!, to = g[b]!;
    edges.add(GEdge(
      a,
      b,
      [
        (from.cx, from.y + from.h),
        for (final d in chain) (g[d]!.cx, g[d]!.cy),
        (to.cx, to.y),
      ],
      dashed: dashed.contains((a, b)),
    ));
  }

  final repOf = {for (final id in nodes.keys) id: resolve(id)};
  return WfGraph(g.values.toList(), edges, maxX, height, repOf, hidden: hiddenCount);
}

/// Crossing reduction: alternating median sweeps, each followed by
/// adjacent-swap (transpose) passes; keeps the best ordering seen.
void _reduceCrossings(List<List<String>> layers, Map<String, List<String>> up, Map<String, List<String>> down) {
  final total = layers.fold<int>(0, (s, l) => s + l.length);
  final big = total > 600;
  Map<String, int> positions() => {
        for (final l in layers)
          for (var i = 0; i < l.length; i++) l[i]: i,
      };
  int crossings() {
    final pos = positions();
    var c = 0;
    for (var l = 0; l + 1 < layers.length; l++) {
      c += _pairCrossings([
        for (final a in layers[l])
          for (final b in down[a]!) (pos[a]!, pos[b]!),
      ]);
    }
    return c;
  }

  // Crossings among edges of u and v to one neighbouring layer, u left of v.
  int local(String u, String v, Map<String, int> pos, Map<String, List<String>> nb) {
    var c = 0;
    for (final a in nb[u]!) {
      for (final b in nb[v]!) {
        if (pos[a]! > pos[b]!) c++;
      }
    }
    return c;
  }

  void transpose() {
    for (var round = 0; round < 4; round++) {
      var improved = false;
      final pos = positions();
      for (final l in layers) {
        for (var i = 0; i + 1 < l.length; i++) {
          final u = l[i], v = l[i + 1];
          final before = local(u, v, pos, up) + local(u, v, pos, down);
          final after = local(v, u, pos, up) + local(v, u, pos, down);
          if (after < before) {
            l[i] = v;
            l[i + 1] = u;
            pos[u] = i + 1;
            pos[v] = i;
            improved = true;
          }
        }
      }
      if (!improved) break;
    }
  }

  var best = [for (final l in layers) [...l]];
  var bestC = big ? 0 : crossings();
  final iters = big ? 4 : 16;
  for (var iter = 0; iter < iters && (big || bestC > 0); iter++) {
    final downward = iter.isEven;
    final range = downward ? [for (var l = 1; l < layers.length; l++) l] : [for (var l = layers.length - 2; l >= 0; l--) l];
    for (final l in range) {
      final pos = positions();
      final key = <String, double>{};
      for (final (i, id) in layers[l].indexed) {
        final nb = [for (final x in (downward ? up[id]! : down[id]!)) pos[x]!]..sort();
        key[id] = nb.isEmpty ? i.toDouble() : (nb.length.isOdd ? nb[nb.length ~/ 2].toDouble() : (nb[nb.length ~/ 2 - 1] + nb[nb.length ~/ 2]) / 2);
      }
      final idx = {for (final (i, id) in layers[l].indexed) id: i};
      layers[l].sort((a, b) {
        final c = key[a]!.compareTo(key[b]!);
        return c != 0 ? c : idx[a]!.compareTo(idx[b]!);
      });
    }
    if (!big) transpose();
    if (big) continue;
    final c = crossings();
    if (c < bestC) {
      bestC = c;
      best = [for (final l in layers) [...l]];
    }
  }
  if (big) return;
  for (var l = 0; l < layers.length; l++) {
    layers[l]
      ..clear()
      ..addAll(best[l]);
  }
}

int _pairCrossings(List<(int, int)> es) {
  var c = 0;
  for (var i = 0; i < es.length; i++) {
    for (var j = i + 1; j < es.length; j++) {
      if ((es[i].$1 - es[j].$1) * (es[i].$2 - es[j].$2) < 0) c++;
    }
  }
  return c;
}

/// Edge crossings of a laid-out graph, segment by segment between
/// adjacent layers (by x position). For tests and tuning.
int graphCrossings(WfGraph g, {GraphMetrics m = const GraphMetrics()}) {
  final byRow = <int, List<(double, double)>>{};
  for (final e in g.edges) {
    for (var i = 1; i < e.points.length; i++) {
      final (x0, y0) = e.points[i - 1];
      final (x1, _) = e.points[i];
      byRow.putIfAbsent((y0 / (m.nodeH + m.vGap)).floor(), () => []).add((x0, x1));
    }
  }
  var c = 0;
  for (final segs in byRow.values) {
    for (var i = 0; i < segs.length; i++) {
      for (var j = i + 1; j < segs.length; j++) {
        if ((segs[i].$1 - segs[j].$1) * (segs[i].$2 - segs[j].$2) < 0) c++;
      }
    }
  }
  return c;
}

// ---------------------------------------------------------------------------
// Tree (list view)
// ---------------------------------------------------------------------------

/// The nodes as an indented tree: each node under the template invocation
/// (DAG/Steps) it ran in, retry attempts under their Retry node. Junction
/// nodes are skipped. Siblings are in start order.
List<(WfNode, int)> nodeTree(Map<String, WfNode> nodes, {required String workflowName}) {
  if (nodes.isEmpty) return const [];
  final attemptOf = <String, String>{};
  for (final n in nodes.values) {
    if (n.isRetry) {
      for (final a in retryAttempts(n, nodes)) {
        attemptOf[a.id] = n.id;
      }
    }
  }
  final rootId = nodes.containsKey(workflowName) ? workflowName : nodes.keys.first;
  final kids = <String, List<WfNode>>{};
  for (final n in nodes.values) {
    if (n.id == rootId || n.isJunction) continue;
    var parent = attemptOf[n.id] ?? n.boundaryId;
    if (parent == null || !nodes.containsKey(parent)) parent = rootId;
    // A Retry node's attempts carry the Retry's own boundary; attempts of a
    // retried container are its parent instead.
    kids.putIfAbsent(parent, () => []).add(n);
  }
  int cmp(WfNode a, WfNode b) {
    final sa = a.startedAt, sb = b.startedAt;
    if (sa != null && sb != null && sa != sb) return sa.compareTo(sb);
    if (sa == null && sb != null) return 1;
    if (sb == null && sa != null) return -1;
    return a.name.compareTo(b.name);
  }

  final out = <(WfNode, int)>[];
  final seen = <String>{};
  void walk(WfNode n, int depth) {
    if (!seen.add(n.id)) return;
    out.add((n, depth));
    final cs = [...?kids[n.id]]..sort(cmp);
    for (final c in cs) {
      walk(c, depth + 1);
    }
  }

  walk(nodes[rootId]!, 0);
  for (final n in nodes.values) {
    if (!n.isJunction && !seen.contains(n.id)) walk(n, 1);
  }
  return out;
}
