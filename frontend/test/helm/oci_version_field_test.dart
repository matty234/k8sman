import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/helm/oci_version_field.dart';
import 'package:k8sman/ui/theme.dart';

import 'fake_helm_api.dart';

void main() {
  Future<void> pump(WidgetTester tester, FakeHelmApi api) async {
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(body: OciVersionField(key: UniqueKey(), api: api, ref: 'oci://reg.example/charts/app', current: '1.0.0', version: '', onChanged: (_) {})),
    ));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump();
  }

  testWidgets('oci version field: dropdown with newer count, text field with the error on failure', (tester) async {
    await pump(tester, FakeHelmApi());
    expect(find.text('3 newer'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    await pump(tester, FakeHelmApi()..ociError = 'not logged in: run helm registry login reg.example');
    expect(find.byType(TextField), findsOneWidget);
    expect(find.textContaining('helm registry login reg.example'), findsOneWidget);
  });
}
