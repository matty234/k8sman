import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/detail/owned_section.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/harness.dart';

class _OwnedApi extends FakeApiClient {
  final calls = <String>[];

  @override
  Future<({List<Json> items, bool partial})> owned({required String uid, String? namespace}) async {
    calls.add(uid);
    return switch (uid) {
      'node-1' => (items: [_pod('p1', 'Running'), _pod('p2', 'Pending')], partial: true),
      'p1' => (items: [_pod('child', 'Failed')], partial: false),
      _ => (items: <Json>[], partial: false),
    };
  }

  static Json _pod(String name, String status) =>
      {'group': '', 'version': 'v1', 'kind': 'Pod', 'namespace': 'ns', 'name': name, 'uid': name, 'status': status};
}

void main() {
  testWidgets('Owns lists children by kind and expands one level at a time', (tester) async {
    final api = _OwnedApi();
    final app = AppState(api)..types = testTypes;
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: OwnedSection(uid: 'node-1'))),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Owns'), findsOneWidget);
    expect(find.text('Pod (2)'), findsOneWidget);
    expect(find.text("Some kinds weren't searched"), findsOneWidget);
    expect(find.text('Failed'), findsNothing); // grandchildren are lazy
    expect(api.calls, ['node-1']);

    await tester.tap(find.byIcon(Icons.chevron_right).at(1));
    await tester.pumpAndSettle();
    expect(find.text('Failed'), findsOneWidget);
    expect(api.calls, ['node-1', 'p1']);
  });
}
