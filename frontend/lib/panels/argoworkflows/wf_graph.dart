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

enum GKind { node, container, junction, dummy }

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

/// An edge as a polyline: from the bottom of [from], through dummy points,
/// to the top of [to].
class GEdge {
  final String from;
  final String to;
  final List<(double, double)> points;

  /// Implicit edges (onExit handler, detached hooks).
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
  const WfGraph(this.nodes, this.edges, this.width, this.height, this.repOf);

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
  final double containerH;
  final double junction;
  final double dummyW;
  final double hGap;
  final double vGap;
  const GraphMetrics({
    this.nodeW = 160,
    this.nodeH = 36,
    this.containerH = 28,
    this.junction = 12,
    this.dummyW = 2,
    this.hGap = 14,
    this.vGap = 30,
  });
}

/// Lays out [nodes] top-down. [workflowName] identifies the root node
/// (whose id is the workflow name) and the onExit handler.
WfGraph layoutWorkflow(Map<String, WfNode> nodes, {required String workflowName, GraphMetrics m = const GraphMetrics()}) {
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

  final visibleIds = [for (final id in nodes.keys) if (resolve(id) == id) id];

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
    if (nodes[id]!.boundaryId != null && nodes[id]!.boundaryId != rootId && nodes.containsKey(nodes[id]!.boundaryId)) {
      // Inside another template invocation but unlinked: hang it off that.
      addEdge(resolve(nodes[id]!.boundaryId!), id, dash: true);
      continue;
    }
    final from = leaves.where((l) => l != id).toList();
    if (from.isEmpty) from.add(rootId);
    for (final f in from) {
      addEdge(f, id, dash: true);
    }
  }

  // 4. DFS from the root (then any leftovers) for a natural order, dropping
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
        stack.add((id, i + 1));
        final c = out[i];
        final s = state[c] ?? 0;
        if (s == 1) {
          out.removeAt(i); // back edge
          pred[c]!.remove(id);
          stack.removeLast();
          stack.add((id, i));
        } else if (s == 0) {
          state[c] = 1;
          dfsOrder.add(c);
          stack.add((c, 0));
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

  // 5. Longest-path layering (Kahn order).
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

  // 6. Graph nodes, with dummies on edges that span several layers.
  final g = <String, GNode>{};
  for (final id in dfsOrder) {
    final n = nodes[id]!;
    final kind = n.isJunction ? GKind.junction : (n.isContainer ? GKind.container : GKind.node);
    final (w, h) = switch (kind) {
      GKind.junction => (m.junction, m.junction),
      GKind.container => (m.nodeW, m.containerH),
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

  // 7. Order within layers: DFS-ish initial order (each node right after
  //    its first parent), then barycenter sweeps keeping the best ordering.
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

  Map<String, int> positions() => {
        for (final l in layers)
          for (var i = 0; i < l.length; i++) l[i]: i,
      };
  int crossings() {
    if (g.length > 600) return 0; // too big to count; just sweep
    final pos = positions();
    var c = 0;
    for (var l = 0; l + 1 < nLayers; l++) {
      final es = <(int, int)>[
        for (final a in layers[l])
          for (final b in down[a]!) (pos[a]!, pos[b]!),
      ];
      for (var i = 0; i < es.length; i++) {
        for (var j = i + 1; j < es.length; j++) {
          if ((es[i].$1 - es[j].$1) * (es[i].$2 - es[j].$2) < 0) c++;
        }
      }
    }
    return c;
  }

  var best = [for (final l in layers) [...l]];
  var bestC = crossings();
  for (var iter = 0; iter < 8 && bestC > 0; iter++) {
    final downward = iter.isEven;
    final range = downward ? [for (var l = 1; l < nLayers; l++) l] : [for (var l = nLayers - 2; l >= 0; l--) l];
    for (final l in range) {
      final pos = positions();
      final bary = <String, double>{};
      for (final (i, id) in layers[l].indexed) {
        final nb = downward ? up[id]! : down[id]!;
        bary[id] = nb.isEmpty ? i.toDouble() : nb.map((x) => pos[x]!).reduce((a, b) => a + b) / nb.length;
      }
      final idx = {for (final (i, id) in layers[l].indexed) id: i};
      layers[l].sort((a, b) {
        final c = bary[a]!.compareTo(bary[b]!);
        return c != 0 ? c : idx[a]!.compareTo(idx[b]!);
      });
    }
    final c = crossings();
    if (c < bestC) {
      bestC = c;
      best = [for (final l in layers) [...l]];
    }
  }
  for (var l = 0; l < nLayers; l++) {
    layers[l]
      ..clear()
      ..addAll(best[l]);
  }

  // 8. X: pack each layer, then pull nodes toward their neighbours'
  //    centres (down then up passes), resolving overlaps in order.
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
  void settle(List<String> l, Map<String, double> want) {
    if (l.isEmpty) return;
    double minDist(int i) => g[l[i - 1]]!.w / 2 + gapBetween(g[l[i - 1]]!, g[l[i]]!) + g[l[i]]!.w / 2;
    final ltr = List<double>.filled(l.length, 0);
    final rtl = List<double>.filled(l.length, 0);
    for (var i = 0; i < l.length; i++) {
      ltr[i] = i == 0 ? want[l[i]]! : math.max(want[l[i]]!, ltr[i - 1] + minDist(i));
    }
    for (var i = l.length - 1; i >= 0; i--) {
      rtl[i] = i == l.length - 1 ? want[l[i]]! : math.min(want[l[i]]!, rtl[i + 1] - minDist(i + 1));
    }
    for (var i = 0; i < l.length; i++) {
      var v = (ltr[i] + rtl[i]) / 2;
      if (i > 0) v = math.max(v, cx[l[i - 1]]! + minDist(i));
      cx[l[i]] = v;
    }
  }

  for (var pass = 0; pass < 4; pass++) {
    final downward = pass.isEven;
    final range = downward ? [for (var l = 1; l < nLayers; l++) l] : [for (var l = nLayers - 2; l >= 0; l--) l];
    for (final l in range) {
      final want = <String, double>{};
      for (final id in layers[l]) {
        final nb = downward ? up[id]! : down[id]!;
        want[id] = nb.isEmpty ? cx[id]! : nb.map((x) => cx[x]!).reduce((a, b) => a + b) / nb.length;
      }
      settle(layers[l], want);
    }
  }

  // 9. Coordinates.
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

  // 10. Edge polylines.
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
  return WfGraph(g.values.toList(), edges, maxX, height, repOf);
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
