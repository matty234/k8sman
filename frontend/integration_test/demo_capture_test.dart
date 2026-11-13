// Records short demo clips of the real app against the sample cluster
// (`make cluster`) for the README / launch post. Not part of the test suite.
//
// Run with a backend already serving the sample cluster:
//   flutter test integration_test/demo_capture_test.dart -d macos \
//     --dart-define=K8SMAN_BACKEND=http://127.0.0.1:7461 \
//     --dart-define=K8SMAN_TOKEN=<token> --dart-define=DEMO_OUT=<dir> \
//     [--dart-define=DEMO_SCENES=palette,filter]
// Each scene writes <dir>/<scene>.rgba (raw frames) and <scene>.json (size and
// per-frame timestamps); tool/encode_demo.py turns them into AVIF/GIF.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/app/backend.dart';
import 'package:k8sman/main.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:provider/provider.dart';

const _out = String.fromEnvironment('DEMO_OUT');
const _scenes = String.fromEnvironment('DEMO_SCENES');
const _dark = String.fromEnvironment('DEMO_THEME') == 'dark';
const _size = Size(1280, 800);

/// Output frames per logical pixel (1 = 1280×800; raise for sharper clips).
final _capture = double.tryParse(const String.fromEnvironment('DEMO_SCALE')) ?? 1.0;

bool _want(String scene) => _scenes.isEmpty || _scenes.split(',').contains(scene);

/// Pointer, key caption and fake window buttons drawn over the app (an
/// in-app capture has no system cursor or titlebar).
final _cursor = ValueNotifier<Offset?>(null);
final _pressed = ValueNotifier<bool>(false);
final _caption = ValueNotifier<String?>(null);
final _frameKey = GlobalKey();

class _Overlay extends StatelessWidget {
  final Widget child;
  const _Overlay({required this.child});

  @override
  Widget build(BuildContext context) => Directionality(
    textDirection: TextDirection.ltr,
    child: ColoredBox(
      // What the window's vibrancy looks like behind the sidebar.
      color: _dark ? const Color(0xFF232428) : const Color(0xFFE9E8EC),
      child: Stack(
        children: [
          Positioned.fill(child: child),
          const Positioned(left: 14, top: 20, child: _TrafficLights()),
          Positioned.fill(
            child: IgnorePointer(
              child: ValueListenableBuilder<String?>(
                valueListenable: _caption,
                builder: (_, c, _) => c == null
                    ? const SizedBox.shrink()
                    : Align(
                        alignment: const Alignment(0, 0.86),
                        child: DecoratedBox(
                          decoration: BoxDecoration(color: const Color(0xD9222222), borderRadius: BorderRadius.circular(10)),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                            child: Text(
                              c,
                              style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.w600, decoration: TextDecoration.none),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ),
          Positioned.fill(
            child: IgnorePointer(
              child: AnimatedBuilder(
                animation: Listenable.merge([_cursor, _pressed]),
                builder: (_, _) {
                  final p = _cursor.value;
                  if (p == null) return const SizedBox.shrink();
                  return CustomPaint(painter: _CursorPainter(p, _pressed.value));
                },
              ),
            ),
          ),
        ],
      ),
    ),
  );
}

class _TrafficLights extends StatelessWidget {
  const _TrafficLights();

  @override
  Widget build(BuildContext context) => Row(
    children: [
      for (final c in const [Color(0xFFFF5F57), Color(0xFFFEBC2E), Color(0xFF28C840)])
        Container(
          width: 12,
          height: 12,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            color: c,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0x22000000), width: 0.5),
          ),
        ),
    ],
  );
}

/// A macOS-style arrow pointer.
class _CursorPainter extends CustomPainter {
  final Offset at;
  final bool pressed;
  _CursorPainter(this.at, this.pressed);

  @override
  void paint(Canvas canvas, Size size) {
    if (pressed) {
      canvas.drawCircle(at, 14, Paint()..color = const Color(0x332F7BF6));
    }
    final s = pressed ? 0.9 : 1.0;
    final path = Path()
      ..moveTo(0, 0)
      ..lineTo(0, 17)
      ..lineTo(4.2, 13)
      ..lineTo(7, 19.5)
      ..lineTo(9.6, 18.4)
      ..lineTo(6.9, 12.2)
      ..lineTo(12.3, 12.2)
      ..close();
    canvas.save();
    canvas.translate(at.dx, at.dy);
    canvas.scale(s);
    canvas.drawPath(
      path.shift(const Offset(0.6, 1)),
      Paint()
        ..color = const Color(0x40000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 1.2),
    );
    canvas.drawPath(path, Paint()..color = Colors.black);
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_CursorPainter old) => old.at != at || old.pressed != pressed;
}

/// Grabs frames from the root layer as fast as it can while recording.
class _Recorder {
  final WidgetTester tester;
  final String name;
  _Recorder(this.tester, this.name);

  late final IOSink _sink = File('$_out/$name.rgba').openWrite();
  final _times = <int>[];
  final _clock = Stopwatch();
  bool _on = false;
  Future<void>? _loop;
  int _w = 0, _h = 0;

  void start() {
    _on = true;
    _clock.start();
    _loop = _run();
  }

  Future<void> _run() async {
    while (_on) {
      final boundary = _frameKey.currentContext?.findRenderObject();
      // Skip a frame caught between layout and paint (e.g. mid-drag).
      if (boundary is RenderRepaintBoundary && !boundary.debugNeedsPaint) {
        // The app plus our overlay, without the test binding's tap markers.
        final image = await boundary.toImage(pixelRatio: _capture);
        final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
        _w = image.width;
        _h = image.height;
        image.dispose();
        if (data != null) {
          _sink.add(data.buffer.asUint8List());
          _times.add(_clock.elapsedMilliseconds);
        }
      }
      // ~20 fps, and never more than a scene's worth (raw frames are big).
      if (_clock.elapsed > const Duration(seconds: 40)) {
        _on = false;
        throw StateError('scene $name ran over 40s');
      }
      await Future<void>.delayed(const Duration(milliseconds: 35));
    }
  }

  Future<void> stop() async {
    _on = false;
    await _loop;
    await _sink.close();
    File('$_out/$name.json').writeAsStringSync(jsonEncode({'width': _w, 'height': _h, 'times': _times}));
  }
}

late WidgetTester _t;

/// Real-time wait that keeps frames coming.
Future<void> wait(int ms) async {
  final end = DateTime.now().add(Duration(milliseconds: ms));
  while (DateTime.now().isBefore(end)) {
    await _t.pump();
    await Future<void>.delayed(const Duration(milliseconds: 16));
  }
}

Future<void> waitFor(Finder f, {int timeoutMs = 15000}) async {
  final end = DateTime.now().add(Duration(milliseconds: timeoutMs));
  while (f.evaluate().isEmpty) {
    if (DateTime.now().isAfter(end)) throw StateError('timed out waiting for $f');
    await wait(100);
  }
}

/// One simulated mouse for every move, click and drag.
TestGesture? _mouse;

Future<TestGesture> _ensureMouse(Offset at) async {
  final m = _mouse;
  if (m != null) return m;
  final g = await _t.createGesture(kind: PointerDeviceKind.mouse);
  await g.addPointer(location: at);
  return _mouse = g;
}

double _ease(double x) => x < 0.5 ? 2 * x * x : 1 - math.pow(-2 * x + 2, 2) / 2;

/// Glides the pointer to [to] (ease in-out), hovering as it goes; with the
/// button down this is a drag.
Future<void> moveTo(Offset to, {int ms = 450, int steps = 18}) async {
  final from = _cursor.value ?? Offset(to.dx + 220, to.dy + 160);
  final g = await _ensureMouse(from);
  for (var i = 1; i <= steps; i++) {
    final p = Offset.lerp(from, to, _ease(i / steps))!;
    _cursor.value = p;
    await g.moveTo(p);
    await _t.pump();
    await Future<void>.delayed(Duration(milliseconds: ms ~/ steps));
  }
}

Future<void> clickAt(Offset p) async {
  await moveTo(p);
  final g = _mouse!;
  _pressed.value = true;
  await g.down(p);
  await wait(90);
  await g.up();
  _pressed.value = false;
  await wait(250);
}

Future<void> click(Finder f, {Alignment align = Alignment.center}) async {
  await waitFor(f);
  final r = _t.getRect(f.first);
  await clickAt(align.withinRect(r));
}

/// Mouse drag with the pointer drawn along the way.
Future<void> drag(Offset from, Offset to, {int ms = 900}) async {
  await moveTo(from);
  final g = _mouse!;
  _pressed.value = true;
  await g.down(from);
  await wait(120);
  await moveTo(to, ms: ms, steps: 30);
  await wait(150);
  await g.up();
  _pressed.value = false;
  await wait(400);
}

/// Types [text] into [field] a character at a time.
Future<void> typeInto(Finder field, String text, {String prefix = '', int perChar = 85}) async {
  for (var i = 1; i <= text.length; i++) {
    await _t.enterText(field, prefix + text.substring(0, i));
    await wait(perChar);
  }
}

/// Opens the palette with ⌘K (shown as a caption); clicks the sidebar's
/// search button if the key didn't land.
Future<Finder> openPalette() async {
  final search = find.byKey(const ValueKey('palette-search'));
  await shortcut(LogicalKeyboardKey.keyK, '⌘K');
  if (search.evaluate().isEmpty) await click(find.byKey(const ValueKey('palette-launcher')));
  await waitFor(search);
  return search;
}

Future<void> shortcut(LogicalKeyboardKey key, String label, {bool meta = true}) async {
  _caption.value = label;
  if (meta) await _t.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await _t.sendKeyEvent(key);
  if (meta) await _t.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await wait(500);
  _caption.value = null;
}

Future<void> key(LogicalKeyboardKey k, {String? label, int after = 300}) async {
  if (label != null) _caption.value = label;
  await _t.sendKeyEvent(k);
  await wait(after);
  if (label != null) _caption.value = null;
}

Future<void> scene(String name, Future<void> Function() body) async {
  if (!_want(name)) return;
  final r = _Recorder(_t, name)..start();
  try {
    await body();
  } finally {
    await _mouse?.removePointer();
    _mouse = null;
    _cursor.value = null;
    _caption.value = null;
    await r.stop();
  }
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  binding.framePolicy = LiveTestWidgetsFlutterBindingFramePolicy.fullyLive;

  testWidgets('demo clips', (tester) async {
    _t = tester;
    assert(_out.isNotEmpty, 'pass --dart-define=DEMO_OUT=<dir>');
    Directory(_out).createSync(recursive: true);
    tester.view.physicalSize = _size * 2;
    tester.view.devicePixelRatio = 2;

    final api = ApiClient();
    final app = AppState(api);
    final backend = BackendController(api, onReady: app.backendConnected);
    await tester.pumpWidget(
      MultiProvider(
        providers: [
          Provider<ApiClient>.value(value: api),
          ChangeNotifierProvider<AppState>.value(value: app),
          ChangeNotifierProvider<BackendController>.value(value: backend),
          ChangeNotifierProvider<LogDock>(create: (_) => LogDock(api)),
        ],
        child: RepaintBoundary(key: _frameKey, child: const _Overlay(child: K8sManApp(themeMode: _dark ? ThemeMode.dark : ThemeMode.light))),
      ),
    );
    unawaited(backend.start());
    await waitFor(find.byKey(const ValueKey('palette-launcher')), timeoutMs: 30000);
    debugPrint('DEMO connected');
    app.setNamespace('demo');
    await wait(2500);

    // Scenes are added below.
    await runScenes(tester, app);
  });
}

/// Mouse-wheel scroll at [at] (the pointer stays where it is).
Future<void> scroll(Offset at, double dy, {int steps = 12, int ms = 900}) async {
  await moveTo(at);
  for (var k = 0; k < steps; k++) {
    await _t.sendEventToBinding(PointerScrollEvent(position: at, scrollDelta: Offset(0, dy / steps), kind: PointerDeviceKind.mouse));
    await wait(ms ~/ steps);
  }
}

void hideDock() {
  final dock = Provider.of<LogDock>(_frameKey.currentContext!, listen: false);
  if (!dock.collapsed) dock.setCollapsed(true);
}

Future<void> showPods(AppState app) async {
  app.selectType(app.typeFor('', 'Pod')!);
  app.showView(MainView.resources);
  await wait(1200);
}

Future<void> runScenes(WidgetTester tester, AppState app) async {
  // ⌘K: jump to a kind, then straight to an object.
  if (_want('palette')) {
    await showPods(app);
    await wait(1500);
  }
  await scene('palette', () async {
    var search = await openPalette();
    await typeInto(search, 'deploy', perChar: 110);
    await wait(700);
    await key(LogicalKeyboardKey.enter, label: 'Return', after: 1400);
    search = await openPalette();
    await typeInto(search, 'crashy', perChar: 110);
    await wait(900);
    await key(LogicalKeyboardKey.enter, label: 'Return', after: 2600);
  });
  app.closeDetail();

  // The filter box suggests columns, then values seen in that column.
  if (_want('filter')) {
    await showPods(app);
    await wait(1500);
  }
  await scene('filter', () async {
    final field = find.byKey(const ValueKey('table-filter'));
    await click(field);
    await wait(600);
    await typeInto(field, 'sta', perChar: 140);
    await wait(700);
    await key(LogicalKeyboardKey.tab, label: 'Tab', after: 900);
    await typeInto(field, 'r', prefix: 'status=', perChar: 140);
    await wait(900);
    await key(LogicalKeyboardKey.enter, label: 'Return', after: 1500);
    await typeInto(field, 'restarts>3', prefix: 'status=Running ', perChar: 110);
    await wait(2200);
    await _t.enterText(field, '');
    await wait(300);
  });

  // Drag a header to move a column; drag a divider to resize one.
  if (_want('columns')) {
    await showPods(app);
    await wait(1500);
  }
  await scene('columns', () async {
    final status = _t.getRect(find.byKey(const ValueKey('header-Status')));
    final ns = _t.getRect(find.byKey(const ValueKey('header-Namespace')));
    await drag(status.center, Offset(ns.left + 4, status.center.dy), ms: 1300);
    await wait(1200);
    final name = _t.getRect(find.byKey(const ValueKey('resize-Name')));
    await drag(name.center, name.center + const Offset(150, 0), ms: 900);
    await wait(1600);
  });

  // Logs stream into the dock; a terminal opens next to them.
  if (_want('logs')) {
    await showPods(app);
    await wait(1500);
  }
  await scene('logs', () async {
    await click(find.textContaining('web-').first);
    await wait(1200);
    await click(find.byKey(const ValueKey('action-logs')));
    await wait(4500);
    await click(find.byKey(const ValueKey('action-terminal')));
    await wait(900);
    // Pods with several containers ask which one.
    final pick = find.text('nginx');
    if (pick.evaluate().length > 1) await click(pick.last);
    // (The terminal reads text through the platform text input, which a
    // test can't drive: the clip ends on the live prompt.)
    await wait(3000);
  });
  app.closeDetail();
  hideDock();
  // Settle on Overview before recording, so the looped clip doesn't open on
  // the previous scene.
  debugPrint('DEMO before overview');
  app.showView(MainView.overview);
  await wait(3000);
  debugPrint('DEMO on overview');

  // Cluster health at a glance: scroll through the groups, hold, back up.
  await scene('overview', () async {
    await wait(1500);
    final pos = _pageScroll(const Offset(760, 500));
    await moveTo(const Offset(760, 500));
    if (pos != null && pos.maxScrollExtent > 0) {
      final ms = (pos.maxScrollExtent * 6).clamp(2500, 7000).round();
      unawaited(pos.animateTo(pos.maxScrollExtent, duration: Duration(milliseconds: ms), curve: Curves.easeInOut));
      await wait(ms + 1800);
      unawaited(pos.animateTo(0, duration: const Duration(milliseconds: 1400), curve: Curves.easeInOut));
      await wait(2200);
    } else {
      await wait(4000);
    }
  });
}

/// The vertical scroll position of the page under [at]: the scrollable there
/// with the most content (not the sidebar's).
ScrollPosition? _pageScroll(Offset at) {
  ScrollPosition? best;
  for (final e in find.byType(Scrollable).evaluate()) {
    final st = (e as StatefulElement).state as ScrollableState;
    if (st.axisDirection != AxisDirection.down) continue;
    final box = e.renderObject as RenderBox?;
    if (box == null || !box.hasSize) continue;
    final r = box.localToGlobal(Offset.zero) & box.size;
    if (!r.contains(at)) continue;
    if (best == null || st.position.maxScrollExtent > best.maxScrollExtent) best = st.position;
  }
  return best;
}
