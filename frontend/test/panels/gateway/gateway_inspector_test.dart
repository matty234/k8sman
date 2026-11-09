import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/inspector/inspector.dart';

import 'gw_support.dart';

void main() {
  setUp(SectionMemory.reset);

  testWidgets('Gateway: status header, problem listener first and open, collapsed summaries at 320px', (tester) async {
    await pumpGwPanel(tester, gwFixture('gateway-legacy-gw'), size: const Size(320, 2000));
    expect(tester.takeException(), isNull);

    // Header: accepted and programmed, but a listener has problems.
    expect(find.text('Programmed'), findsOneWidget);
    expect(find.text('1 of 2 listeners has problems'), findsOneWidget);

    // The broken listener comes first and starts open; the healthy one is shut.
    final secure = tester.getTopLeft(find.byKey(const ValueKey('listener-secure')));
    final web = tester.getTopLeft(find.byKey(const ValueKey('listener-web')));
    expect(secure.dy, lessThan(web.dy));
    expect(find.text('Secret not found'), findsOneWidget);
    expect(find.textContaining('Routes from this namespace'), findsOneWidget); // only the open one

    // Conditions collapsed behind a summary.
    expect(find.text('all 2 true'), findsOneWidget);
    expect(find.text('Message'), findsNothing);
  });
}
