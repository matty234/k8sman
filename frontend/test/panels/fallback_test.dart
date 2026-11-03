import 'package:flutter_test/flutter_test.dart';

import '../support/harness.dart';

void main() {
  testWidgets('fallback panel renders spec, status and conditions', (tester) async {
    await pumpPanel(tester, {
      'apiVersion': 'example.k8sman.dev/v1alpha1',
      'kind': 'Widget',
      'metadata': {'name': 'sprocket', 'namespace': 'demo'},
      'spec': {'color': 'blue', 'size': 3},
      'status': {
        'phase': 'Ready',
        'conditions': [
          {'type': 'Ready', 'status': 'True', 'reason': 'Reconciled'}
        ],
      },
    });
    expect(find.text('Spec'), findsOneWidget);
    expect(find.text('Conditions'), findsOneWidget);
    expect(find.text('Reconciled'), findsOneWidget);
  });
}
