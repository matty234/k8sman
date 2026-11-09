import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/panel.dart';
import 'package:k8sman/panels/pod/pod_section.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/detail/metadata_section.dart';
import 'package:k8sman/ui/detail/owner_line.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/harness.dart';

void main() {
  setUp(PodSectionMemory.reset);

  testWidgets('Metadata comes collapsed behind a summary; the owner shows on its own line at the top', (tester) async {
    final pod = jsonDecode(File('../dev/fixtures/pod-web.json').readAsStringSync()) as Json;
    final api = FakeApiClient();
    final app = AppState(api)..types = testTypes;
    final ctx = PanelContext(object: pod, type: testType('', 'Pod'), api: api, app: app);
    tester.view.physicalSize = const Size(320, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(
        theme: buildTheme(Brightness.dark),
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [OverviewTopLine(pod), MetadataSection(ctx: ctx)]),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Owned by '), findsOneWidget);
    await tester.tap(find.text('ReplicaSet/web-6fd47b8fcb'));
    await tester.pump();
    expect(app.detail?.type.kind, 'ReplicaSet');

    expect(find.textContaining(RegExp(r'^3 labels · created \w+ ago$')), findsOneWidget);
    expect(find.byKey(const ValueKey('metadata-labels')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('pod-section-metadata')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('metadata-labels')), findsOneWidget);
    expect(find.textContaining('app=', findRichText: true), findsOneWidget);
    expect(find.text(pod['metadata']['uid'] as String), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
