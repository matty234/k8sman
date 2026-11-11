import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/panels/panel.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/detail/metadata_section.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';

void main() {
  testWidgets('metadata: values align, system annotations fold, no overflow at 320px', (tester) async {
    final api = FakeApiClient();
    final app = AppState(api)..types = testTypes;
    final ctx = PanelContext(
      object: {
        'apiVersion': 'apps/v1',
        'kind': 'Deployment',
        'metadata': {
          'name': 'web',
          'namespace': 'demo',
          'uid': '0f3c2a9e-1b7d-4c5e-9a8f-2d6b4e1c7a30',
          'resourceVersion': '123456',
          'labels': {'app.kubernetes.io/name': 'web', 'example.com/team': 'payments'},
          'annotations': {
            'note': 'short',
            'example.com/a-very-long-annotation-key-that-does-not-fit-the-column': 'a long value ' * 20,
            'kubectl.kubernetes.io/last-applied-configuration': '{"apiVersion":"apps/v1","kind":"Deployment","metadata":{"name":"web"}}',
            'deployment.kubernetes.io/revision': '7',
          },
        },
      },
      type: testType('apps', 'Deployment'),
      api: api,
      app: app,
    );
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(body: SizedBox(width: 320, child: ListView(children: [MetadataSection(ctx: ctx)]))),
      ),
    ));
    await tester.tap(find.byKey(const ValueKey('pod-section-metadata')));
    await tester.pumpAndSettle();

    // Annotation values start at the same x whatever their key's length.
    final short = tester.getTopLeft(find.text('short')).dx;
    expect(tester.getTopLeft(find.textContaining('a long value')).dx, short);

    // Bookkeeping annotations are folded behind one row at the end.
    expect(find.text('2 system annotations'), findsOneWidget);
    expect(find.text('7'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('metadata-system-annotations')));
    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.text('7')).dx, short);

    // The JSON one opens pretty-printed.
    await tester.tap(find.textContaining('{"apiVersion"'));
    await tester.pumpAndSettle();
    expect(find.textContaining('"kind": "Deployment"', findRichText: true), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
