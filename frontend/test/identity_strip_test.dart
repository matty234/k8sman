import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/inspector/identity_strip.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/harness.dart';

void main() {
  testWidgets('identity strip: namespace, age, the naming label value, every label in a list', (tester) async {
    final api = FakeApiClient();
    final app = AppState(api)..types = testTypes;
    final created = DateTime.now().toUtc().subtract(const Duration(days: 5)).toIso8601String();
    final pod = {
      'metadata': {
        'name': 'web-1',
        'namespace': 'shop',
        'uid': 'u1',
        'creationTimestamp': created,
        'labels': {
          'pod-template-hash': '5d8f7c9b6',
          'app': 'web',
          for (var i = 0; i < 12; i++) 'team-$i': 'value-$i',
        },
      },
    };
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(body: SizedBox(width: 360, child: IdentityStrip(type: testType('', 'Pod'), namespace: 'shop', object: pod))),
      ),
    ));

    expect(find.text('shop'), findsOneWidget);
    expect(find.text('5d'), findsOneWidget);
    // Up front: the value of the label that names it; the rest in a list.
    expect(find.text('web'), findsOneWidget);
    expect(find.text('pod-template-hash=5d8f7c9b6', findRichText: true), findsNothing);
    final more = find.byKey(const ValueKey('identity-more'));
    expect(find.descendant(of: more, matching: find.text('+13')), findsOneWidget);

    await tester.tap(more);
    await tester.pumpAndSettle();
    expect(find.text('pod-template-hash=5d8f7c9b6', findRichText: true), findsOneWidget);
    expect(find.text('team-11=value-11', findRichText: true), findsOneWidget);
    expect(find.text('Copy all labels'), findsOneWidget);
  });
}
