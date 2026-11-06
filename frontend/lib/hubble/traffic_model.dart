/// The traffic map's data: GET /api/hubble/map (see API.md "Hubble") and
/// the graph the Map tab draws from it (visible nodes, merged edges, the
/// order of the namespaces around the circle). No widgets here.
library;

import 'dart:math' as math;

import '../api/models.dart';
import '../util/k8s.dart';

/// One entry of a top list; an empty [name] sums the rest.
class TrafficCount {
  final String name;
  final int n;
  const TrafficCount(this.name, this.n);

  static List<TrafficCount> list(dynamic l) => [for (final j in asMapList(l)) TrafficCount('${j['name'] ?? ''}', (j['n'] as num?)?.toInt() ?? 0)];
}

/// Traffic from one node to another over the window.
class TrafficEdge {
  final String from;
  final String to;
  final int flows;
  final int drops;

  /// Flows a second lately (0 once the pair went quiet).
  final double rate;
  final List<TrafficCount> ports;
  final List<TrafficCount> peers;
  final List<TrafficCount> fromWorkloads;
  final List<TrafficCount> toWorkloads;
  final List<TrafficCount> reasons;

  const TrafficEdge({
    required this.from,
    required this.to,
    this.flows = 0,
    this.drops = 0,
    this.rate = 0,
    this.ports = const [],
    this.peers = const [],
    this.fromWorkloads = const [],
    this.toWorkloads = const [],
    this.reasons = const [],
  });

  factory TrafficEdge.fromJson(Json j) => TrafficEdge(
        from: '${j['from'] ?? ''}',
        to: '${j['to'] ?? ''}',
        flows: (j['flows'] as num?)?.toInt() ?? 0,
        drops: (j['drops'] as num?)?.toInt() ?? 0,
        rate: (j['rate'] as num?)?.toDouble() ?? 0,
        ports: TrafficCount.list(j['ports']),
        peers: TrafficCount.list(j['peers']),
        fromWorkloads: TrafficCount.list(j['fromWorkloads']),
        toWorkloads: TrafficCount.list(j['toWorkloads']),
        reasons: TrafficCount.list(j['reasons']),
      );

  int get total => flows + drops;
}

/// GET /api/hubble/map.
class TrafficMap {
  final String window;
  final DateTime? since;
  final DateTime? now;
  final DateTime? startedAt;
  final int flows;
  final int drops;
  final double rate;
  final int lost;
  final int uncounted;

  /// starting | live | error.
  final String state;
  final String? error;
  final List<TrafficEdge> edges;

  const TrafficMap({
    this.window = '5m',
    this.since,
    this.now,
    this.startedAt,
    this.flows = 0,
    this.drops = 0,
    this.rate = 0,
    this.lost = 0,
    this.uncounted = 0,
    this.state = 'live',
    this.error,
    this.edges = const [],
  });

  factory TrafficMap.fromJson(Json j) => TrafficMap(
        window: '${j['window'] ?? ''}',
        since: DateTime.tryParse('${j['since'] ?? ''}'),
        now: DateTime.tryParse('${j['now'] ?? ''}'),
        startedAt: DateTime.tryParse('${j['startedAt'] ?? ''}'),
        flows: (j['flows'] as num?)?.toInt() ?? 0,
        drops: (j['drops'] as num?)?.toInt() ?? 0,
        rate: (j['rate'] as num?)?.toDouble() ?? 0,
        lost: (j['lost'] as num?)?.toInt() ?? 0,
        uncounted: (j['uncounted'] as num?)?.toInt() ?? 0,
        state: '${j['state'] ?? 'live'}',
        error: j['error'] as String?,
        edges: [for (final e in asMapList(j['edges'])) TrafficEdge.fromJson(e)],
      );

  /// How far back the counts go (shorter than the window while the map is
  /// younger than it).
  Duration get covered => since == null || now == null ? Duration.zero : now!.difference(since!);
}

// Node ids the backend uses for endpoints outside any namespace.
const worldId = 'reserved:world';
const ingressId = 'reserved:ingress';
const hostId = 'reserved:host';
const remoteNodeId = 'reserved:remote-node';
const apiServerId = 'reserved:kube-apiserver';

/// The UI's bucket for namespaces past the top N.
const otherNamespacesId = 'reserved:other-namespaces';

bool isReserved(String id) => id.startsWith('reserved:');

/// Reserved identities the toolbar can show or hide. The world and Cilium
/// Ingress are always shown: they are what the map is about.
enum ReservedGroup {
  nodes('Nodes', 'The host and other nodes (host networking, kubelet probes, node-local traffic)'),
  apiServer('API server', 'Traffic to and from the Kubernetes API server'),
  other('Other', 'Health checks, unmanaged and unknown endpoints');

  final String label;
  final String hint;
  const ReservedGroup(this.label, this.hint);
}

ReservedGroup? groupOf(String id) => switch (id) {
      hostId || remoteNodeId => ReservedGroup.nodes,
      apiServerId => ReservedGroup.apiServer,
      worldId || ingressId || otherNamespacesId => null,
      _ => isReserved(id) ? ReservedGroup.other : null,
    };

/// A display name for a node id.
String nodeLabel(String id) => switch (id) {
      worldId => 'World',
      ingressId => 'Ingress',
      hostId => 'Host',
      remoteNodeId => 'Other nodes',
      apiServerId => 'API server',
      otherNamespacesId => 'Other namespaces',
      _ when isReserved(id) => '${id.substring('reserved:'.length)[0].toUpperCase()}${id.substring('reserved:'.length + 1)}',
      _ => id,
    };

/// A node of the drawn graph: a namespace, Cilium Ingress, a reserved
/// identity, or the bucket of namespaces past the top N.
class MapNode {
  final String id;
  int out = 0;
  int inn = 0;
  int internal = 0;
  int drops = 0;
  int worldOut = 0;
  int worldIn = 0;
  double rate = 0;

  /// The namespaces in [otherNamespacesId].
  final List<String> members = [];
  MapNode(this.id);

  String get label => id == otherNamespacesId ? '${members.length} more namespace${members.length == 1 ? '' : 's'}' : nodeLabel(id);
  bool get isNamespace => !isReserved(id);
  int get total => out + inn + internal;
}

/// An edge of the drawn graph: [TrafficEdge]s merged when the namespaces
/// on one side were folded into [otherNamespacesId].
class MapEdge {
  final String from;
  final String to;
  int flows = 0;
  int drops = 0;
  double rate = 0;
  final Map<String, int> ports = {};
  final Map<String, int> peers = {};
  final Map<String, int> fromWorkloads = {};
  final Map<String, int> toWorkloads = {};
  final Map<String, int> reasons = {};
  MapEdge(this.from, this.to);

  int get total => flows + drops;
  double get dropShare => total == 0 ? 0 : drops / total;
  bool get toWorld => to == worldId;
  bool get fromWorld => from == worldId;
  bool get touchesWorld => toWorld || fromWorld;

  void add(TrafficEdge e) {
    flows += e.flows;
    drops += e.drops;
    rate += e.rate;
    void merge(Map<String, int> m, List<TrafficCount> l) {
      for (final c in l) {
        m[c.name] = (m[c.name] ?? 0) + c.n;
      }
    }

    merge(ports, e.ports);
    merge(peers, e.peers);
    merge(fromWorkloads, e.fromWorkloads);
    merge(toWorkloads, e.toWorkloads);
    merge(reasons, e.reasons);
  }

  /// [m] busiest first, with the unnamed rest last.
  static List<TrafficCount> top(Map<String, int> m, [int n = 5]) {
    final named = [for (final e in m.entries) if (e.key.isNotEmpty) TrafficCount(e.key, e.value)]..sort((a, b) => b.n != a.n ? b.n.compareTo(a.n) : a.name.compareTo(b.name));
    var rest = m[''] ?? 0;
    for (final c in named.skip(n)) {
      rest += c.n;
    }
    return [...named.take(n), if (rest > 0) TrafficCount('', rest)];
  }
}

/// What the Map tab draws: the visible nodes and edges after the reserved
/// toggles, the search and the top-N cut.
class MapGraph {
  final Map<String, MapNode> nodes;
  final List<MapEdge> edges;

  /// Volume on edges hidden by each [ReservedGroup] toggle.
  final Map<ReservedGroup, int> hidden;

  /// Namespaces matching the search (empty without one).
  final Set<String> matches;
  final int maxEdge;

  MapGraph._(this.nodes, this.edges, this.hidden, this.matches)
      : maxEdge = edges.fold(0, (m, e) => math.max(m, e.total));

  static final empty = MapGraph._({}, [], {}, {});

  MapEdge? edge(String from, String to) {
    for (final e in edges) {
      if (e.from == from && e.to == to) return e;
    }
    return null;
  }

  Iterable<MapEdge> edgesOf(String id) => edges.where((e) => e.from == id || e.to == id);

  /// Builds the graph from [m]. Reserved identities in groups not in
  /// [shown] are left out (their volume goes to [hidden]). A [query]
  /// keeps the namespaces whose name contains it and their neighbours.
  /// Past [maxNamespaces], the quietest namespaces are folded into one
  /// "more namespaces" node, except those in [keep] (e.g. the selection).
  static MapGraph build(TrafficMap m, {Set<ReservedGroup> shown = const {}, String query = '', int maxNamespaces = 30, Set<String> keep = const {}}) {
    final hidden = <ReservedGroup, int>{};
    var edges = <TrafficEdge>[];
    ReservedGroup? off(String id) {
      final g = groupOf(id);
      return g != null && !shown.contains(g) ? g : null;
    }

    for (final e in m.edges) {
      final g = off(e.from) ?? off(e.to);
      if (g != null) {
        hidden[g] = (hidden[g] ?? 0) + e.total;
      } else {
        edges.add(e);
      }
    }

    // The search: matching namespaces and whatever they talk to.
    final q = query.trim().toLowerCase();
    final matches = <String>{};
    if (q.isNotEmpty) {
      for (final e in edges) {
        for (final id in [e.from, e.to]) {
          if (!isReserved(id) && id.toLowerCase().contains(q)) matches.add(id);
        }
      }
      final keepIds = {...matches};
      for (final e in edges) {
        if (matches.contains(e.from)) keepIds.add(e.to);
        if (matches.contains(e.to)) keepIds.add(e.from);
      }
      edges = [for (final e in edges) if (keepIds.contains(e.from) && keepIds.contains(e.to) && (matches.contains(e.from) || matches.contains(e.to))) e];
    }

    // Top N namespaces by volume; the rest share one node.
    final volume = <String, int>{};
    for (final e in edges) {
      for (final id in {e.from, e.to}) {
        if (!isReserved(id)) volume[id] = (volume[id] ?? 0) + e.total;
      }
    }
    final ranked = volume.keys.toList()..sort((a, b) => volume[b] != volume[a] ? volume[b]!.compareTo(volume[a]!) : a.compareTo(b));
    final kept = <String>{...keep.where(volume.containsKey), ...matches};
    for (final id in ranked) {
      if (kept.length >= maxNamespaces) break;
      kept.add(id);
    }
    final folded = ranked.length > kept.length + 1 ? {for (final id in ranked) if (!kept.contains(id)) id} : const <String>{};
    String map(String id) => folded.contains(id) ? otherNamespacesId : id;

    final nodes = <String, MapNode>{};
    MapNode node(String id) => nodes[id] ??= MapNode(id);
    final merged = <(String, String), MapEdge>{};
    for (final e in edges) {
      final from = map(e.from), to = map(e.to);
      final a = node(from), b = node(to);
      if (folded.contains(e.from) && !a.members.contains(e.from)) a.members.add(e.from);
      if (folded.contains(e.to) && !b.members.contains(e.to)) b.members.add(e.to);
      a.drops += e.drops;
      if (from != to) b.drops += e.drops;
      a.rate += e.rate;
      if (from == to) {
        a.internal += e.total;
        continue;
      }
      a.out += e.total;
      b.inn += e.total;
      if (to == worldId) a.worldOut += e.total;
      if (from == worldId || from == ingressId) b.worldIn += e.total;
      (merged[(from, to)] ??= MapEdge(from, to)).add(e);
    }
    final list = merged.values.toList()..sort((a, b) => b.total.compareTo(a.total));
    return MapGraph._(nodes, list, hidden, matches);
  }

  /// The order of the lanes around the circle, clockwise from the top:
  /// Cilium Ingress first, then the namespaces as a chain where each is
  /// followed by the one it talks to most (so busy pairs sit close and
  /// their chords stay short), starting from the one the world reaches
  /// most; then the reserved identities and the "more namespaces" node.
  /// [previous] is kept while the same lanes are shown, so the picture
  /// doesn't reshuffle every refresh.
  List<String> order([List<String>? previous]) {
    final ids = nodes.keys.where((id) => id != worldId).toSet();
    if (previous != null && previous.length == ids.length && previous.every(ids.contains)) return previous;
    final ns = ids.where((id) => !isReserved(id)).toList()..sort();
    final w = <(String, String), int>{};
    for (final e in edges) {
      final k = e.from.compareTo(e.to) < 0 ? (e.from, e.to) : (e.to, e.from);
      w[k] = (w[k] ?? 0) + e.total;
    }
    int weight(String a, String b) => w[a.compareTo(b) < 0 ? (a, b) : (b, a)] ?? 0;
    final chain = <String>[];
    final left = {...ns};
    if (left.isNotEmpty) {
      var cur = left.reduce((a, b) {
        final na = nodes[a]!, nb = nodes[b]!;
        if (na.worldIn != nb.worldIn) return na.worldIn > nb.worldIn ? a : b;
        return na.total >= nb.total ? a : b;
      });
      while (true) {
        chain.add(cur);
        left.remove(cur);
        if (left.isEmpty) break;
        String? best;
        var bw = 0;
        for (final id in left) {
          final x = weight(cur, id);
          if (x > bw || (x == bw && best != null && x > 0 && nodes[id]!.total > nodes[best]!.total)) {
            best = id;
            bw = x;
          }
        }
        cur = best ?? left.reduce((a, b) => nodes[a]!.total >= nodes[b]!.total ? a : b);
      }
    }
    const known = [hostId, remoteNodeId, apiServerId];
    int rank(String id) => known.contains(id) ? known.indexOf(id) : known.length;
    final reserved = ids.where((id) => isReserved(id) && id != ingressId && id != otherNamespacesId).toList()
      ..sort((a, b) => rank(a) != rank(b) ? rank(a).compareTo(rank(b)) : a.compareTo(b));
    return [
      if (ids.contains(ingressId)) ingressId,
      ...chain,
      if (ids.contains(otherNamespacesId)) otherNamespacesId,
      ...reserved,
    ];
  }
}

/// 1234 → "1.2k", 45678 → "46k".
String fmtCount(num v) {
  if (v >= 1e6) return '${(v / 1e6).toStringAsFixed(v >= 1e7 ? 0 : 1)}M';
  if (v >= 1e4) return '${(v / 1e3).toStringAsFixed(0)}k';
  if (v >= 1e3) return '${(v / 1e3).toStringAsFixed(1)}k';
  return '${v.round()}';
}

/// Flows a second: "120/s", "3.4/s", "<0.1/s".
String fmtRate(double r) {
  if (r <= 0) return '0/s';
  if (r < 0.1) return '<0.1/s';
  if (r < 10) return '${r.toStringAsFixed(1)}/s';
  return '${fmtCount(r)}/s';
}
