import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/network/ingress_panel.dart';
import 'package:k8sman/ui/inspector/inspector.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';
import 'net_support.dart';

Json ingressWithExtras() {
  final ing = devFixture('ingress-web');
  ing['spec']['ingressClassName'] = 'nginx';
  ing['metadata']['annotations'] = {
    ...?ing['metadata']['annotations'],
    'nginx.ingress.kubernetes.io/rewrite-target': '/',
    'nginx.ingress.kubernetes.io/proxy-body-size': '8m',
    'cert-manager.io/cluster-issuer': 'letsencrypt',
  };
  (ing['spec']['rules'] as List).add({
    'host': 'api.demo.local',
    'http': {
      'paths': [
        {
          'path': '/v1',
          'pathType': 'Exact',
          'backend': {
            'service': {'name': 'ghost', 'port': {'number': 8080}}
          }
        }
      ]
    }
  });
  ing['status'] = {
    'loadBalancer': {
      'ingress': [
        {'ip': '172.18.0.2'}
      ]
    }
  };
  return ing;
}

void main() {
  setUp(SectionMemory.reset);

  testWidgets('ingress: rules, named port resolution, missing TLS secret', (tester) async {
    await loadRealFonts();
    final app = await pumpPanel(tester, devFixture('ingress-web'),
        api: FakeApiClient(objects: {'services/demo/web': devFixture('svc-web')}));
    expect(find.text('web.demo.local'), findsWidgets);
    expect(find.text(':http (80)'), findsOneWidget);
    expect(find.text(':80'), findsOneWidget);
    expect(find.text('TLS Secret web-tls not found'), findsOneWidget);
    expect(find.text('pending'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pod-section-ing-tls')));
    await tester.pump();
    expect(find.text('Secret not found'), findsNWidgets(2)); // summary and row
    await tester.tap(find.text('web').first);
    expect(app.detail?.type.kind, 'Service');
  });

  test('helpers: urls, tls wildcard, annotations filter', () {
    final spec = Map<String, dynamic>.from(devFixture('ingress-web')['spec']);
    final paths = flattenIngressRules(spec);
    expect(paths.map((p) => p.url(ingressTlsHosts(spec))), ['https://web.demo.local/', 'https://web.demo.local/api']);
    expect(const IngressPath(host: 'a.example.com', path: '/', pathType: 'Prefix', backend: {}).url({'*.example.com'}), 'https://a.example.com/');
    expect(const IngressPath(host: 'a.b.example.com', path: '/', pathType: 'Prefix', backend: {}).url({'*.example.com'}), 'http://a.b.example.com/');
    expect(controllerAnnotations({'kubectl.kubernetes.io/last-applied-configuration': '{}', 'nginx.ingress.kubernetes.io/ssl-redirect': 'true'}).keys,
        ['nginx.ingress.kubernetes.io/ssl-redirect']);
    expect(referencedServices(spec), {'web'});
  });

}
