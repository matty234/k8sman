import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/resource_nav.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

class _Api extends ApiClient {
  _Api() : super(base: Uri.parse('http://fake'));
  final calls = <(String, bool?)>[];

  @override
  Future<({bool readOnly, String reason})> setContextReadOnly(String context, bool? readOnly) async {
    calls.add((context, readOnly));
    return (readOnly: readOnly == true, reason: readOnly == true ? 'context' : '');
  }
}

void main() {
  testWidgets('a production context starts locked; unlocking asks first, locking does not', (tester) async {
    final api = _Api();
    final app = AppState(api)
      ..currentContext = 'prod-eu'
      ..readOnly = true
      ..readOnlyReason = 'auto'
      ..readOnlyContexts = {'prod-eu': 'auto'};
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: Center(child: ReadOnlyToggle()))),
    ));
    expect(find.byIcon(Icons.lock), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('read-only-toggle')));
    await tester.pumpAndSettle();
    expect(find.text('Allow changes to prod-eu?'), findsOneWidget);
    expect(find.textContaining('looks like production'), findsOneWidget);
    await tester.tap(find.text('Allow Changes'));
    await tester.pumpAndSettle();
    expect(api.calls, [('prod-eu', false)]);
    expect(app.readOnly, isFalse);
    expect(app.readOnlyContexts, isEmpty);
    expect(find.byIcon(Icons.lock_open), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('read-only-toggle')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing, reason: 'locking needs no confirmation');
    expect(api.calls.last, ('prod-eu', true));
    expect(app.readOnly, isTrue);
    expect(app.readOnlyContexts, {'prod-eu': 'context'});
  });
}
