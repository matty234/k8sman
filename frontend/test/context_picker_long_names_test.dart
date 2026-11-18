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
    expect(contextDisplay('arn:aws:eks:eu-west-1:123456789012:cluster/prod-payments'), (primary: 'prod-payments', secondary: 'AWS · eu-west-1 · 123456789012'));
    expect(contextDisplay('gke_my-proj_europe-west1_prod'), (primary: 'prod', secondary: 'GCP · europe-west1 · my-proj'));
    expect(contextDisplay('gke_a_b_c_d').secondary, 'GCP');
    expect(contextDisplay('minikube').primary, 'minikube');
    // Provider from the server or auth plugin when the name says nothing; never guessed.
    expect(contextDisplay('prod', server: 'https://ABC.gr7.eu-west-1.eks.amazonaws.com').secondary, 'AWS · eu-west-1');
    expect(contextDisplay('aks', server: 'https://x.privatelink.uksouth.azmk8s.io:443').secondary, 'Azure · uksouth');
    expect(contextDisplay('web', server: 'https://34.1.2.3', auth: 'gke-gcloud-auth-plugin').secondary, 'GCP');
    expect(contextDisplay('x', auth: 'aws').secondary, 'AWS');
    expect(contextDisplay('kind-dev', server: 'https://127.0.0.1:6443').secondary, isNull);
    expect(contextDisplay('sso', server: 'https://sso.example:6443', auth: 'kubelogin').secondary, isNull);
    expect(contextDisplays([const ContextInfo(name: 'aks', cluster: 'c', user: 'u', server: 'https://x.hcp.uksouth.azmk8s.io')], labels: {'aks': 'Core'})['aks'], (primary: 'Core', secondary: 'Azure · uksouth · aks'));

    const eks = 'arn:aws:eks:eu-west-1:123456789012:cluster/prod-payments';
    const long = 'some-very-long-plain-context-name-that-will-not-fit-in-a-sidebar-prod-search';
    // A label replaces the primary; the secondary is the cloud one or the real name; duplicate labels stay.
    expect(contextDisplays([for (final n in [eks, 'minikube', 'kind']) ContextInfo(name: n, cluster: 'c', user: 'u')], labels: {eks: 'Payments', 'minikube': 'Dev', 'kind': 'Dev'}),
        {eks: (primary: 'Payments', secondary: 'AWS · eu-west-1 · 123456789012'), 'minikube': (primary: 'Dev', secondary: 'minikube'), 'kind': (primary: 'Dev', secondary: 'kind')});
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
    expect(find.text('AWS · eu-west-1 · 123456789012'), findsOneWidget);
    expect(find.text('Search prod'), findsOneWidget);
    expect(find.text(long), findsOneWidget, reason: 'the real name is the faint secondary');
    // (The test font is wider than the real one, so the long name is cut here.)
    expect(tester.takeException(), isNull);
  });
}
