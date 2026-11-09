import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../ui/widgets/editorial.dart';
import '../util/k8s.dart';
import 'flow_list.dart' show dropReasonLabel;
import 'hubble_api.dart';
import 'traffic_model.dart';
import 'traffic_painters.dart';
import '../api/error_info.dart' show errorText;

/// How often the map is fetched while it is on screen.
const mapRefresh = Duration(seconds: 2);

/// The windows the map offers (the backend keeps 15 minutes).
const mapWindows = ['1m', '5m', '15m'];

enum MapMode { radial, matrix }

/// The Hubble page's Map tab: which namespaces talk to each other, and
/// which receive from and send to the world, over the last 1, 5 or 15
/// minutes. The cluster is a disc with a lane per namespace: chords inside
/// join namespaces that talk, rays crossing the boundary are traffic to and
/// from the world (Cilium Ingress has its own lane at the top). The matrix
/// shows the same counts as a grid. The side panel lists the edges of the
/// cluster, or what is selected, with ways on: "Can A reach B?", the
/// namespace's flows, the namespace in the inspector.
///
/// Polls GET /api/hubble/map every [mapRefresh] while on screen (the
/// backend counts while it is asked, and stops a minute after); nothing
/// runs while the tab is hidden.
class TrafficMapView extends StatefulWidget {
  final HubbleApi api;

  /// Opens "Can A reach B?" with endpoint specs (`ns:web`, `fqdn:…`, an IP).
  final void Function(String from, String to) onCheck;

  /// Opens the Flows tab for a namespace.
  final ValueChanged<String> onShowFlows;
  const TrafficMapView({super.key, required this.api, required this.onCheck, required this.onShowFlows});

  @override
  State<TrafficMapView> createState() => _TrafficMapViewState();
}

class _TrafficMapViewState extends State<TrafficMapView> {
  TrafficMap? _data;
  String? _error;
  String _window = '5m';
  Timer? _timer;
  bool _fetching = false;
  int _gen = 0;

  MapMode _mode = MapMode.radial;
  final Set<ReservedGroup> _reserved = {};
  final _search = TextEditingController();
  String _query = '';
  bool _live = false;

  String? _selNode;
  (String, String)? _selEdge;

  MapGraph _graph = MapGraph.empty;
  List<String> _order = const [];
  int _capacity = 30;

  ValueListenable<TickerModeData>? _visible;
  bool get _onScreen => _visible?.value.enabled ?? true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final n = TickerMode.getValuesNotifier(context);
    if (n != _visible) {
      _visible?.removeListener(_onVisibility);
      _visible = n..addListener(_onVisibility);
      _onVisibility();
    }
  }

  void _onVisibility() {
    if (_onScreen && _timer == null && !_fetching) {
      _fetch();
    } else if (!_onScreen) {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void dispose() {
    _visible?.removeListener(_onVisibility);
    _timer?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _fetch() async {
    _timer?.cancel();
    _timer = null;
    if (_fetching) return;
    _fetching = true;
    final gen = _gen;
    try {
      final d = await widget.api.trafficMap(window: _window);
      if (mounted && gen == _gen) {
        setState(() {
          _data = d;
          _error = null;
          _rebuild();
        });
      }
    } catch (e) {
      if (mounted && gen == _gen) setState(() => _error = errorText(e));
    } finally {
      _fetching = false;
      if (mounted && _onScreen) {
        if (gen != _gen) {
          _fetch();
        } else {
          _timer = Timer(mapRefresh, _fetch);
        }
      }
    }
  }

  void _rebuild() {
    final d = _data;
    if (d == null) return;
    _graph = MapGraph.build(
      d,
      shown: _reserved,
      query: _query,
      maxNamespaces: _capacity,
      keep: {?_selNode, ?_selEdge?.$1, ?_selEdge?.$2},
    );
    _order = _graph.order(_order);
    if (_selNode != null && !_graph.nodes.containsKey(_selNode)) _selNode = null;
  }

  void _update(VoidCallback f) => setState(() {
        f();
        _rebuild();
      });

  void _setWindow(String w) {
    if (w == _window) return;
    setState(() {
      _window = w;
      _gen++;
    });
    if (!_fetching) _fetch();
  }

  /// Selects what was clicked (again: unselects). A namespace also opens
  /// in the inspector.
  void _select(MapHit? hit) {
    final ns = hit?.node;
    if (ns != null && ns != _selNode && !isReserved(ns)) context.read<AppState>().openRef(ObjectRef(kind: 'Namespace', name: ns));
    setState(() {
      if (hit == null) {
        _selNode = null;
        _selEdge = null;
      } else if (ns != null) {
        _selNode = _selNode == ns ? null : ns;
        _selEdge = null;
      } else {
        final k = (hit.edge!.from, hit.edge!.to);
        _selEdge = _selEdge == k ? null : k;
        _selNode = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final d = _data;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => _select(null)},
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _Toolbar(
          mode: _mode,
          onMode: (m) => _update(() => _mode = m),
          window: _window,
          onWindow: _setWindow,
          search: _search,
          onSearch: (q) => _update(() => _query = q),
          reserved: _reserved,
          hidden: _graph.hidden,
          onReserved: (g, on) => _update(() => on ? _reserved.add(g) : _reserved.remove(g)),
          live: _live,
          onLive: _mode == MapMode.radial ? (v) => setState(() => _live = v) : null,
          data: d,
        ),
        Container(height: 1, color: colors.separator),
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            final panel = (box.maxWidth * 0.27).clamp(250.0, 330.0);
            final canvas = Size(math.max(0, box.maxWidth - panel - 1), box.maxHeight);
            final cap = _mode == MapMode.radial
                ? RadialLayout.capacity(canvas) - _graph.nodes.keys.where((id) => isReserved(id) && id != otherNamespacesId && id != worldId).length - 1
                : ((math.min(canvas.width, canvas.height) - 160) / 13).floor();
            if (cap != _capacity) {
              _capacity = math.max(6, cap);
              _rebuild();
            }
            final Widget body;
            if (d == null) {
              body = _error != null
                  ? Align(alignment: Alignment.topLeft, child: Padding(padding: const EdgeInsets.all(12), child: InlineMessage(_error!, isError: true)))
                  : const Center(child: CircularProgressIndicator());
            } else if (_graph.nodes.isEmpty) {
              body = Align(
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: InlineMessage(
                    _query.isNotEmpty
                        ? 'No namespace matching "$_query" had traffic in this window.'
                        : d.state == 'starting'
                            ? 'Counting flows… the map fills in as Hubble sees traffic.'
                            : 'No traffic between namespaces or with the world in this window yet.',
                    icon: Icons.hourglass_empty,
                  ),
                ),
              );
            } else {
              body = _MapCanvas(
                key: const ValueKey('traffic-map-canvas'),
                graph: _graph,
                order: _order,
                mode: _mode,
                focus: MapFocus(node: _selNode, edge: _selEdge, matches: _graph.matches),
                live: _live && _mode == MapMode.radial,
                onTap: _select,
              );
            }
            return Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  if (_error != null && d != null) Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 0), child: InlineMessage(_error!, isError: true)),
                  if (d?.state == 'error' && d?.error != null) Padding(padding: const EdgeInsets.fromLTRB(10, 8, 10, 0), child: InlineMessage('Reconnecting to Hubble Relay: ${d!.error}', isError: true)),
                  Expanded(child: body),
                ]),
              ),
              Container(width: 1, color: colors.separator),
              SizedBox(
                width: panel,
                child: ColoredBox(
                  color: colors.inspector.withValues(alpha: theme.brightness == Brightness.dark ? 0.5 : 0.6),
                  child: _SidePanel(
                    graph: _graph,
                    data: d,
                    node: _selNode,
                    edge: _selEdge == null ? null : _graph.edge(_selEdge!.$1, _selEdge!.$2),
                    onSelect: _select,
                    onCheck: widget.onCheck,
                    onShowFlows: widget.onShowFlows,
                  ),
                ),
              ),
            ]);
          }),
        ),
      ]),
    );
  }
}

/// Endpoint spec for a world peer: an IP as is, a DNS name as fqdn:.
String peerSpec(String peer) => RegExp(r'^[0-9.]+$').hasMatch(peer) || peer.contains(':') ? peer : 'fqdn:$peer';

/// "Can A reach B?" for an edge: namespaces as ns:, the world by its top
/// peer. Null when one side can't be named (Ingress, reserved identities).
(String, String)? reachFor(MapEdge e) {
  String? side(String id, bool from) {
    if (id == worldId) {
      final top = MapEdge.top(e.peers, 1);
      return top.isEmpty || top.first.name.isEmpty ? null : peerSpec(top.first.name);
    }
    return isReserved(id) ? null : 'ns:$id';
  }

  final a = side(e.from, true), b = side(e.to, false);
  return a == null || b == null ? null : (a, b);
}

// ---------------------------------------------------------------------------
// Toolbar
// ---------------------------------------------------------------------------

class _Toolbar extends StatelessWidget {
  final MapMode mode;
  final ValueChanged<MapMode> onMode;
  final String window;
  final ValueChanged<String> onWindow;
  final TextEditingController search;
  final ValueChanged<String> onSearch;
  final Set<ReservedGroup> reserved;
  final Map<ReservedGroup, int> hidden;
  final void Function(ReservedGroup g, bool on) onReserved;
  final bool live;
  final ValueChanged<bool>? onLive;
  final TrafficMap? data;

  const _Toolbar({
    required this.mode,
    required this.onMode,
    required this.window,
    required this.onWindow,
    required this.search,
    required this.onSearch,
    required this.reserved,
    required this.hidden,
    required this.onReserved,
    required this.live,
    required this.onLive,
    required this.data,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final reduceMotion = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 10, 6),
      child: Row(children: [
        Expanded(
          flex: 3,
          child: Wrap(spacing: 8, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
            _Segments<MapMode>(
              keyPrefix: 'map-mode',
              value: mode,
              onChanged: onMode,
              items: const [(MapMode.radial, 'Map', Icons.radar), (MapMode.matrix, 'Matrix', Icons.grid_on)],
            ),
            _Segments<String>(
              keyPrefix: 'map-window',
              value: window,
              onChanged: onWindow,
              items: [for (final w in mapWindows) (w, w, null)],
              tooltip: 'Window: traffic counted over the last 1, 5 or 15 minutes',
            ),
            SizedBox(
              width: 170,
              height: 26,
              child: TextField(
                key: const ValueKey('map-search'),
                controller: search,
                style: small,
                onChanged: onSearch,
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'Filter namespaces',
                  prefixIcon: const Icon(Icons.search, size: 14),
                  prefixIconConstraints: const BoxConstraints(minWidth: 26),
                  suffixIcon: search.text.isEmpty
                      ? null
                      : InkWell(
                          onTap: () {
                            search.clear();
                            onSearch('');
                          },
                          child: const Icon(Icons.close, size: 13),
                        ),
                  suffixIconConstraints: const BoxConstraints(minWidth: 22),
                ),
              ),
            ),
            for (final g in ReservedGroup.values)
              _ToolbarToggle(
                key: ValueKey('map-reserved-${g.name}'),
                label: !reserved.contains(g) && (hidden[g] ?? 0) > 0 ? '${g.label} ${fmtCount(hidden[g]!)}' : g.label,
                icon: switch (g) { ReservedGroup.nodes => Icons.dns_outlined, ReservedGroup.apiServer => Icons.api, ReservedGroup.other => Icons.more_horiz },
                value: reserved.contains(g),
                tooltip: '${reserved.contains(g) ? 'Hide' : 'Show'} ${g.label.toLowerCase()}: ${g.hint}',
                onChanged: (v) => onReserved(g, v),
              ),
            _ToolbarToggle(
              key: const ValueKey('map-live'),
              label: 'Live',
              icon: Icons.blur_on,
              value: live && !reduceMotion,
              tooltip: reduceMotion
                  ? 'Off while the system asks to reduce motion'
                  : 'Move dots along the links that carried traffic in the last half minute (pauses while hidden)',
              onChanged: reduceMotion ? null : onLive,
            ),
          ]),
        ),
        const SizedBox(width: 8),
        Flexible(child: Align(alignment: Alignment.centerRight, child: _Status(data: data))),
      ]),
    );
  }
}

class _Status extends StatelessWidget {
  final TrafficMap? data;
  const _Status({required this.data});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final d = data;
    if (d == null) return const SizedBox.shrink();
    final small = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final windowLen = _parseWindow(d.window);
    final young = d.covered + const Duration(seconds: 20) < windowLen;
    final parts = <InlineSpan>[
      TextSpan(text: '${fmtRate(d.rate)} now'),
      TextSpan(text: ' · ${fmtCount(d.flows)} flows'),
      if (d.drops > 0) TextSpan(text: ' · ${fmtCount(d.drops)} dropped', style: TextStyle(color: severityColor(context, Severity.error))),
      TextSpan(text: young ? ' · counting for ${_ago(d.covered)}' : ' in ${_ago(windowLen)}'),
      if (d.lost > 0) TextSpan(text: ' · relay skipped ${fmtCount(d.lost)}', style: TextStyle(color: severityColor(context, Severity.warn))),
    ];
    final tip = [
      'Flows counted once each (replies and repeat traces aren\'t), from the relay\'s live stream.',
      if (young) 'Counting started ${_ago(d.covered)} ago: the map keeps counting while it is open, and stops a minute after you leave it.',
      if (d.lost > 0) 'Hubble Relay reported ${d.lost} events it couldn\'t deliver (its buffers overflowed): the counts are a lower bound.',
      if (d.uncounted > 0) '${d.uncounted} flows of rarely seen pairs weren\'t counted (more pairs than the map keeps).',
    ].join('\n');
    return Tooltip(
      message: tip,
      child: Text.rich(TextSpan(children: parts), key: const ValueKey('map-status'), style: small, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

/// A Go duration as the backend writes it ("5m0s").
Duration _parseWindow(String w) {
  final m = RegExp(r'^(?:(\d+)h)?(?:(\d+)m)?(?:(\d+)s)?$').firstMatch(w);
  if (m == null) return const Duration(minutes: 5);
  return Duration(hours: int.tryParse(m.group(1) ?? '') ?? 0, minutes: int.tryParse(m.group(2) ?? '') ?? 0, seconds: int.tryParse(m.group(3) ?? '') ?? 0);
}

String _ago(Duration d) {
  if (d.inMinutes >= 1) {
    final s = d.inSeconds % 60;
    return s >= 30 && d.inMinutes < 5 ? '${d.inMinutes}½ min' : '${d.inMinutes} min';
  }
  return '${math.max(1, d.inSeconds)} s';
}

/// A compact segmented control (macOS-style), with optional icons.
class _Segments<T> extends StatelessWidget {
  final String keyPrefix;
  final T value;
  final ValueChanged<T> onChanged;
  final List<(T, String, IconData?)> items;
  final String? tooltip;
  const _Segments({required this.keyPrefix, required this.value, required this.onChanged, required this.items, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final row = Container(
      height: 24,
      decoration: BoxDecoration(border: Border.all(color: colors.separator), borderRadius: BorderRadius.circular(6)),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          for (final (i, (v, label, icon)) in items.indexed) ...[
            if (i > 0) Container(width: 1, color: colors.separator),
            Hoverable(
              key: ValueKey('$keyPrefix-$v'),
              cursor: SystemMouseCursors.basic,
              onTap: () => onChanged(v),
              builder: (h) {
                final on = v == value;
                final fg = on ? theme.colorScheme.onSurface : theme.hintColor;
                return Container(
                  padding: const EdgeInsets.symmetric(horizontal: 9),
                  alignment: Alignment.center,
                  color: on ? theme.colorScheme.onSurface.withValues(alpha: 0.09) : (h ? colors.hover : null),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    if (icon != null) ...[Icon(icon, size: 13, color: on ? theme.colorScheme.primary : fg), const SizedBox(width: 4)],
                    Text(label, style: TextStyle(fontSize: 12, color: fg, fontWeight: on ? FontWeight.w600 : null)),
                  ]),
                );
              },
            ),
          ],
        ]),
      ),
    );
    return tooltip == null ? row : Tooltip(message: tooltip!, child: row);
  }
}

/// A tinted toolbar toggle, as the log toolbar has.
class _ToolbarToggle extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool value;
  final String? tooltip;
  final ValueChanged<bool>? onChanged;
  const _ToolbarToggle({super.key, required this.label, required this.icon, required this.value, this.onChanged, this.tooltip});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final enabled = onChanged != null;
    final on = value && enabled;
    final fg = !enabled ? colors.faint : (on ? theme.colorScheme.primary : theme.hintColor);
    return Semantics(
      label: label,
      toggled: value,
      button: true,
      child: Tooltip(
        message: tooltip ?? label,
        child: Hoverable(
          onTap: enabled ? () => onChanged!(!value) : null,
          cursor: SystemMouseCursors.basic,
          builder: (h) => Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 7),
            decoration: BoxDecoration(
              color: on ? theme.colorScheme.primary.withValues(alpha: 0.13) : (h && enabled ? colors.hover : null),
              borderRadius: BorderRadius.circular(5),
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 14, color: fg),
              const SizedBox(width: 4),
              Text(label, style: TextStyle(fontSize: 12, color: on ? theme.colorScheme.primary : (enabled ? theme.colorScheme.onSurface : colors.faint))),
            ]),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Canvas
// ---------------------------------------------------------------------------

/// The drawing: one CustomPaint for the whole map (no widget per edge),
/// with a hover card over it. Layouts are cached per graph and size, so
/// hovering and the live dots only repaint.
class _MapCanvas extends StatefulWidget {
  final MapGraph graph;
  final List<String> order;
  final MapMode mode;
  final MapFocus focus;
  final bool live;
  final ValueChanged<MapHit?> onTap;
  const _MapCanvas({super.key, required this.graph, required this.order, required this.mode, required this.focus, required this.live, required this.onTap});

  @override
  State<_MapCanvas> createState() => _MapCanvasState();
}

/// The last layouts drawn, for tests to find where things are.
@visibleForTesting
RadialLayout? debugRadialLayout;
@visibleForTesting
MatrixLayout? debugMatrixLayout;

class _MapCanvasState extends State<_MapCanvas> with SingleTickerProviderStateMixin {
  final _hover = ValueNotifier<(MapHit, Offset)?>(null);
  final _clock = ValueNotifier<double>(0);
  late final Ticker _ticker = createTicker((e) => _clock.value = e.inMicroseconds / 1e6);

  Object? _key;
  RadialLayout? _radial;
  MatrixLayout? _matrix;

  @override
  void initState() {
    super.initState();
    _syncTicker();
  }

  @override
  void didUpdateWidget(_MapCanvas old) {
    super.didUpdateWidget(old);
    _syncTicker();
  }

  /// Live dots run only while on, and only when something is active.
  void _syncTicker() {
    final want = widget.live && widget.graph.edges.any((e) => e.rate > 0);
    if (want && !_ticker.isActive) {
      _ticker.start();
    } else if (!want && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _hover.dispose();
    _clock.dispose();
    super.dispose();
  }

  void _layout(Size size, MapPalette p, TextStyle label, TextStyle mono) {
    final key = (widget.graph, widget.order, size, widget.mode, p.dark);
    if (key == _key) return;
    _key = key;
    if (widget.mode == MapMode.radial) {
      _radial = debugRadialLayout = RadialLayout(widget.graph, widget.order, size, p, labelStyle: label, monoStyle: mono);
    } else {
      _matrix = debugMatrixLayout = MatrixLayout(widget.graph, widget.order, size, p, labelStyle: label);
    }
    // A hovered edge from the last data would show stale numbers.
    final h = _hover.value;
    if (h != null) _hover.value = (_hit(h.$2) ?? h.$1, h.$2);
  }

  MapHit? _hit(Offset p) => widget.mode == MapMode.radial ? _radial?.hitTest(p) : _matrix?.hitTest(p);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final p = MapPalette.of(context);
    final label = theme.textTheme.bodySmall!.copyWith(fontSize: 11.5, height: 1.2);
    final mono = monoStyle(context, size: 10.5);
    return LayoutBuilder(builder: (context, box) {
      final size = box.biggest;
      _layout(size, p, label, mono);
      return MouseRegion(
        onHover: (e) {
          final hit = _hit(e.localPosition);
          final cur = _hover.value;
          if (hit == null) {
            if (cur != null) _hover.value = null;
          } else {
            _hover.value = (hit, e.localPosition);
          }
        },
        onExit: (_) => _hover.value = null,
        cursor: SystemMouseCursors.basic,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapUp: (e) => widget.onTap(_hit(e.localPosition)),
          child: ValueListenableBuilder<(MapHit, Offset)?>(
            valueListenable: _hover,
            builder: (context, h, _) => Stack(children: [
              Positioned.fill(
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: widget.mode == MapMode.radial
                        ? RadialPainter(layout: _radial!, p: p, focus: widget.focus, hover: h?.$1, clock: _ticker.isActive ? _clock : null)
                        : MatrixPainter(layout: _matrix!, p: p, focus: widget.focus, hover: h?.$1),
                  ),
                ),
              ),
              if (widget.mode == MapMode.radial) Positioned(left: 12, bottom: 10, child: _Legend(p: p)),
              if (h != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomSingleChildLayout(
                      delegate: _CardPlacement(h.$2),
                      child: _HoverCard(hit: h.$1, graph: widget.graph, gate: _radial?.gateEdge, p: p),
                    ),
                  ),
                ),
            ]),
          ),
        ),
      );
    });
  }
}

/// Puts the hover card beside the pointer, inside the canvas.
class _CardPlacement extends SingleChildLayoutDelegate {
  final Offset at;
  _CardPlacement(this.at);

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints c) => BoxConstraints.loose(Size(math.min(300, c.maxWidth), c.maxHeight));

  @override
  Offset getPositionForChild(Size size, Size child) {
    var x = at.dx + 16, y = at.dy + 16;
    if (x + child.width > size.width - 6) x = at.dx - 16 - child.width;
    if (y + child.height > size.height - 6) y = math.max(6, size.height - 6 - child.height);
    return Offset(math.max(6, x), y);
  }

  @override
  bool shouldRelayout(_CardPlacement old) => old.at != at;
}

class _Legend extends StatelessWidget {
  final MapPalette p;
  const _Legend({required this.p});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall?.copyWith(color: p.hint, fontSize: 11);
    Widget swatch(Color c, String text, {bool dashed = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 16, height: 3, decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(2))),
          const SizedBox(width: 5),
          Text(text, style: style),
        ]);
    return Wrap(spacing: 12, runSpacing: 4, children: [
      swatch(p.ink.withValues(alpha: 0.45), 'between namespaces'),
      swatch(p.egress, 'to the world'),
      swatch(p.ingress, 'from the world'),
      swatch(p.drop, 'dropped'),
    ]);
  }
}

class _HoverCard extends StatelessWidget {
  final MapHit hit;
  final MapGraph graph;
  final MapEdge? gate;
  final MapPalette p;
  const _HoverCard({required this.hit, required this.graph, required this.gate, required this.p});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    final mono = monoStyle(context, size: 11);
    final lines = <Widget>[];
    String title;
    if (hit.node != null) {
      final n = graph.nodes[hit.node!];
      title = n?.label ?? nodeLabel(hit.node!);
      if (n != null) {
        lines.add(Text('${fmtCount(n.out)} out · ${fmtCount(n.inn)} in${n.internal > 0 ? ' · ${fmtCount(n.internal)} within' : ''}', style: small));
        if (n.worldOut > 0 || n.worldIn > 0) {
          lines.add(Text([if (n.worldOut > 0) '${fmtCount(n.worldOut)} to the world', if (n.worldIn > 0) '${fmtCount(n.worldIn)} from the world'].join(' · '), style: small?.copyWith(color: p.egress)));
        }
        if (n.drops > 0) lines.add(Text('${fmtCount(n.drops)} dropped', style: small?.copyWith(color: p.drop)));
        if (n.members.isNotEmpty) lines.add(Text(n.members.take(8).join(', ') + (n.members.length > 8 ? ', …' : ''), style: hint));
        if (n.isNamespace) lines.add(Text('Click to focus and open it in the inspector', style: hint));
      }
    } else {
      final e = hit.edge!;
      final isGate = e.from == worldId && e.to == ingressId;
      title = '${nodeLabel(e.from)} → ${nodeLabel(e.to)}';
      lines.add(Text.rich(TextSpan(children: [
        TextSpan(text: '${fmtCount(e.flows)} flows'),
        if (e.drops > 0) TextSpan(text: ' · ${fmtCount(e.drops)} dropped', style: TextStyle(color: p.drop)),
        TextSpan(text: ' · ${fmtRate(e.rate)} now', style: TextStyle(color: theme.hintColor)),
      ]), style: small));
      if (isGate) lines.add(Text('What Cilium Ingress passed on to pods (Hubble sees its connections, not the clients\')', style: hint));
      void list(String label, Map<String, int> m, {String Function(String)? text}) {
        final top = MapEdge.top(m, 4);
        if (top.isEmpty) return;
        lines.add(Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text.rich(TextSpan(children: [
            TextSpan(text: '$label  ', style: hint),
            TextSpan(text: top.map((c) => c.name.isEmpty ? 'other ${fmtCount(c.n)}' : '${text?.call(c.name) ?? c.name} ${fmtCount(c.n)}').join(' · '), style: mono),
          ])),
        ));
      }

      list('Ports', e.ports);
      if (e.touchesWorld) {
        list(e.toWorld ? 'To' : 'From', e.peers, text: graph.peerText);
        if (MapEdge.top(e.peers, 4).any((c) => graph.names[c.name]?.isCluster == false)) lines.add(Text(PeerName.rdnsNote, style: hint));
      }
      list('From', e.fromWorkloads);
      list('To', e.toWorkloads);
      if (e.reasons.isNotEmpty) {
        lines.add(Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(MapEdge.top(e.reasons, 3).map((c) => '${dropReasonLabel(c.name)} ${fmtCount(c.n)}').join(' · '), style: small?.copyWith(color: p.drop)),
        ));
      }
      if (!isGate) lines.add(Padding(padding: const EdgeInsets.only(top: 3), child: Text('Click for details', style: hint)));
    }
    return Material(
      key: const ValueKey('map-hover-card'),
      elevation: 3,
      shadowColor: Colors.black.withValues(alpha: 0.18),
      color: theme.colorScheme.surface,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(8), border: Border.all(color: AppColors.of(context).separator)),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 3),
          ...lines,
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Side panel
// ---------------------------------------------------------------------------

class _SidePanel extends StatelessWidget {
  final MapGraph graph;
  final TrafficMap? data;
  final String? node;
  final MapEdge? edge;
  final ValueChanged<MapHit?> onSelect;
  final void Function(String from, String to) onCheck;
  final ValueChanged<String> onShowFlows;
  const _SidePanel({
    required this.graph,
    required this.data,
    required this.node,
    required this.edge,
    required this.onSelect,
    required this.onCheck,
    required this.onShowFlows,
  });

  @override
  Widget build(BuildContext context) {
    final e = edge, n = node == null ? null : graph.nodes[node];
    final children = e != null
        ? _edgeDetail(context, e)
        : n != null
            ? _nodeDetail(context, n)
            : _overview(context);
    return PageScroll(padding: const EdgeInsets.fromLTRB(12, 10, 12, 16), children: children);
  }

  List<Widget> _overview(BuildContext context) {
    final theme = Theme.of(context);
    final p = MapPalette.of(context);
    final inbound = graph.nodes.values.where((n) => n.isNamespace && n.worldIn > 0).toList()..sort((a, b) => b.worldIn.compareTo(a.worldIn));
    final outbound = graph.nodes.values.where((n) => n.isNamespace && n.worldOut > 0).toList()..sort((a, b) => b.worldOut.compareTo(a.worldOut));
    final dropping = graph.edges.where((e) => e.drops > 0).toList()..sort((a, b) => b.drops.compareTo(a.drops));
    final busiest = graph.edges.where((e) => !e.touchesWorld && e.from != ingressId).take(5).toList();
    String via(MapNode n) {
      final direct = graph.edge(worldId, n.id), ing = graph.edge(ingressId, n.id);
      final ports = <String, int>{};
      for (final e in [?direct, ?ing]) {
        for (final x in e.ports.entries) {
          ports[x.key] = (ports[x.key] ?? 0) + x.value;
        }
      }
      return [
        if (ing != null) 'via Ingress',
        if (direct != null) 'direct',
        ...MapEdge.top(ports, 3).where((c) => c.name.isNotEmpty).map((c) => c.name),
      ].join(' · ');
    }

    String peers(MapNode n) {
      final e = graph.edge(n.id, worldId);
      if (e == null) return '';
      final top = MapEdge.top(e.peers, 3);
      final named = top.where((c) => c.name.isNotEmpty).map((c) => graph.names[c.name]?.name ?? c.name).toList();
      final more = e.peers.keys.where((k) => k.isNotEmpty).length - named.length;
      return [named.join(', '), if (more > 0) '+$more'].join(' ');
    }

    return [
      Text('Edges of the cluster', style: theme.textTheme.titleSmall),
      const SizedBox(height: 2),
      Text(
        'Namespaces the world reaches and namespaces that reach out, over the last ${data?.window.replaceAll('m0s', 'm') ?? ''}.',
        style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
      ),
      _Section(
        title: 'Reached from the world',
        icon: Icons.south_east,
        color: p.ingress,
        empty: 'No traffic from outside the cluster seen.',
        rows: [for (final n in inbound) _Row(key: ValueKey('map-in-${n.id}'), title: n.label, count: n.worldIn, subtitle: via(n), onTap: () => onSelect(MapHit.node(n.id)))],
      ),
      _Section(
        title: 'Calling out to the world',
        icon: Icons.north_east,
        color: p.egress,
        empty: 'No traffic to outside the cluster seen.',
        rows: [for (final n in outbound) _Row(key: ValueKey('map-out-${n.id}'), title: n.label, count: n.worldOut, subtitle: peers(n), mono: true, onTap: () => onSelect(MapHit.node(n.id)))],
      ),
      if (dropping.isNotEmpty)
        _Section(
          title: 'Dropping',
          icon: Icons.block,
          color: p.drop,
          rows: [
            for (final e in dropping.take(8))
              _Row(
                title: '${nodeLabel(e.from)} → ${nodeLabel(e.to)}',
                count: e.drops,
                countColor: p.drop,
                subtitle: MapEdge.top(e.reasons, 2).map((c) => dropReasonLabel(c.name)).join(', '),
                onTap: () => onSelect(MapHit.edge(e)),
              ),
          ],
        ),
      if (busiest.isNotEmpty)
        _Section(
          title: 'Busiest links',
          icon: Icons.swap_horiz,
          color: p.hint,
          rows: [
            for (final e in busiest)
              _Row(
                title: '${nodeLabel(e.from)} → ${nodeLabel(e.to)}',
                count: e.total,
                subtitle: MapEdge.top(e.ports, 3).where((c) => c.name.isNotEmpty).map((c) => c.name).join(' · '),
                mono: true,
                onTap: () => onSelect(MapHit.edge(e)),
              ),
          ],
        ),
    ];
  }

  Widget _header(BuildContext context, String title, {String? subtitle}) {
    final theme = Theme.of(context);
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(title, style: theme.textTheme.titleSmall, key: const ValueKey('map-selection-title')),
          if (subtitle != null) Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ]),
      ),
      IconButton(tooltip: 'Back to the overview (Esc)', iconSize: 15, visualDensity: VisualDensity.compact, icon: const Icon(Icons.close), onPressed: () => onSelect(null)),
    ]);
  }

  List<Widget> _nodeDetail(BuildContext context, MapNode n) {
    final p = MapPalette.of(context);
    final outs = graph.edges.where((e) => e.from == n.id).toList();
    final ins = graph.edges.where((e) => e.to == n.id).toList();
    final reasons = <String, int>{};
    for (final e in [...outs, ...ins]) {
      for (final x in e.reasons.entries) {
        reasons[x.key] = (reasons[x.key] ?? 0) + x.value;
      }
    }
    return [
      _header(context, n.label, subtitle: n.isNamespace ? 'Namespace' : (n.id == otherNamespacesId ? n.members.join(', ') : 'Reserved identity')),
      const SizedBox(height: 6),
      if (n.isNamespace)
        Wrap(spacing: 6, runSpacing: 6, children: [
          OutlinedButton.icon(
            key: const ValueKey('map-show-flows'),
            onPressed: () => onShowFlows(n.id),
            icon: const Icon(Icons.swap_horiz, size: 15),
            label: const Text('Flows'),
          ),
          OutlinedButton.icon(
            onPressed: () => context.read<AppState>().openRef(ObjectRef(kind: 'Namespace', name: n.id)),
            icon: const Icon(Icons.open_in_new, size: 14),
            label: const Text('Inspect'),
          ),
        ]),
      const SizedBox(height: 8),
      KeyValueTable(keyWidth: 90, [
        ('Out', fmtCount(n.out)),
        ('In', fmtCount(n.inn)),
        if (n.internal > 0) ('Within', fmtCount(n.internal)),
        if (n.drops > 0) ('Dropped', Text(fmtCount(n.drops), style: TextStyle(color: p.drop))),
        if (reasons.isNotEmpty) ('Why', MapEdge.top(reasons, 3).map((c) => dropReasonLabel(c.name)).join(', ')),
      ]),
      _Section(
        title: 'Sends to',
        icon: Icons.north_east,
        color: p.egress,
        empty: 'Nothing.',
        rows: [for (final e in outs) _edgeRow(e, nodeLabel(e.to), p)],
      ),
      _Section(
        title: 'Receives from',
        icon: Icons.south_west,
        color: p.ingress,
        empty: 'Nothing.',
        rows: [for (final e in ins) _edgeRow(e, nodeLabel(e.from), p)],
      ),
    ];
  }

  _Row _edgeRow(MapEdge e, String title, MapPalette p) => _Row(
        title: title,
        count: e.total,
        countColor: e.drops > e.flows ? p.drop : null,
        subtitle: [
          if (e.drops > 0) '${fmtCount(e.drops)} dropped',
          ...MapEdge.top(e.touchesWorld ? e.peers : e.ports, 3).where((c) => c.name.isNotEmpty).map((c) => e.touchesWorld ? (graph.names[c.name]?.name ?? c.name) : c.name),
        ].join(' · '),
        mono: true,
        onTap: () => onSelect(MapHit.edge(e)),
      );

  List<Widget> _edgeDetail(BuildContext context, MapEdge e) {
    final theme = Theme.of(context);
    final p = MapPalette.of(context);
    final reach = reachFor(e);
    final ns = !isReserved(e.from) ? e.from : (!isReserved(e.to) ? e.to : null);
    List<Widget> counts(String title, Map<String, int> m, {bool peers = false}) {
      final top = MapEdge.top(m, 8);
      if (top.isEmpty) return const [];
      return [
        _Section(title: title, rows: [
          for (final c in top)
            _Row(
              title: c.name.isEmpty ? 'other' : c.name,
              titleWidget: peers && graph.names[c.name] != null ? _PeerTitle(c.name, graph.names[c.name]!) : null,
              count: c.n,
              mono: c.name.isNotEmpty,
              trailing: peers && c.name.isNotEmpty && ns != null
                  ? IconButton(
                      tooltip: 'Can $ns reach ${c.name}?',
                      iconSize: 14,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.alt_route),
                      onPressed: () => e.toWorld ? onCheck('ns:$ns', peerSpec(c.name)) : onCheck(peerSpec(c.name), 'ns:$ns'),
                    )
                  : null,
            ),
        ]),
      ];
    }

    return [
      _header(context, '${nodeLabel(e.from)} → ${nodeLabel(e.to)}', subtitle: e.toWorld ? 'Leaving the cluster' : (e.fromWorld ? 'Arriving from outside' : null)),
      const SizedBox(height: 6),
      Wrap(spacing: 6, runSpacing: 6, children: [
        if (reach != null)
          FilledButton.tonalIcon(
            key: const ValueKey('map-check-reach'),
            onPressed: () => onCheck(reach.$1, reach.$2),
            icon: const Icon(Icons.alt_route, size: 15),
            label: Text('Can ${nodeLabel(e.from)} reach ${e.toWorld ? MapEdge.top(e.peers, 1).first.name : nodeLabel(e.to)}?', overflow: TextOverflow.ellipsis),
          ),
        if (ns != null)
          OutlinedButton.icon(
            key: const ValueKey('map-show-flows'),
            onPressed: () => onShowFlows(ns),
            icon: const Icon(Icons.swap_horiz, size: 15),
            label: Text('Flows in $ns', overflow: TextOverflow.ellipsis),
          ),
      ]),
      const SizedBox(height: 8),
      KeyValueTable(keyWidth: 90, [
        ('Flows', fmtCount(e.flows)),
        if (e.drops > 0) ('Dropped', Text('${fmtCount(e.drops)} (${(e.dropShare * 100).toStringAsFixed(e.dropShare < 0.1 ? 1 : 0)}%)', style: TextStyle(color: p.drop))),
        ('Now', e.rate > 0 ? fmtRate(e.rate) : Text('quiet lately', style: TextStyle(color: theme.hintColor))),
      ]),
      if (e.reasons.isNotEmpty)
        _Section(title: 'Dropped because', color: p.drop, icon: Icons.block, rows: [
          for (final c in MapEdge.top(e.reasons, 5)) _Row(title: dropReasonLabel(c.name), count: c.n, countColor: p.drop),
        ]),
      ...counts(e.toWorld ? 'Destinations' : 'Sources', e.peers, peers: true),
      ...counts('Ports', e.ports),
      ...counts('From workloads', e.fromWorkloads),
      ...counts('To workloads', e.toWorkloads),
    ];
  }
}

class _Section extends StatelessWidget {
  final String title;
  final IconData? icon;
  final Color? color;
  final String? empty;
  final List<Widget> rows;
  const _Section({required this.title, this.icon, this.color, this.empty, required this.rows});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 18),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // The app's section heading: the direction's glyph in its map
        // colour, the title, a hairline running to the count.
        SizedBox(
          height: 24,
          child: TitleRule(
            title: Row(mainAxisSize: MainAxisSize.min, children: [
              if (icon != null) ...[Icon(icon, size: 13, color: color ?? theme.hintColor), const SizedBox(width: 6)],
              Flexible(child: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: sectionTitleStyle(context))),
            ]),
            trailing: rows.isEmpty ? null : Text('${rows.length}', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontFeatures: tabularFigures)),
          ),
        ),
        const SizedBox(height: 4),
        if (rows.isEmpty && empty != null) Text(empty!, style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).faint)) else ...rows,
      ]),
    );
  }
}

class _Row extends StatelessWidget {
  final String title;
  final int count;
  final Color? countColor;
  final String? subtitle;
  final bool mono;
  final Widget? trailing;
  final VoidCallback? onTap;

  /// Replaces the title text.
  final Widget? titleWidget;
  const _Row({super.key, required this.title, this.titleWidget, required this.count, this.countColor, this.subtitle, this.mono = false, this.trailing, this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final small = theme.textTheme.bodySmall;
    return Hoverable(
      onTap: onTap,
      builder: (h) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(color: h && onTap != null ? colors.hover : null, borderRadius: BorderRadius.circular(5)),
        child: Row(children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              titleWidget ?? Text(title, maxLines: 1, overflow: TextOverflow.ellipsis, style: mono && subtitle == null ? monoStyle(context, size: 11.5) : small),
              if (subtitle != null && subtitle!.isNotEmpty)
                Text(subtitle!, maxLines: 1, overflow: TextOverflow.ellipsis, style: (mono ? monoStyle(context, size: 10.5) : small)?.copyWith(color: theme.hintColor)),
            ]),
          ),
          const SizedBox(width: 6),
          Text(fmtCount(count), style: monoStyle(context, size: 11.5, color: countColor ?? theme.hintColor)),
          ?trailing,
        ]),
      ),
    );
  }
}

/// A world address with its label: a cluster object's name opens it in the
/// inspector; a PTR name is muted, with a note. The IP follows, dimmed.
class _PeerTitle extends StatelessWidget {
  final String ip;
  final PeerName name;
  const _PeerTitle(this.ip, this.name);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ref = name.ref;
    final Widget label = ref != null
        ? ResourceLink(ref, label: name.name, singleLine: true)
        : name.isCluster
            ? Text(name.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5))
            : Tooltip(
                message: PeerName.rdnsNote,
                child: Text(name.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5, color: theme.hintColor)),
              );
    return Row(children: [
      Flexible(child: label),
      const SizedBox(width: 6),
      Flexible(child: Text(ip, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 10.5, color: theme.hintColor.withValues(alpha: 0.7)))),
    ]);
  }
}
