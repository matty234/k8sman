import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/resource_nav.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

class _Api extends ApiClient {
  _Api() : super(base: Uri.parse('http://fake'));
  final saved = <(String, String, String)>[];

  @override
  Future<void> putContextAppearance(String context, String icon, String color) async => saved.add((context, icon, color));
}

void main() {
  testWidgets('picking an icon and colour updates the switcher tile and is saved', (tester) async {
    final api = _Api();
    final app = AppState(api)
      ..currentContext = 'prod-eu'
      ..contexts = const [ContextInfo(name: 'prod-eu', cluster: 'c', user: 'u')];
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: Center(child: SizedBox(width: 260, child: ContextPicker())))),
    ));
    expect(find.byKey(const ValueKey('context-badge--')), findsOneWidget, reason: 'default badge');

    await tester.tap(find.text('prod-eu'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Change icon & colour…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('context-icon-rocket')));
    await tester.tap(find.byKey(const ValueKey('context-color-red')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('context-appearance-done')));
    await tester.pumpAndSettle();

    expect(api.saved, [('prod-eu', 'rocket', 'red')]);
    expect(find.byKey(const ValueKey('context-badge-rocket-red')), findsOneWidget);
    expect(find.byIcon(Icons.rocket_launch_outlined), findsOneWidget);
  });
}
