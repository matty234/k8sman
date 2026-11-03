import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/resource_table.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/harness.dart';

dynamic _fx(String n) => jsonDecode(File('../dev/fixtures/$n').readAsStringSync());

class _Api extends FakeApiClient {
  _Api() : super(objects: {'deployments.apps/demo/web': Map<String, dynamic>.from(_fx('deploy-web.json'))});
  @override
  Stream<WatchMessage> watch(ResourceRef r, {String? namespace, String? labelSelector, String? fieldSelector, bool includeObject = false}) =>
      Stream.value(WatchMessage(type: 'SNAPSHOT', table: TableData.fromJson(_fx('api-table-deployments.json'))));
}

void main() {
  testWidgets('right-click a row shows resource actions; Open opens the inspector', (tester) async {
    final api = _Api();
    // Real discovery reports verbs; Delete is only offered when allowed.
    const type = ResourceType(group: 'apps', version: 'v1', resource: 'deployments', kind: 'Deployment',
        verbs: ['get', 'list', 'watch', 'create', 'update', 'patch', 'delete']);
    final app = AppState(api)
      ..types = [for (final t in testTypes) t.gk == type.gk ? type : t]
      ..currentContext = 'kind-k8sman-dev';
    tester.view.physicalSize = const Size(1300, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: Scaffold(body: ResourceTableView(type: type))),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 20));

    await tester.tap(find.text('web').first, buttons: kSecondaryButton);
    await tester.pump(); // fetch object
    await tester.pump(); // menu (instant, no animation)
    for (final label in ['Open', 'Scale', 'Restart', 'Copy name', 'Copy namespace/name', 'Copy YAML', 'Delete']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    expect(tester.hasRunningAnimations, isFalse);
    expect(app.detail, isNull, reason: 'right-click must not change selection');

    await tester.tap(find.text('Open'));
    await tester.pump();
    expect(app.detail?.name, 'web');
    expect(app.detail?.type, type);
  });
}
