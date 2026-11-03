import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/ui/widgets/common.dart';

void main() {
  testWidgets('MenuSelect opens instantly and selects', (tester) async {
    String value = 'b';
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: StatefulBuilder(
          builder: (context, setState) => Center(
            child: MenuSelect<String>(
              value: value,
              options: const [('a', Text('alpha')), ('b', Text('bravo')), ('c', Text('charlie'))],
              onChanged: (v) => setState(() => value = v),
            ),
          ),
        ),
      ),
    ));
    expect(find.text('bravo'), findsOneWidget);
    await tester.tap(find.text('bravo'));
    await tester.pump(); // one frame: menu fully shown, nothing animating
    expect(find.text('charlie'), findsOneWidget);
    expect(tester.hasRunningAnimations, isFalse, reason: 'menu must not grow/fade in');
    await tester.tap(find.text('charlie'));
    await tester.pump();
    expect(tester.hasRunningAnimations, isFalse, reason: 'menu must not fade out');
    expect(value, 'c');
  });
}
