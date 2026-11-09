import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/ui/security/security_api.dart';

import 'security_test.dart' show fixture, pumpSecurity;

void main() {
  testWidgets('ignore a finding from the dialog, it leaves the list, "1 ignored" shows, un-ignore restores it', (tester) async {
    final base = fixture('security');
    await pumpSecurity(tester, base, size: const Size(1000, 1500));

    final first = SecFinding.fromJson((base['findings'] as List).first as Json);
    final tile = find.byKey(ValueKey(first.id));
    expect(tile, findsOneWidget);
    expect(find.textContaining('ignored'), findsNothing);

    // Right-click: the menu offers Ignore…, the dialog the scopes and a summary.
    await tester.tap(tile, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ignore…'));
    await tester.pumpAndSettle();
    expect(find.text('This finding'), findsOneWidget);
    expect(find.text('This check everywhere'), findsOneWidget);
    expect(find.byKey(const ValueKey('ignore-summary')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('ignore-reason')), 'intended');
    await tester.tap(find.byKey(const ValueKey('ignore-confirm')));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey(first.id)), findsNothing);
    expect(find.textContaining('(1 ignored)', findRichText: true), findsOneWidget); // next to the findings figure
    expect(find.text('1 ignored'), findsOneWidget); // the quiet toggle

    // On demand: greyed, with the rule's reason and an Un-ignore button.
    await tester.tap(find.byKey(const ValueKey('toggle-ignored')));
    await tester.pumpAndSettle();
    expect(find.textContaining('"intended"'), findsOneWidget);
    await tester.ensureVisible(find.byKey(ValueKey('unignore-${first.id}')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(ValueKey('unignore-${first.id}')));
    await tester.pumpAndSettle();

    expect(find.byKey(ValueKey(first.id)), findsOneWidget);
    expect(find.textContaining('ignored'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
