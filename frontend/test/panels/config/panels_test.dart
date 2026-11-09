import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/ui/inspector/inspector.dart';

import '../../support/harness.dart';

Json fixture(String name) => jsonDecode(File('../dev/fixtures/$name.json').readAsStringSync()) as Json;
Json localFixture(String name) => jsonDecode(File('test/panels/config/fixtures/$name.json').readAsStringSync()) as Json;

FakeApiClient podsApi(List<Json> pods) => FakeApiClient(itemsByResource: {'pods': pods});

Future<void> openSection(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(ValueKey('pod-section-$id')));
  await tester.pump();
}

void main() {
  setUp(SectionMemory.reset);

  testWidgets('ConfigMap: data entries and used-by from the web pod', (tester) async {
    final app = await pumpPanel(tester, fixture('cm-web-config'), api: podsApi([fixture('pod-web')]));
    expect(find.text('APP_MODE'), findsWidgets);
    expect(find.text('nginx.conf'), findsWidgets);
    expect(find.text('pod uses it'), findsOneWidget);
    expect(find.text('1 workload · 1 pod'), findsOneWidget);
    expect(find.textContaining('/etc/nginx/conf.d', findRichText: true), findsOneWidget);
    expect(find.textContaining('env APP_MODE ← key APP_MODE', findRichText: true), findsOneWidget);

    await tester.tap(find.text('web-6fd47b8fcb-4v4m9'));
    await tester.pump();
    expect(app.detail?.type.kind, 'Pod');
    expect(app.detail?.name, 'web-6fd47b8fcb-4v4m9');
  });

  testWidgets('Secret: masked by default, reveal decodes, reveal all', (tester) async {
    await pumpPanel(tester, fixture('secret-web-secret'), api: podsApi([fixture('pod-web')]));
    expect(find.text('hunter2'), findsNothing);
    expect(find.text('s3cr3t-token'), findsNothing);
    expect(find.textContaining('Arbitrary user-defined'), findsOneWidget);
    expect(find.textContaining('env API_TOKEN ← key API_TOKEN', findRichText: true), findsOneWidget);

    await tester.tap(find.byTooltip('Reveal').last); // DB_PASSWORD (sorted second)
    await tester.pump();
    expect(find.text('hunter2'), findsOneWidget);
    expect(find.text('s3cr3t-token'), findsNothing);

    await tester.tap(find.text('Reveal all'));
    await tester.pump();
    expect(find.text('hunter2'), findsOneWidget);
    expect(find.text('s3cr3t-token'), findsOneWidget);

    await tester.tap(find.text('Hide all'));
    await tester.pump();
    expect(find.text('hunter2'), findsNothing);
  });

}
