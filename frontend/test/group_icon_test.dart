import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/ui/widgets/group_icon.dart';
import 'package:provider/provider.dart';

/// Serves canned `/api/icons/{group}` answers and records the calls.
class IconApi extends ApiClient {
  final Map<String, Uint8List?> icons;
  final Set<String> failing;
  final List<String> calls = [];
  IconApi({this.icons = const {}, this.failing = const {}}) : super(base: Uri.parse('http://icons.test'));

  @override
  Future<Uint8List?> groupIcon(String group) async {
    calls.add(group);
    if (failing.contains(group)) throw ApiException(500, 'boom');
    return icons[group];
  }
}

/// A small solid PNG, encoded for real (call inside runAsync).
Future<Uint8List> solidPng(Color color, {int size = 32}) async {
  final rec = ui.PictureRecorder();
  Canvas(rec).drawCircle(Offset(size / 2, size / 2), size / 2, Paint()..color = color);
  final img = await rec.endRecording().toImage(size, size);
  final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
  return bytes!.buffer.asUint8List();
}

Future<void> pumpIcons(WidgetTester tester, ApiClient? api, List<String> groups) async {
  final row = MaterialApp(
    home: Scaffold(body: Row(children: [for (final g in groups) GroupIcon(group: g, size: 24)])),
  );
  await tester.pumpWidget(api == null ? row : Provider<ApiClient>.value(value: api, child: row));
  await tester.pump();
  await tester.pump();
}

Finder image(String g) => find.byKey(ValueKey('group-icon-image/$g'));
Finder monogram(String g) => find.byKey(ValueKey('group-icon-monogram/$g'));

void main() {
  setUp(GroupIconCache.clear);

  test('bundled assets match groups and subdomains only', () {
    expect(bundledGroupIconAsset('argoproj.io'), 'assets/icons/argo.png');
    expect(bundledGroupIconAsset('acme.cert-manager.io'), 'assets/icons/cert-manager.png');
    expect(bundledGroupIconAsset('gateway.networking.k8s.io'), 'assets/icons/kubernetes.png');
    expect(bundledGroupIconAsset('cluster.x-k8s.io'), 'assets/icons/kubernetes.png');
    expect(bundledGroupIconAsset('notargoproj.io'), isNull);
    expect(bundledGroupIconAsset('example.k8sman.dev'), isNull);
  });

  test('every bundled asset exists', () {
    for (final name in bundledGroupIcons.values.toSet()) {
      expect(File('assets/icons/$name.png').existsSync(), isTrue, reason: name);
    }
  });

  test('monogram is deterministic', () {
    expect(GroupMonogram.letterFor('example.k8sman.dev'), 'E');
    expect(GroupMonogram.letterFor('9.io'), '9');
    expect(GroupMonogram.colorFor('a.io'), GroupMonogram.colorFor('a.io'));
    expect(GroupMonogram.colorFor('a.io'), isNot(GroupMonogram.colorFor('b.io')));
  });

  testWidgets('fallback order: bundled, then API, then monogram', (tester) async {
    final png = (await tester.runAsync(() => solidPng(Colors.teal)))!;
    final api = IconApi(icons: {'traefik.io': png, 'none.example.dev': null}, failing: {'down.example.dev'});
    await pumpIcons(tester, api, ['argoproj.io', 'traefik.io', 'none.example.dev', 'down.example.dev']);

    // 1. Bundled: drawn from assets, the backend isn't asked.
    expect(image('argoproj.io'), findsOneWidget);
    expect(find.descendant(of: image('argoproj.io'), matching: find.byType(Image)), findsOneWidget);
    expect((tester.widget<Image>(find.descendant(of: image('argoproj.io'), matching: find.byType(Image))).image as AssetImage).assetName,
        'assets/icons/argo.png');
    expect(api.calls, isNot(contains('argoproj.io')));

    // 2. Backend image.
    expect(image('traefik.io'), findsOneWidget);
    expect(tester.widget<Image>(find.descendant(of: image('traefik.io'), matching: find.byType(Image))).image, isA<MemoryImage>());

    // 3. No image, or backend error: monogram.
    expect(monogram('none.example.dev'), findsOneWidget);
    expect(monogram('down.example.dev'), findsOneWidget);
    expect(find.text('N'), findsOneWidget);
    expect(api.calls, unorderedEquals(['traefik.io', 'none.example.dev', 'down.example.dev']));
  });

  testWidgets('lookups are memoised; failures are retried', (tester) async {
    final png = (await tester.runAsync(() => solidPng(Colors.orange)))!;
    final api = IconApi(icons: {'traefik.io': png}, failing: {'down.example.dev'});
    await pumpIcons(tester, api, ['traefik.io', 'traefik.io', 'down.example.dev']);
    await pumpIcons(tester, api, ['down.example.dev', 'traefik.io']);
    expect(api.calls.where((c) => c == 'traefik.io'), hasLength(1));
    expect(api.calls.where((c) => c == 'down.example.dev').length, greaterThan(1));
    // A known result is shown on the first frame (no monogram flash).
    await tester.pumpWidget(Provider<ApiClient>.value(
      value: api,
      child: const MaterialApp(home: GroupIcon(group: 'traefik.io')),
    ));
    expect(image('traefik.io'), findsOneWidget);
  });

  testWidgets('without an ApiClient it still renders', (tester) async {
    await pumpIcons(tester, null, ['argoproj.io', 'example.k8sman.dev']);
    expect(image('argoproj.io'), findsOneWidget);
    expect(monogram('example.k8sman.dev'), findsOneWidget);
  });
}
