import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/widgets/dialogs.dart';

void main() {
  testWidgets('showTextPrompt disables confirm while the validator objects, then returns the trimmed text', (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => TextButton(
          onPressed: () async => result = await showTextPrompt(context, title: 'Name', validator: (t) => t.isEmpty ? 'required' : null, confirmLabel: 'Go'),
          child: const Text('open'),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Go')).onPressed, isNull);
    await tester.enterText(find.byType(TextField), '  abc ');
    await tester.pump();
    await tester.tap(find.text('Go'));
    await tester.pumpAndSettle();
    expect(result, 'abc');
  });
}
