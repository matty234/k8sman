// Generates the k8sman app icon at every AppIcon.appiconset size.
//
//   cd tools/app_icon && flutter test
//
// Each size is painted directly at its pixel size (not downsampled) so the
// small sizes stay crisp; sizes of 32px and below use heavier strokes and
// drop the glow.
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';

const sizes = [16, 32, 64, 128, 256, 512, 1024];
const outDir = '../../frontend/macos/Runner/Assets.xcassets/AppIcon.appiconset';

// Palette.
const accent = Color(0xFF0A84FF);
const accentLight = Color(0xFF5AC8FA);
const bgTop = Color(0xFF1F2B40);
const bgBottom = Color(0xFF080C14);

void main() {
  testWidgets('generate app icon', (tester) async {
    await tester.runAsync(() async {
      for (final px in sizes) {
        final bytes = await renderIcon(px);
        final f = File('$outDir/app_icon_$px.png');
        await f.writeAsBytes(bytes);
      }
    });
  });
}

Future<List<int>> renderIcon(int px) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  final s = px / 1024.0;
  canvas.scale(s);
  paintIcon(canvas, small: px <= 32, tiny: px <= 16);
  final image = await recorder.endRecording().toImage(px, px);
  final data = await image.toByteData(format: ui.ImageByteFormat.png);
  return data!.buffer.asUint8List();
}

/// Paints the icon on a 1024×1024 canvas, following the macOS icon grid:
/// an 824pt rounded square (continuous corners) inset 100pt, with a soft
/// drop shadow.
void paintIcon(Canvas canvas, {bool small = false, bool tiny = false}) {
  // Small sizes use more of the canvas so the shape stays legible.
  final inset = tiny ? 40.0 : (small ? 64.0 : 100.0);
  final body = Rect.fromLTWH(inset, inset, 1024 - 2 * inset, 1024 - 2 * inset);
  final radius = body.width * 0.225;
  final shape = RSuperellipse.fromRectAndRadius(body, Radius.circular(radius));

  // Drop shadow.
  if (!small) {
    canvas.drawRSuperellipse(
      shape.shift(const Offset(0, 12)),
      Paint()
        ..color = const Color(0x66000000)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
  }

  // Dark gradient body.
  canvas.drawRSuperellipse(
    shape,
    Paint()
      ..shader = ui.Gradient.linear(body.topCenter, body.bottomCenter, [bgTop, bgBottom]),
  );

  canvas.save();
  canvas.clipRSuperellipse(shape);
  // Soft blue light from the top, behind the motif.
  canvas.drawCircle(
    body.center.translate(0, -body.height * 0.18),
    body.width * 0.62,
    Paint()
      ..shader = ui.Gradient.radial(
        body.center.translate(0, -body.height * 0.18),
        body.width * 0.62,
        [accent.withValues(alpha: 0.30), accent.withValues(alpha: 0.0)],
      ),
  );
  canvas.restore();

  // Hairline highlight around the edge.
  if (!small) {
    canvas.drawRSuperellipse(
      shape.deflate(1.5),
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3
        ..shader = ui.Gradient.linear(
          body.topCenter,
          body.bottomCenter,
          [const Color(0x40FFFFFF), const Color(0x08FFFFFF)],
        ),
    );
  }

  paintMotif(canvas, body, small: small, tiny: tiny);
}

/// A hexagonal node graph: six outer nodes joined in a ring, each wired to a
/// central hub (a cluster of nodes around a control plane).
void paintMotif(Canvas canvas, Rect body, {required bool small, required bool tiny}) {
  final c = body.center;
  final r = body.width * (tiny ? 0.33 : 0.30);
  final weight = tiny ? 2.1 : (small ? 1.6 : 1.0);
  final ring = 30.0 * weight * (body.width / 824);
  final spoke = 22.0 * weight * (body.width / 824);
  final nodeR = 44.0 * math.min(weight, 1.4) * (body.width / 824);
  final hubR = 74.0 * math.min(weight, 1.3) * (body.width / 824);

  // Pointy-top hexagon vertices.
  final pts = [
    for (var i = 0; i < 6; i++) c + Offset.fromDirection(-math.pi / 2 + i * math.pi / 3, r),
  ];
  final bounds = Rect.fromCircle(center: c, radius: r + nodeR);
  final stroke = ui.Gradient.linear(bounds.topLeft, bounds.bottomRight, [accentLight, accent]);

  final rim = Path()..addPolygon(pts, true);
  final spokes = Path();
  for (final p in pts) {
    final dir = (p - c) / (p - c).distance;
    final from = c + dir * (hubR + spoke * 0.9);
    final to = p - dir * (nodeR + spoke * 0.6);
    spokes
      ..moveTo(from.dx, from.dy)
      ..lineTo(to.dx, to.dy);
  }

  Paint line(double w) => Paint()
    ..style = PaintingStyle.stroke
    ..strokeWidth = w
    ..strokeCap = StrokeCap.round
    ..strokeJoin = StrokeJoin.round
    ..shader = stroke;

  // Glow.
  if (!small) {
    final glow = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = ring * 1.6
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..color = accent.withValues(alpha: 0.45)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 28);
    canvas.drawPath(rim, glow);
    canvas.drawCircle(c, hubR, Paint()
      ..color = accent.withValues(alpha: 0.5)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40));
  }

  canvas.drawPath(rim, line(ring));
  if (!tiny) {
    // Spokes a touch dimmer than the rim.
    canvas.drawPath(
      spokes,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = spoke
        ..strokeCap = StrokeCap.round
        ..color = accent.withValues(alpha: 0.85),
    );
  }

  // Outer nodes: filled discs with a dark core so they read as nodes.
  for (final p in pts) {
    canvas.drawCircle(p, nodeR, Paint()..shader = stroke);
    if (!small) canvas.drawCircle(p, nodeR * 0.42, Paint()..color = bgBottom.withValues(alpha: 0.85));
  }

  // Hub: white core with an accent ring.
  canvas.drawCircle(c, hubR, Paint()..shader = stroke);
  canvas.drawCircle(c, hubR * (small ? 0.5 : 0.62), Paint()..color = const Color(0xFFFFFFFF));
}
