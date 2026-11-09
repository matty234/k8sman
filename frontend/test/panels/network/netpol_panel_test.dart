import 'package:flutter_test/flutter_test.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';
import 'net_support.dart';

void main() {
  testWidgets('netpol: explanation and selected pods', (tester) async {
    await loadRealFonts();
    final app = await pumpPanel(tester, devFixture('netpol-web-allow-frontend'),
        api: FakeApiClient(itemsByResource: {'pods': demoPods()}, itemsFilter: labelSelectorFilter));
    await saveScreenshot(tester, 'network-netpol-web');
    expect(find.text('Applies to pods matching app=web in demo (2 pods).'), findsOneWidget);
    expect(find.text('Restricts ingress'), findsOneWidget);
    expect(find.text('Restricted · 2 allowed'), findsOneWidget);
    expect(find.text('Not restricted'), findsOneWidget);
    expect(find.text('from pods with tier=frontend in this namespace on TCP 8080'), findsOneWidget);
    await tester.tap(find.text('web-6fd47b8fcb-4v4m9'));
    expect(app.detail?.type.kind, 'Pod');
  });

  testWidgets('netpol: default deny all + complex egress', (tester) async {
    await loadRealFonts();
    await pumpPanel(
      tester,
      {
        'apiVersion': 'networking.k8s.io/v1',
        'kind': 'NetworkPolicy',
        'metadata': {'name': 'default-deny', 'namespace': 'demo', 'uid': 'np2'},
        'spec': {
          'podSelector': {},
          'policyTypes': ['Ingress', 'Egress'],
          'egress': [
            {
              'to': [
                {'namespaceSelector': {'matchLabels': {'kubernetes.io/metadata.name': 'kube-system'}}, 'podSelector': {'matchLabels': {'k8s-app': 'kube-dns'}}}
              ],
              'ports': [
                {'protocol': 'UDP', 'port': 53},
                {'protocol': 'TCP', 'port': 53}
              ]
            },
            {
              'to': [
                {'ipBlock': {'cidr': '0.0.0.0/0', 'except': ['169.254.169.254/32', '10.0.0.0/8']}}
              ],
              'ports': [
                {'port': 30000, 'endPort': 32767}
              ]
            }
          ],
        },
      },
      api: FakeApiClient(itemsByResource: {'pods': demoPods()}, itemsFilter: labelSelectorFilter),
    );
    await saveScreenshot(tester, 'network-netpol-deny');
    expect(find.text('Applies to all pods in demo (9 pods).'), findsOneWidget);
    expect(find.text('Default deny ingress'), findsNothing);
    expect(find.text('Restricts ingress and egress'), findsOneWidget);
    expect(find.text('Deny all'), findsOneWidget);
    expect(find.text('to IPs in 0.0.0.0/0 except 169.254.169.254/32, 10.0.0.0/8 on TCP 30000-32767'), findsOneWidget);
  });
}
