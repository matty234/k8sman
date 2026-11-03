import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/theme.dart';

void main() {
  testWidgets('content that fits does not move when dragged (no overscroll)', (tester) async {
    final controller = ScrollController();
    await tester.pumpWidget(MaterialApp(
      scrollBehavior: const AppScrollBehavior(),
      theme: buildTheme(Brightness.dark).copyWith(platform: TargetPlatform.macOS),
      home: Scaffold(body: ListView(controller: controller, children: const [Text('a'), Text('b')])),
    ));
    final gesture = await tester.startGesture(tester.getCenter(find.text('a')));
    await gesture.moveBy(const Offset(0, -200));
    await tester.pump();
    expect(controller.offset, 0);
    await gesture.moveBy(const Offset(0, 400));
    await tester.pump();
    expect(controller.offset, 0);
    await gesture.up();
    await tester.pumpAndSettle();
    expect(find.byType(GlowingOverscrollIndicator), findsNothing);
    expect(find.byType(StretchingOverscrollIndicator), findsNothing);
  });
}
