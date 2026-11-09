import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/inspector/inspector.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/util/k8s.dart';

void main() {
  testWidgets('Callout: bar, title and action; the action wraps under the text at 320 without overflow', (tester) async {
    for (final width in [560.0, 320.0]) {
      tester.view.physicalSize = Size(width, 400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Callout(
                severity: Severity.warn,
                title: 'Suspended: no new jobs will be scheduled',
                body: 'spec.suspend is true. Jobs already running are not affected.',
                action: OutlinedButton(onPressed: () {}, child: const Text('Resume')),
              ),
            ]),
          ),
        ),
      ));
      expect(tester.takeException(), isNull, reason: 'overflow at $width');
      expect(find.byKey(const ValueKey('callout-bar')), findsOneWidget);
      final title = tester.getRect(find.text('Suspended: no new jobs will be scheduled'));
      final action = tester.getRect(find.text('Resume'));
      if (width == 320) {
        expect(action.top, greaterThan(title.bottom), reason: 'wraps under the text');
      } else {
        expect(action.left, greaterThan(title.right), reason: 'at the right');
      }
    }
  });
}
