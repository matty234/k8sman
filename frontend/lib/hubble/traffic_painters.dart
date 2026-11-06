/// Geometry and painting for the traffic map: the radial map (the cluster
/// as a disc, a lane per namespace, chords inside, the world outside) and
/// the matrix. Layouts are built once per data refresh and size; painting
/// and hit-testing only read them.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../ui/theme.dart';
import '../util/k8s.dart';
import 'traffic_model.dart';

/// The map's colours, from the theme.
class MapPalette {
  final Color ink;
  final Color hint;
  final Color faint;
  final Color separator;
  final Color background;

  /// Traffic leaving the cluster; also the selection.
  final Color egress;

  /// Traffic arriving from the world (directly or through Ingress).
  final Color ingress;
  final Color drop;
  final bool dark;

  const MapPalette({
    required this.ink,
    required this.hint,
    required this.faint,
    required this.separator,
    required this.background,
    required this.egress,
    required this.ingress,
    required this.drop,
    required this.dark,
  });

  factory MapPalette.of(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final dark = theme.brightness == Brightness.dark;
    return MapPalette(
      ink: theme.colorScheme.onSurface,
      hint: theme.hintColor,
      faint: colors.faint,
      separator: colors.separator,
      background: theme.scaffoldBackgroundColor,
      egress: theme.colorScheme.primary,
      ingress: dark ? const Color(0xFFB794F6) : const Color(0xFF8344CC),
      drop: severityColor(context, Severity.error),
      dark: dark,
    );
  }

  /// The colour of an edge: [base], or red when most of it was dropped
  /// (a smaller share shows as a red core, see RadialPainter).
  Color edgeColor(MapEdge e, Color base) => e.dropShare >= 0.5 ? drop : base;
}

/// What the pointer is over: a lane (node) or an edge.
class MapHit {
  final String? node;
  final MapEdge? edge;
  const MapHit.node(String this.node) : edge = null;
  const MapHit.edge(MapEdge this.edge) : node = null;

  bool sameAs(MapHit? o) => o != null && o.node == node && o.edge?.from == edge?.from && o.edge?.to == edge?.to;
}

/// Which edges stand out: the selection, else what is hovered.
class MapFocus {
  final String? node;
  final (String, String)? edge;
  final Set<String> matches;
  const MapFocus({this.node, this.edge, this.matches = const {}});

  bool get any => node != null || edge != null;
  bool edgeOn(MapEdge e) => (node != null && (e.from == node || e.to == node)) || (edge != null && e.from == edge!.$1 && e.to == edge!.$2);
  bool nodeOn(String id, MapGraph g) {
    if (node == id) return true;
    if (node != null) return g.edge(node!, id) != null || g.edge(id, node!) != null;
    if (edge != null) return edge!.$1 == id || edge!.$2 == id;
    return false;
  }
}

class MapLane {
  final String id;
  final double theta;
  final Offset inner;
  final Offset outer;
  final double dot;
  final TextPainter label;

  /// Where the label ends, as a radius: the lane's rule runs on from there.
  final double labelEnd;
  MapLane(this.id, this.theta, this.inner, this.outer, this.dot, this.label, this.labelEnd);
}

class EdgeGeom {
  final MapEdge edge;
  final List<Offset> pts;
  final double width;
  final bool ray;
  late final double length = () {
    var l = 0.0;
    for (var i = 1; i < pts.length; i++) {
      l += (pts[i] - pts[i - 1]).distance;
    }
    return l;
  }();
  EdgeGeom(this.edge, this.pts, this.width, {this.ray = false});

  Offset at(double t) {
    final target = t * length;
    var acc = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final seg = (pts[i] - pts[i - 1]).distance;
      if (acc + seg >= target) return Offset.lerp(pts[i - 1], pts[i], seg == 0 ? 0 : (target - acc) / seg)!;
      acc += seg;
    }
    return pts.last;
  }

  double distanceTo(Offset p) {
    var best = double.infinity;
    for (var i = 1; i < pts.length; i++) {
      best = math.min(best, _segDist(p, pts[i - 1], pts[i]));
    }
    return best;
  }
}

double _segDist(Offset p, Offset a, Offset b) {
  final ab = b - a;
  final len2 = ab.dx * ab.dx + ab.dy * ab.dy;
  if (len2 == 0) return (p - a).distance;
  final t = (((p - a).dx * ab.dx + (p - a).dy * ab.dy) / len2).clamp(0.0, 1.0);
  return (p - (a + ab * t)).distance;
}

Offset _unit(double theta) => Offset(math.cos(theta), math.sin(theta));

/// The radial map's geometry for one graph and size.
class RadialLayout {
  final MapGraph graph;
  final List<String> order;
  final Size size;
  late final Offset c;

  /// Chord circle, cluster boundary, longest world ray.
  late final double rc, rb, rayMax;
  final Map<String, MapLane> lanes = {};
  final List<EdgeGeom> chords = [];
  final List<EdgeGeom> rays = [];

  /// Per lane, the world peers its rays lead to (lane id, text, where).
  final List<(String, TextPainter, Offset)> worldLabels = [];

  /// World → Ingress, drawn from what Ingress passed on (Hubble sees the
  /// proxy's connections to pods, not the clients').
  MapEdge? gateEdge;

  /// The most lanes that fit the circle (and stay readable: past 40 the
  /// chords become a mass; the search and focus are for the rest).
  static int capacity(Size size) {
    final rc = _radii(size).$1;
    return (2 * math.pi * rc / 18).floor().clamp(8, 40);
  }

  static (double, double, bool) _radii(Size size) {
    final rayLabels = size.width >= 720;
    const rayMax = 58.0;
    final sideRoom = (rayLabels ? 132.0 : 10.0) + rayMax + 6;
    final rb = math.max(60.0, math.min((size.width - 2 * sideRoom) / 2, (size.height - 2 * (rayMax + 22)) / 2));
    final band = (rb * 0.4).clamp(64.0, 112.0);
    return (math.max(30.0, rb - band), rb, rayLabels);
  }

  RadialLayout(this.graph, this.order, this.size, MapPalette p, {required TextStyle labelStyle, required TextStyle monoStyle}) {
    c = size.center(Offset.zero);
    final (_, rb0, rayLabels) = _radii(size);
    rb = rb0;
    rayMax = 58;
    // The labels' band is as wide as the longest name needs, up to half
    // the radius (longer names are cut short).
    final painters = <String, TextPainter>{};
    var longest = 0.0;
    for (final id in order) {
      final node = graph.nodes[id]!;
      final reserved = !node.isNamespace;
      final style = labelStyle.copyWith(
        color: id == ingressId ? p.ingress : (reserved ? p.hint : p.ink),
        fontStyle: reserved && id != ingressId ? FontStyle.italic : null,
      );
      final tp = painters[id] = TextPainter(text: TextSpan(text: node.label, style: style), maxLines: 1, ellipsis: '…', textDirection: TextDirection.ltr)..layout();
      longest = math.max(longest, tp.width);
    }
    final band = (longest + 26).clamp(56.0, math.max(56.0, rb * 0.5));
    rc = math.max(30.0, rb - band);
    final n = order.length;
    if (n == 0) return;
    final step = 2 * math.pi / n;
    var maxTotal = 1;
    for (final id in order) {
      maxTotal = math.max(maxTotal, graph.nodes[id]?.total ?? 0);
    }
    for (var i = 0; i < n; i++) {
      final id = order[i];
      final node = graph.nodes[id]!;
      final theta = -math.pi / 2 + i * step;
      final u = _unit(theta);
      final dot = 2.5 + 4.0 * math.sqrt(node.total / maxTotal);
      final tp = painters[id]!..layout(maxWidth: rb - rc - 18);
      lanes[id] = MapLane(id, theta, c + u * rc, c + u * rb, dot, tp, rc + 10 + tp.width);
    }

    // Edges between lanes are chords; to and from the world, rays.
    final maxEdge = math.max(1, graph.maxEdge);
    double width(int v) => 0.8 + 6.5 * math.sqrt(v / maxEdge);
    final rayEdges = <MapEdge>[];
    for (final e in graph.edges) {
      if (e.touchesWorld) {
        rayEdges.add(e);
        continue;
      }
      final a = lanes[e.from], b = lanes[e.to];
      if (a == null || b == null) continue;
      final both = graph.edge(e.to, e.from) != null;
      chords.add(EdgeGeom(e, _chord(a, b, both, width(e.total)), width(e.total)));
    }
    var gate = 0;
    for (final e in graph.edges) {
      if (e.from == ingressId) gate += e.total;
    }
    if (gate > 0 && lanes.containsKey(ingressId)) {
      gateEdge = MapEdge(worldId, ingressId)..flows = gate;
      for (final e in graph.edges.where((e) => e.from == ingressId)) {
        gateEdge!.rate += e.rate;
        for (final x in e.ports.entries) {
          gateEdge!.ports[x.key] = (gateEdge!.ports[x.key] ?? 0) + x.value;
        }
      }
      rayEdges.add(gateEdge!);
    }
    // Rays scale among themselves (the Ingress gate carries the most, so
    // it is capped at the widest of the rest rather than setting the
    // scale).
    var maxRay = 1;
    for (final e in rayEdges) {
      if (e != gateEdge) maxRay = math.max(maxRay, e.total);
    }
    double share(MapEdge e) => math.min(1, e.total / maxRay);
    final byLane = <String, List<MapEdge>>{};
    for (final e in rayEdges) {
      (byLane[e.toWorld ? e.from : e.to] ??= []).add(e);
    }
    // Lanes with the most world traffic get their peers written out.
    final labelledLanes = (byLane.keys.toList()..sort((a, b) => byLane[b]!.fold(0, (s, e) => s + e.total).compareTo(byLane[a]!.fold(0, (s, e) => s + e.total)))).take(12).toSet();
    for (final entry in byLane.entries) {
      final lane = lanes[entry.key];
      if (lane == null) continue;
      final u = _unit(lane.theta);
      final both = entry.value.length > 1;
      var reach = 0.0;
      for (final e in entry.value) {
        final out = e.toWorld;
        final w = 1.4 + 5.0 * math.sqrt(share(e));
        final perp = Offset(-u.dy, u.dx) * (both ? (out ? 1 : -1) * (w / 2 + 2.5) : 0);
        final len = 22 + (rayMax - 22) * math.sqrt(share(e));
        reach = math.max(reach, len);
        final near = lane.outer + perp, far = lane.outer + u * len + perp;
        rays.add(EdgeGeom(e, out ? [near, far] : [far, near], w, ray: true));
      }
      if (!rayLabels || !labelledLanes.contains(lane.id)) continue;
      // One label per lane: where it sends (blue), then what reaches it
      // (violet), a line each.
      final lines = <TextPainter>[];
      for (final e in [...entry.value]..sort((a, b) => a.toWorld == b.toWorld ? 0 : (a.toWorld ? -1 : 1))) {
        final m = e.peers.keys.any((k) => k.isNotEmpty) ? e.peers : e.ports;
        final top = MapEdge.top(m, 1);
        if (top.isEmpty || top.first.name.isEmpty) continue;
        final more = m.keys.where((k) => k.isNotEmpty).length - 1;
        lines.add(TextPainter(
          text: TextSpan(style: monoStyle, children: [
            TextSpan(text: top.first.name, style: TextStyle(color: (e.toWorld ? p.egress : p.ingress).withValues(alpha: 0.9))),
            if (more > 0) TextSpan(text: ' +$more', style: TextStyle(color: p.faint)),
          ]),
          maxLines: 1,
          ellipsis: '…',
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 136));
      }
      if (lines.isEmpty) continue;
      final w = lines.fold(0.0, (m, tp) => math.max(m, tp.width));
      final h = lines.fold(0.0, (m, tp) => m + tp.height);
      final end = lane.outer + u * (reach + 7);
      final dx = u.dx >= 0.2 ? 0.0 : (u.dx <= -0.2 ? -w : -w / 2);
      final dy = u.dy >= 0.35 ? 0.0 : (u.dy <= -0.35 ? -h : -h / 2);
      final align = u.dx <= -0.2 ? 1.0 : (u.dx >= 0.2 ? 0.0 : 0.5);
      var y = 0.0;
      for (final tp in lines) {
        worldLabels.add((lane.id, tp, end + Offset(dx + (w - tp.width) * align, dy + y)));
        y += tp.height;
      }
    }
  }

  /// A chord between the inner ends of two lanes, bowed towards the centre
  /// (more for lanes far apart); the two directions of a pair are drawn
  /// side by side.
  List<Offset> _chord(MapLane a, MapLane b, bool both, double w) {
    var d = (a.theta - b.theta).abs() % (2 * math.pi);
    if (d > math.pi) d = 2 * math.pi - d;
    final p0 = a.inner, p2 = b.inner;
    final mid = (p0 + p2) / 2;
    final pull = 0.12 + 0.55 * (d / math.pi);
    var ctrl = Offset.lerp(mid, c, pull)!;
    if (both) {
      final dir = p2 - p0;
      final len = dir.distance;
      if (len > 0) ctrl += Offset(-dir.dy, dir.dx) / len * (w / 2 + 2.5);
    }
    // Stop short of the target dot, for the arrowhead.
    final pts = <Offset>[];
    const steps = 24;
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      final mt = 1 - t;
      pts.add(p0 * (mt * mt) + ctrl * (2 * mt * t) + p2 * (t * t));
    }
    return pts;
  }

  /// A point on the edge from [from] to [to] (for tests and the hover
  /// card), or null when it isn't drawn.
  Offset? pointOn(String from, String to) {
    for (final g in [...rays, ...chords]) {
      if (g.edge.from == from && g.edge.to == to) return g.at(0.5);
    }
    return null;
  }

  Offset? laneAt(String id) {
    final l = lanes[id];
    return l == null ? null : c + _unit(l.theta) * ((rc + l.labelEnd) / 2);
  }

  MapHit? hitTest(Offset p) {
    final d = p - c;
    final r = d.distance;
    // Rays first: they start where lanes end.
    EdgeGeom? best;
    var bestD = double.infinity;
    for (final g in rays) {
      final dist = g.distanceTo(p);
      if (dist < math.max(6, g.width / 2 + 4) && dist < bestD) {
        best = g;
        bestD = dist;
      }
    }
    if (best != null) return MapHit.edge(best.edge);
    if (r >= rc - 8 && r <= rb + 4 && lanes.isNotEmpty) {
      final theta = math.atan2(d.dy, d.dx);
      final step = 2 * math.pi / order.length;
      var i = ((theta + math.pi / 2) / step).round() % order.length;
      if (i < 0) i += order.length;
      final lane = lanes[order[i]];
      if (lane != null) return MapHit.node(lane.id);
    }
    for (final g in chords) {
      final dist = g.distanceTo(p);
      if (dist < math.max(5, g.width / 2 + 3) && dist < bestD) {
        best = g;
        bestD = dist;
      }
    }
    return best == null ? null : MapHit.edge(best.edge);
  }
}

/// Paints a [RadialLayout]. With a [clock] (seconds, while "Live" is on),
/// dots move along the edges that carried traffic lately.
class RadialPainter extends CustomPainter {
  final RadialLayout layout;
  final MapPalette p;
  final MapFocus focus;
  final MapHit? hover;
  final ValueListenable<double>? clock;
  RadialPainter({required this.layout, required this.p, required this.focus, this.hover, this.clock}) : super(repaint: clock);

  @override
  void paint(Canvas canvas, Size size) {
    final l = layout;
    if (l.order.isEmpty) return;
    final g = l.graph;
    final hoverNode = hover?.node;
    final hoverEdge = hover?.edge;
    // What stands out: the selection, else what the pointer is over.
    final f = focus.any ? focus : MapFocus(node: hoverNode, edge: hoverEdge == null ? null : (hoverEdge.from, hoverEdge.to), matches: focus.matches);

    // The cluster: a faint disc inside its boundary.
    canvas.drawCircle(l.c, l.rb, Paint()..color = p.ink.withValues(alpha: p.dark ? 0.035 : 0.022));
    canvas.drawCircle(
      l.c,
      l.rb,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..color = p.ink.withValues(alpha: p.dark ? 0.22 : 0.16),
    );

    // Lane rules, from the end of the label out to the boundary.
    final rule = Paint()
      ..strokeWidth = 1
      ..color = p.separator;
    for (final lane in l.lanes.values) {
      final u = _unit(lane.theta);
      if (lane.labelEnd + 6 < l.rb) canvas.drawLine(l.c + u * (lane.labelEnd + 6), lane.outer, rule);
    }

    // Quiet edges first, then the ones in focus on top.
    final all = [...l.chords, ...l.rays];
    final on = <EdgeGeom>[];
    for (final e in all) {
      if (f.any && f.edgeOn(e.edge)) {
        on.add(e);
      } else {
        _edge(canvas, e, f.any ? 0.10 : 1);
      }
    }
    for (final e in on) {
      _edge(canvas, e, 1, strong: true);
    }

    // Live: dots along what carried traffic in the last half minute.
    final t = clock?.value;
    if (t != null) {
      for (final e in all) {
        if (e.edge.rate <= 0 || (f.any && !f.edgeOn(e.edge))) continue;
        final n = (1 + math.log(e.edge.rate + 1) / math.ln10 * 1.6).clamp(1, 6).round();
        final speed = 70 / math.max(40, e.length); // ~70 px/s
        final paint = Paint()..color = _base(e.edge).withValues(alpha: 0.95);
        for (var i = 0; i < n; i++) {
          canvas.drawCircle(e.at((t * speed + i / n) % 1.0), 1.4 + e.width * 0.22, paint);
        }
      }
    }

    // Lanes: a dot where chords meet, the name along the lane, a tick on
    // the boundary.
    for (final lane in l.lanes.values) {
      final node = g.nodes[lane.id]!;
      final lit = !f.any || f.nodeOn(lane.id, g) || focus.matches.contains(lane.id);
      final selected = focus.node == lane.id || (focus.edge != null && (focus.edge!.$1 == lane.id || focus.edge!.$2 == lane.id));
      final alpha = lit ? 1.0 : 0.3;
      final dotPaint = Paint()..color = (selected ? p.egress : (lane.id == ingressId ? p.ingress : p.ink)).withValues(alpha: alpha * (node.isNamespace || lane.id == ingressId ? 0.85 : 0.5));
      if (node.isNamespace || lane.id == ingressId) {
        canvas.drawCircle(lane.inner, lane.dot, dotPaint);
      } else {
        canvas.drawRect(Rect.fromCircle(center: lane.inner, radius: lane.dot * 0.85), dotPaint);
      }
      if (node.drops > 0) {
        canvas.drawCircle(
          lane.inner,
          lane.dot + 2,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = p.drop.withValues(alpha: alpha),
        );
      }
      final u = _unit(lane.theta);
      canvas.drawLine(lane.outer - u * 3, lane.outer + u * 3, Paint()
        ..strokeWidth = lane.id == ingressId ? 3 : 1.5
        ..color = (lane.id == ingressId ? p.ingress : p.ink).withValues(alpha: alpha * 0.5));
      _label(canvas, lane, l, alpha, selected || focus.matches.contains(lane.id));
    }

    for (final (id, tp, at) in l.worldLabels) {
      if (f.any && !(f.node == id || f.edge?.$1 == id || f.edge?.$2 == id)) continue;
      tp.paint(canvas, at);
    }
  }

  Color _base(MapEdge e) {
    if (e.toWorld) return p.edgeColor(e, p.egress);
    if (e.fromWorld || e.from == ingressId) return p.edgeColor(e, p.ingress);
    return p.edgeColor(e, p.ink);
  }

  void _edge(Canvas canvas, EdgeGeom e, double fade, {bool strong = false}) {
    final edge = e.edge;
    final maxEdge = math.max(1, layout.graph.maxEdge);
    final weight = math.sqrt(edge.total / maxEdge);
    var alpha = e.ray || edge.from == ingressId ? 0.6 + 0.35 * weight : 0.14 + 0.44 * weight;
    if (edge.drops > 0) alpha = math.max(alpha, 0.7);
    if (edge.rate <= 0) alpha *= 0.55; // quiet lately
    if (strong) alpha = 0.95;
    final color = _base(edge).withValues(alpha: alpha * fade);
    final w = e.width + (strong ? 0.8 : 0);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..color = color;
    // The line stops where the arrowhead (at the target) begins.
    final head = 4 + w * 0.9;
    final last = e.pts.last;
    var k = e.pts.length - 2;
    while (k > 0 && (e.pts[k] - last).distance < 2) {
      k--;
    }
    final dir = last - e.pts[k];
    final len = dir.distance;
    if (len == 0) return;
    final u = dir / len;
    final targetDot = e.ray ? 0.0 : (layout.lanes[edge.to]?.dot ?? 0) + 1.5;
    final tip = last - u * targetDot;
    final back = tip - u * head;
    final path = Path()..moveTo(e.pts.first.dx, e.pts.first.dy);
    for (var i = 1; i < e.pts.length - 1; i++) {
      if ((e.pts[i] - last).distance <= head + targetDot) break;
      path.lineTo(e.pts[i].dx, e.pts[i].dy);
    }
    final stop = back + u * 0.5;
    path.lineTo(stop.dx, stop.dy);
    canvas.drawPath(path, paint);
    if (edge.drops > 0 && edge.dropShare < 0.5) {
      // Partly dropped: a red core as wide as the dropped share.
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round
          ..strokeWidth = math.max(1.3, w * edge.dropShare)
          ..color = p.drop.withValues(alpha: (strong ? 1.0 : 0.9) * fade),
      );
    }
    final side = Offset(-u.dy, u.dx) * (head * 0.55);
    canvas.drawPath(
      Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(back.dx + side.dx, back.dy + side.dy)
        ..lineTo(back.dx - side.dx, back.dy - side.dy)
        ..close(),
      Paint()..color = color,
    );
  }

  void _label(Canvas canvas, MapLane lane, RadialLayout l, double alpha, bool strong) {
    final tp = lane.label;
    canvas.save();
    canvas.translate(l.c.dx, l.c.dy);
    final right = math.cos(lane.theta) >= -1e-6;
    if (right) {
      canvas.rotate(lane.theta);
      canvas.translate(l.rc + 10, -tp.height / 2);
    } else {
      // Upright on the left: turned half round, ending at the same radius.
      canvas.rotate(lane.theta + math.pi);
      canvas.translate(-(l.rc + 10) - tp.width, -tp.height / 2);
    }
    if (alpha < 1 || strong) {
      canvas.saveLayer(Rect.fromLTWH(-2, -2, tp.width + 4, tp.height + 4), Paint()..color = Colors.black.withValues(alpha: alpha));
      if (strong) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(Rect.fromLTWH(-4, -1, tp.width + 8, tp.height + 2), const Radius.circular(4)),
          Paint()..color = p.egress.withValues(alpha: 0.14),
        );
      }
      tp.paint(canvas, Offset.zero);
      canvas.restore();
    } else {
      tp.paint(canvas, Offset.zero);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(RadialPainter old) => old.layout != layout || old.p != p || !_sameFocus(old.focus, focus) || !(old.hover?.sameAs(hover) ?? hover == null) || old.clock != clock;
}

bool _sameFocus(MapFocus a, MapFocus b) => a.node == b.node && a.edge == b.edge && a.matches.length == b.matches.length && a.matches.containsAll(b.matches);

/// The matrix's geometry: sources down, destinations across, the world
/// first in both.
class MatrixLayout {
  final MapGraph graph;
  final List<String> ids;
  final Size size;
  late final double rowHeader, colHeader, cell;
  late final Offset origin;
  final List<TextPainter> rowLabels = [];
  final List<TextPainter> colLabels = [];
  late final TextPainter caption;
  late final int maxCell;

  MatrixLayout(this.graph, List<String> order, this.size, MapPalette p, {required TextStyle labelStyle})
      : ids = [if (graph.nodes.containsKey(worldId)) worldId, ...order] {
    TextPainter label(String id, double maxWidth) => TextPainter(
          text: TextSpan(
            text: graph.nodes[id]?.label ?? nodeLabel(id),
            style: labelStyle.copyWith(
              color: id == worldId || id == ingressId ? p.ingress : (isReserved(id) ? p.hint : p.ink),
              fontStyle: isReserved(id) && id != worldId && id != ingressId ? FontStyle.italic : null,
            ),
          ),
          maxLines: 1,
          ellipsis: '…',
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: maxWidth);
    var widest = 0.0;
    for (final id in ids) {
      final tp = label(id, 150);
      rowLabels.add(tp);
      colLabels.add(label(id, 120));
      widest = math.max(widest, tp.width);
    }
    rowHeader = widest + 14;
    caption = TextPainter(
      text: TextSpan(text: 'from ↓   to →', style: labelStyle.copyWith(color: p.faint, fontSize: 10.5)),
      textDirection: TextDirection.ltr,
    )..layout();
    var tallest = 0.0;
    for (final tp in colLabels) {
      tallest = math.max(tallest, tp.width);
    }
    colHeader = tallest * math.sin(math.pi / 4) + 22;
    final n = math.max(1, ids.length);
    cell = math.min((size.width - rowHeader - 24) / n, (size.height - colHeader - 16) / n).clamp(8.0, 30.0);
    final w = rowHeader + n * cell, h = colHeader + n * cell;
    origin = Offset(math.max(8, (size.width - w) / 2) + rowHeader, math.max(8, (size.height - h) / 2) + colHeader);
    var m = 1;
    for (final e in graph.edges) {
      m = math.max(m, e.total);
    }
    for (final node in graph.nodes.values) {
      m = math.max(m, node.internal);
    }
    maxCell = m;
  }

  Rect cellRect(int row, int col) => Rect.fromLTWH(origin.dx + col * cell, origin.dy + row * cell, cell, cell);

  Offset? pointOn(String from, String to) {
    final r = ids.indexOf(from), c = ids.indexOf(to);
    return r < 0 || c < 0 ? null : cellRect(r, c).center;
  }

  /// (row, column) under [p]; -1 for a header.
  (int, int)? cellAt(Offset p) {
    final n = ids.length;
    final col = ((p.dx - origin.dx) / cell).floor();
    final row = ((p.dy - origin.dy) / cell).floor();
    final inCols = col >= 0 && col < n, inRows = row >= 0 && row < n;
    if (inRows && inCols) return (row, col);
    if (inRows && p.dx < origin.dx && p.dx > origin.dx - rowHeader) return (row, -1);
    if (inCols && p.dy < origin.dy && p.dy > origin.dy - colHeader) return (-1, col);
    return null;
  }

  MapHit? hitTest(Offset p) {
    final rc = cellAt(p);
    if (rc == null) return null;
    final (r, c) = rc;
    if (r < 0) return MapHit.node(ids[c]);
    if (c < 0) return MapHit.node(ids[r]);
    if (r == c) return MapHit.node(ids[r]);
    final e = graph.edge(ids[r], ids[c]);
    return e == null ? null : MapHit.edge(e);
  }
}

class MatrixPainter extends CustomPainter {
  final MatrixLayout layout;
  final MapPalette p;
  final MapFocus focus;
  final MapHit? hover;
  MatrixPainter({required this.layout, required this.p, required this.focus, this.hover});

  @override
  void paint(Canvas canvas, Size size) {
    final l = layout;
    final n = l.ids.length;
    if (n == 0) return;
    final g = l.graph;
    final grid = Rect.fromLTWH(l.origin.dx, l.origin.dy, n * l.cell, n * l.cell);
    final wi = l.ids.indexOf(worldId);

    // The world's row (arriving) and column (leaving), tinted.
    if (wi >= 0) {
      canvas.drawRect(l.cellRect(wi, 0).expandToInclude(l.cellRect(wi, n - 1)), Paint()..color = p.ingress.withValues(alpha: 0.06));
      canvas.drawRect(l.cellRect(0, wi).expandToInclude(l.cellRect(n - 1, wi)), Paint()..color = p.egress.withValues(alpha: 0.06));
    }
    // Hovered or selected row and column.
    int? hr, hc;
    final h = hover;
    if (h?.edge != null) {
      hr = l.ids.indexOf(h!.edge!.from);
      hc = l.ids.indexOf(h.edge!.to);
    } else if (h?.node != null) {
      hr = hc = l.ids.indexOf(h!.node!);
    }
    final band = Paint()..color = p.ink.withValues(alpha: 0.045);
    if (hr != null && hr >= 0) canvas.drawRect(l.cellRect(hr, 0).expandToInclude(l.cellRect(hr, n - 1)), band);
    if (hc != null && hc >= 0) canvas.drawRect(l.cellRect(0, hc).expandToInclude(l.cellRect(n - 1, hc)), band);

    final gridPaint = Paint()
      ..color = p.separator
      ..strokeWidth = 1;
    for (var i = 0; i <= n; i++) {
      final x = l.origin.dx + i * l.cell, y = l.origin.dy + i * l.cell;
      canvas.drawLine(Offset(x, grid.top), Offset(x, grid.bottom), gridPaint);
      canvas.drawLine(Offset(grid.left, y), Offset(grid.right, y), gridPaint);
    }

    void cellFill(int r, int c, int v, int drops, Color base, {bool dim = false}) {
      if (v <= 0) return;
      final rect = l.cellRect(r, c).deflate(1);
      // Log scale: the matrix is for spotting who talks at all, and
      // roughly how much (one busy pair would wash out the rest).
      final a = (0.16 + 0.8 * math.log(1 + v) / math.log(1 + l.maxCell)) * (dim ? 0.25 : 1);
      canvas.drawRect(rect, Paint()..color = base.withValues(alpha: a));
      if (drops > 0) {
        // A red corner, larger with the share of drops.
        final s = rect.width * (0.35 + 0.65 * (drops / v)).clamp(0.35, 1.0);
        canvas.drawPath(
          Path()
            ..moveTo(rect.right - s, rect.top)
            ..lineTo(rect.right, rect.top)
            ..lineTo(rect.right, rect.top + s)
            ..close(),
          Paint()..color = p.drop.withValues(alpha: dim ? 0.3 : 0.95),
        );
      }
    }

    for (final e in g.edges) {
      final r = l.ids.indexOf(e.from), c = l.ids.indexOf(e.to);
      if (r < 0 || c < 0) continue;
      final base = e.toWorld ? p.egress : (e.fromWorld || e.from == ingressId ? p.ingress : p.ink);
      cellFill(r, c, e.total, e.drops, base, dim: focus.any && !focus.edgeOn(e));
    }
    for (var i = 0; i < n; i++) {
      final node = g.nodes[l.ids[i]];
      if (node == null || node.internal == 0) continue;
      cellFill(i, i, node.internal, 0, p.ink, dim: focus.any && focus.node != node.id);
    }
    // The diagonal: traffic within a namespace.
    canvas.drawLine(grid.topLeft, grid.bottomRight, Paint()
      ..color = p.ink.withValues(alpha: 0.08)
      ..strokeWidth = 1);

    if (h?.edge != null && hr! >= 0 && hc! >= 0) {
      canvas.drawRect(l.cellRect(hr, hc), Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = p.egress);
    }
    final sel = focus.edge;
    if (sel != null) {
      final r = l.ids.indexOf(sel.$1), c = l.ids.indexOf(sel.$2);
      if (r >= 0 && c >= 0) {
        canvas.drawRect(l.cellRect(r, c).inflate(1), Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = p.egress);
      }
    }

    l.caption.paint(canvas, Offset(l.origin.dx - 8 - l.caption.width, l.origin.dy - l.caption.height - 6));

    // Labels: sources on the left, destinations slanted on top.
    for (var i = 0; i < n; i++) {
      final id = l.ids[i];
      final on = !focus.any || focus.nodeOn(id, g) || i == hr || i == hc;
      final rowTp = l.rowLabels[i];
      final y = l.origin.dy + i * l.cell + (l.cell - rowTp.height) / 2;
      _paintFaded(canvas, rowTp, Offset(l.origin.dx - 8 - rowTp.width, y), on ? 1 : 0.35);
      final colTp = l.colLabels[i];
      canvas.save();
      canvas.translate(l.origin.dx + i * l.cell + l.cell / 2, l.origin.dy - 6);
      canvas.rotate(-math.pi / 4);
      _paintFaded(canvas, colTp, Offset(0, -colTp.height / 2), on ? 1 : 0.35);
      canvas.restore();
    }
  }

  void _paintFaded(Canvas canvas, TextPainter tp, Offset at, double alpha) {
    if (alpha >= 1) {
      tp.paint(canvas, at);
      return;
    }
    canvas.saveLayer(at & tp.size, Paint()..color = Colors.black.withValues(alpha: alpha));
    tp.paint(canvas, at);
    canvas.restore();
  }

  @override
  bool shouldRepaint(MatrixPainter old) => old.layout != layout || old.p != p || !_sameFocus(old.focus, focus) || !(old.hover?.sameAs(hover) ?? hover == null);
}
