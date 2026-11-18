import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/resource_nav.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/util/context_display.dart';
import 'package:provider/provider.dart';

void main() {
  testWidgets('cloud context names show structured; long plain names keep their tail; no overflow', (tester) async {
    expect(contextDisplay('arn:aws:eks:eu-west-1:123456789012:cluster/prod-payments'), (primary: 'prod-payments', secondary: 'eu-west-1 · 123456789012'));
    expect(contextDisplay('gke_my-proj_europe-west1_prod'), (primary: 'prod', secondary: 'europe-west1 · my-proj'));
    expect(contextDisplay('gke_a_b_c_d').secondary, isNull);
    expect(contextDisplay('minikube').primary, 'minikube');
    expect(contextDisplays(['arn:aws:eks:r:1:cluster/x', 'arn:aws:eks:r:1:cluster/x']).keys, ['arn:aws:eks:r:1:cluster/x']);

    const eks = 'arn:aws:eks:eu-west-1:123456789012:cluster/prod-payments';
    const long = 'some-very-long-plain-context-name-that-will-not-fit-in-a-sidebar-prod-search';
    final names = [eks, long];
    final app = AppState(ApiClient(base: Uri.parse('http://fake')))
      ..currentContext = eks
      ..contexts = [for (final n in names) ContextInfo(name: n, cluster: 'c', user: 'u')];
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: Align(alignment: Alignment.topLeft, child: SizedBox(width: 420, child: ContextPicker())))),
    ));
    expect(find.text('prod-payments'), findsOneWidget, reason: 'trigger shows the cluster name');
    await tester.tap(find.byIcon(Icons.unfold_more));
    await tester.pumpAndSettle();
    expect(find.text('prod-payments'), findsNWidgets(2), reason: 'trigger and menu row');
    expect(find.text('eu-west-1 · 123456789012'), findsOneWidget);
    // (The test font is wider than the real one, so the long name is cut here.)
    expect(find.byWidgetPredicate((w) => w is Text && (w.data ?? '').startsWith('some') && w.data!.contains('…') && w.data!.endsWith('search')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
