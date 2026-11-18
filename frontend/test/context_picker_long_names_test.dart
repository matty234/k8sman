import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/state/context_appearance.dart';
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
    // A label replaces the primary; the secondary is the cloud one or the real name; duplicate labels stay.
    expect(contextDisplays([eks, 'minikube', 'kind'], labels: {eks: 'Payments', 'minikube': 'Dev', 'kind': 'Dev'}),
        {eks: (primary: 'Payments', secondary: 'eu-west-1 · 123456789012'), 'minikube': (primary: 'Dev', secondary: 'minikube'), 'kind': (primary: 'Dev', secondary: 'kind')});
    final names = [eks, long];
    final app = AppState(ApiClient(base: Uri.parse('http://fake')))
      ..currentContext = eks
      ..contextAppearance = {long: const ContextAppearance(label: 'Search prod')}
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
    expect(find.text('Search prod'), findsOneWidget);
    expect(find.text(long), findsOneWidget, reason: 'the real name is the faint secondary');
    // (The test font is wider than the real one, so the long name is cut here.)
    expect(tester.takeException(), isNull);
  });
}
