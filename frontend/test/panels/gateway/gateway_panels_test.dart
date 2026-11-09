import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/ui/widgets/atoms.dart' show CopyLine;
import 'package:k8sman/ui/inspector/inspector.dart';

import '../../support/screenshot.dart';
import 'gw_support.dart';

/// [o] with every listener, rule and secondary section opened (healthy
/// rows start collapsed).
Json opened(Json o) {
  final uid = o['metadata']['uid'];
  for (var i = 0; i < 10; i++) {
    SectionMemory.set('route-rule:$uid/$i', true);
  }
  for (final l in (o['spec']['listeners'] as List? ?? const [])) {
    SectionMemory.set('gw-listener:$uid/${l['name']}', true);
  }
  for (final s in ['gw-topology', 'gw-infra']) {
    SectionMemory.set(s, true);
  }
  return o;
}

void main() {
  setUp(SectionMemory.reset);

  testWidgets('Gateway demo-gw: healthy, listeners, attached routes, topology', (tester) async {
    await loadRealFonts();
    final app = await pumpGwPanel(tester, opened(gwFixture('gateway-demo-gw')), size: const Size(560, 3000));
    expect(find.text('Programmed'), findsWidgets);
    expect(find.text('10.96.230.213'), findsWidgets);
    // Listener rows.
    expect(find.textContaining('HTTPS :443', findRichText: true), findsWidgets); // the row, its routes' group and the topology
    expect(find.text('*.example.com'), findsOneWidget);
    expect(find.text('Secret demo-tls'), findsWidgets);
    expect(find.textContaining('Routes from namespaces with gateway-access=true'), findsOneWidget);
    expect(find.textContaining('Routes from this namespace (gateway-demo)'), findsOneWidget);
    // Attached routes grouped by listener, with acceptance.
    expect(find.text('HTTPRoute demo/web-route'), findsWidgets);
    expect(find.text('Not accepted'), findsNWidgets(2));
    expect(find.byTooltip('NoMatchingParent: No listeners match this parent ref'), findsOneWidget);
    expect(find.text('No matching listener'), findsOneWidget);
    // Topology reaches backends.
    expect(find.text('demo/web'), findsWidgets);
    expect(find.text('ghost'), findsWidgets);
    expect(find.text('Service not found'), findsWidgets);
    // Infrastructure labels.
    expect(find.text('Infrastructure'), findsOneWidget);
    expect(find.textContaining('platform', findRichText: true), findsWidgets);
    await tester.tap(find.text('eg').first);
    expect(app.detail?.type.kind, 'GatewayClass');
  });

  testWidgets('HTTPRoute web-route: rules, weights, filters, curl', (tester) async {
    await loadRealFonts();
    final app = await pumpGwPanel(tester, opened(gwFixture('httproute-web-route')), size: const Size(560, 2600));
    expect(find.text('Accepted'), findsWidgets);
    expect(find.text('path /api*  ·  header x-canary = true'), findsOneWidget);
    expect(find.text('90%'), findsOneWidget);
    expect(find.text('10%'), findsOneWidget);
    expect(find.text('Request headers: add x-route: api-canary; remove x-debug'), findsOneWidget);
    expect(find.text('Redirect to path /new (301)'), findsOneWidget);
    expect(find.text('Rewrite prefix /'), findsOneWidget);
    expect(find.text('Mirror to web-nodeport:80'), findsOneWidget);
    expect(find.text('request 10s'), findsOneWidget);
    expect(find.text("curl -H 'Host: app.example.com' -H 'x-canary: true' 'http://10.96.230.213/api'"), findsOneWidget);
    expect(find.text("curl -H 'Host: app.example.com' 'http://10.96.230.213/?debug=1'"), findsOneWidget);
    expect(find.byType(CopyLine), findsNWidgets(5));
    await tester.tap(find.text('gateway-demo/demo-gw').first);
    expect(app.detail?.type.kind, 'Gateway');
  });

  testWidgets('HTTPRoute admin-api: NotAccepted, listener not found', (tester) async {
    await loadRealFonts();
    await pumpGwPanel(tester, gwFixture('httproute-admin-api'));
    expect(find.text('Not accepted'), findsWidgets);
    expect(find.text("Listener 'admin-api' not found on Gateway gateway-demo/demo-gw"), findsOneWidget);
    expect(find.text('It has: http, https, admin, redis. Fix sectionName in parentRefs, or add the listener.'), findsOneWidget);
  });

  testWidgets('HTTPRoute cache-admin: RefNotPermitted needs a ReferenceGrant', (tester) async {
    await loadRealFonts();
    await pumpGwPanel(tester, opened(gwFixture('httproute-cache-admin')));
    expect(find.text('Unresolved refs'), findsWidgets);
    expect(find.text('backendRef to Service demo/redis requires a ReferenceGrant in demo'), findsOneWidget);
    expect(find.text('needs ReferenceGrant'), findsWidgets);
    // No address-less example: the route is accepted, so curl is offered.
    expect(find.text("curl -H 'Host: cache.example.com' 'http://10.96.230.213/'"), findsOneWidget);
  });

  testWidgets('GatewayClass eg: controller, parameters, gateways', (tester) async {
    await loadRealFonts();
    await pumpGwPanel(tester, gwFixture('gatewayclass-eg'));
    expect(find.text('gateway.envoyproxy.io/gatewayclass-controller'), findsOneWidget);
    expect(find.text('EnvoyProxy/clusterip-proxy'), findsOneWidget);
    expect(find.text('gateway-demo/demo-gw'), findsOneWidget);
    expect(find.text('demo/legacy-gw'), findsOneWidget);
    expect(find.text('gateway-demo/pending-gw'), findsNothing);
    expect(find.text('Install Envoy Gateway'), findsNothing);
  });

  testWidgets('ReferenceGrant: summary, routes relying on it, uncovered refs', (tester) async {
    await loadRealFonts();
    await pumpGwPanel(tester, gwFixture('referencegrant-allow-gateway-demo-to-web'));
    expect(find.text('Allows HTTPRoutes in namespace gateway-demo to reference the Service web in demo.'), findsOneWidget);
    expect(find.text('Allows GRPCRoutes in namespace gateway-demo to reference the Service web in demo.'), findsOneWidget);
    expect(find.text('HTTPRoute gateway-demo/shop'), findsOneWidget);
    expect(find.text('GRPCRoute gateway-demo/greeter'), findsOneWidget);
    expect(find.text('HTTPRoute gateway-demo/admin-api'), findsOneWidget);
    expect(find.text('NOT COVERED BY THIS GRANT'), findsOneWidget);
    expect(find.text('HTTPRoute gateway-demo/cache-admin'), findsOneWidget);
  });

}
