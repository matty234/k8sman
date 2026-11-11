import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/app/diagnostics/diagnostics_hooks.dart';
import 'package:k8sman/app/diagnostics/diagnostics_log.dart';

void main() {
  testWidgets('identical overflows group, samples are redacted, release builds show a quiet placeholder', (tester) async {
    final log = DiagnosticsLog()..sensitiveTerms = () => ['payments'];
    FlutterErrorDetails overflow(int px) => FlutterErrorDetails(
          exception: FlutterError('A RenderFlex overflowed by $px pixels on the right.'),
          library: 'rendering library',
          context: ErrorDescription('during layout'),
          stack: StackTrace.fromString('#0 PodRow.build (package:k8sman/ui/inspector/pod_rows.dart:42:7)'),
        );
    log
      ..record(overflow(12))
      ..record(overflow(30));
    expect(log.groups, hasLength(1));
    expect(log.groups.single.count, 2);
    expect(log.groups.single.kind, 'overflow');
    expect(log.groups.single.location, 'package:k8sman/ui/inspector/pod_rows.dart:42');

    final text = redactDiagnostics('GET https://10.0.0.12:6443/api/v1/namespaces/payments/pods/web-7d9c8b6f5-x2k9q failed: dial 10.0.0.12:6443, pod web-7d9c8b6f5-x2k9q in RenderFlex (package:k8sman/ui/a.dart:3)',
        terms: ['payments']);
    expect(text, isNot(contains('10.0.0.12')));
    expect(text, isNot(contains('web-7d9c8b6f5-x2k9q')));
    expect(text, isNot(contains('payments')));
    expect(text, contains('RenderFlex'));
    expect(text, contains('package:k8sman/ui/a.dart:3'));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: diagnosticsErrorWidget(overflow(1), release: true, onReport: () {})),
    ));
    expect(find.text("Couldn't show this section"), findsOneWidget);
    expect(find.text('Report'), findsOneWidget);
    log.dispose();
  });
}
