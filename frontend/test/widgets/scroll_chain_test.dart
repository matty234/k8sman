import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/ui/widgets/common.dart';

void main() {
  testWidgets('dragging a nested list past its end scrolls the outer one', (tester) async {
    final outer = ScrollController();
    await tester.pumpWidget(MaterialApp(
      scrollBehavior: const AppScrollBehavior(),
      home: ListView(controller: outer, children: [
        SizedBox(
          height: 200,
          child: ScrollChain(
            child: ListView(key: const ValueKey('inner'), children: [for (var i = 0; i < 20; i++) SizedBox(height: 20, child: Text('row $i'))]),
          ),
        ),
        const SizedBox(height: 2000),
      ]),
    ));
    // Scroll the inner list to its end, then keep going: the outer moves.
    await tester.drag(find.byKey(const ValueKey('inner')), const Offset(0, -150));
    await tester.pumpAndSettle();
    expect(outer.offset, 0);
    await tester.drag(find.byKey(const ValueKey('inner')), const Offset(0, -400));
    await tester.pumpAndSettle();
    expect(outer.offset, greaterThan(0));
  });
}
