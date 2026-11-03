import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

bool _fontsLoaded = false;

/// Loads Roboto, Material Icons and Menlo so headless renders look real
/// (flutter_test otherwise draws every glyph as a box).
Future<void> loadRealFonts() async {
  if (_fontsLoaded) return;
  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? File(Platform.resolvedExecutable).parent.parent.parent.parent.parent.parent.path;
  final fonts = '$flutterRoot/bin/cache/artifacts/material_fonts';
  Future<void> load(String family, List<String> files) async {
    final loader = FontLoader(family);
    for (final f in files) {
      final file = File(f);
      if (file.existsSync()) loader.addFont(Future.value(ByteData.sublistView(file.readAsBytesSync())));
    }
    await loader.load();
  }

  await load('Roboto', ['$fonts/Roboto-Regular.ttf', '$fonts/Roboto-Medium.ttf', '$fonts/Roboto-Bold.ttf']);
  await load('MaterialIcons', ['$fonts/MaterialIcons-Regular.otf']);
  await load('Menlo', ['/System/Library/Fonts/Menlo.ttc']);
  _fontsLoaded = true;
}

/// Writes a PNG of the current widget tree to `build/screenshots/<name>.png`
/// so you can open it and eyeball the layout. Call [loadRealFonts] before
/// pumping. Not an assertion — purely for visual review.
Future<String> saveScreenshot(WidgetTester tester, String name) async {
  // Capture the whole view (including dialogs/overlays) from the root layer.
  final view = tester.binding.renderViews.first;
  final layer = view.debugLayer! as OffsetLayer;
  final path = '${Directory.current.path}/build/screenshots/$name.png';
  await tester.runAsync(() async {
    final image = await layer.toImage(Offset.zero & view.size);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    File(path)
      ..createSync(recursive: true)
      ..writeAsBytesSync(bytes!.buffer.asUint8List());
  });
  return path;
}
