import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/panels/gateway/gw_widgets.dart' show CopyLine;
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
    await saveScreenshot(tester, 'gateway-demo-gw');
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

  testWidgets('Gateway legacy-gw: missing certificate Secret on a listener', (tester) async {
    await loadRealFonts();
    await pumpGwPanel(tester, gwFixture('gateway-legacy-gw'));
    await saveScreenshot(tester, 'gateway-legacy-gw');
    expect(find.text('1 of 2 listeners has problems'), findsOneWidget);
    expect(find.text('Certificate Secret missing or invalid'), findsWidgets);
    expect(find.text('Secret not found'), findsOneWidget);
  });

  testWidgets('Gateway pending-gw: no controller', (tester) async {
    await loadRealFonts();
    await pumpGwPanel(tester, gwFixture('gateway-pending-gw'));
    await saveScreenshot(tester, 'gateway-pending-gw');
    expect(find.text('No controller has picked up this Gateway'), findsOneWidget);
    expect(find.textContaining('controller example.com/not-installed'), findsOneWidget);
  });

  testWidgets('HTTPRoute web-route: rules, weights, filters, curl', (tester) async {
    await loadRealFonts();
    final app = await pumpGwPanel(tester, opened(gwFixture('httproute-web-route')), size: const Size(560, 2600));
    await saveScreenshot(tester, 'httproute-web-route');
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
    await saveScreenshot(tester, 'httproute-admin-api');
    expect(find.text('Not accepted'), findsWidgets);
    expect(find.text("Listener 'admin-api' not found on Gateway gateway-demo/demo-gw"), findsOneWidget);
    expect(find.text('It has: http, https, admin, redis. Fix sectionName in parentRefs, or add the listener.'), findsOneWidget);
  });

  testWidgets('HTTPRoute sneaky-admin: NotAllowedByListeners explained', (tester) async {
    await loadRealFonts();
    await pumpGwPanel(tester, gwFixture('httproute-sneaky-admin'));
    expect(find.textContaining("Listener 'admin' only accepts routes from its own namespace (gateway-demo); this route is in demo."), findsOneWidget);
  });

  testWidgets('HTTPRoute cache-admin: RefNotPermitted needs a ReferenceGrant', (tester) async {
    await loadRealFonts();
    await pumpGwPanel(tester, opened(gwFixture('httproute-cache-admin')));
    await saveScreenshot(tester, 'httproute-cache-admin');
    expect(find.text('Unresolved refs'), findsWidgets);
    expect(find.text('backendRef to Service demo/redis requires a ReferenceGrant in demo'), findsOneWidget);
    expect(find.text('needs ReferenceGrant'), findsWidgets);
    // No address-less example: the route is accepted, so curl is offered.
    expect(find.text("curl -H 'Host: cache.example.com' 'http://10.96.230.213/'"), findsOneWidget);
  });

  testWidgets('HTTPRoute shop: cross-namespace backend permitted, HTTPS example', (tester) async {
    await pumpGwPanel(tester, opened(gwFixture('httproute-shop')));
    expect(find.text('needs ReferenceGrant'), findsNothing);
    expect(find.text("curl -k --resolve shop.example.com:443:10.96.230.213 'https://shop.example.com/'"), findsOneWidget);
  });

  testWidgets('HTTPRoute ghost: missing Service', (tester) async {
    await pumpGwPanel(tester, opened(gwFixture('httproute-ghost')));
    expect(find.text('Service demo/ghost does not exist'), findsOneWidget);
    expect(find.text('Service not found'), findsWidgets);
  });

  testWidgets('GRPCRoute greeter: method match and grpcurl', (tester) async {
    await loadRealFonts();
    await pumpGwPanel(tester, opened(gwFixture('grpcroute-greeter')));
    await saveScreenshot(tester, 'grpcroute-greeter');
    expect(find.text('helloworld.Greeter/SayHello  ·  header x-tenant = acme'), findsOneWidget);
    expect(find.text("grpcurl -plaintext -authority grpc.example.com -H 'x-tenant: acme' 10.96.230.213:80 helloworld.Greeter/SayHello"), findsOneWidget);
  });

  testWidgets('TCPRoute redis: no hostnames, no example command', (tester) async {
    await pumpGwPanel(tester, gwFixture('tcproute-redis'));
    expect(find.text('Hostnames'), findsNothing);
    expect(find.text('redis'), findsWidgets);
    expect(find.byType(CopyLine), findsNothing);
  });

  testWidgets('GatewayClass eg: controller, parameters, gateways', (tester) async {
    await loadRealFonts();
    await pumpGwPanel(tester, gwFixture('gatewayclass-eg'));
    await saveScreenshot(tester, 'gatewayclass-eg');
    expect(find.text('gateway.envoyproxy.io/gatewayclass-controller'), findsOneWidget);
    expect(find.text('EnvoyProxy/clusterip-proxy'), findsOneWidget);
    expect(find.text('gateway-demo/demo-gw'), findsOneWidget);
    expect(find.text('demo/legacy-gw'), findsOneWidget);
    expect(find.text('gateway-demo/pending-gw'), findsNothing);
    expect(find.text('Install Envoy Gateway'), findsNothing);
  });

  testWidgets('GatewayClass orphan: no controller, offers Envoy Gateway', (tester) async {
    await loadRealFonts();
    await pumpGwPanel(tester, gwFixture('gatewayclass-orphan'));
    await saveScreenshot(tester, 'gatewayclass-orphan');
    expect(find.text('No controller has accepted this class'), findsOneWidget);
    expect(find.text('gateway-demo/pending-gw'), findsOneWidget);
    await tester.tap(find.text('Install Envoy Gateway'));
    await tester.pumpAndSettle();
    expect(find.text('Dry run'), findsOneWidget);
  });

  testWidgets('ReferenceGrant: summary, routes relying on it, uncovered refs', (tester) async {
    await loadRealFonts();
    await pumpGwPanel(tester, gwFixture('referencegrant-allow-gateway-demo-to-web'));
    await saveScreenshot(tester, 'referencegrant');
    expect(find.text('Allows HTTPRoutes in namespace gateway-demo to reference the Service web in demo.'), findsOneWidget);
    expect(find.text('Allows GRPCRoutes in namespace gateway-demo to reference the Service web in demo.'), findsOneWidget);
    expect(find.text('HTTPRoute gateway-demo/shop'), findsOneWidget);
    expect(find.text('GRPCRoute gateway-demo/greeter'), findsOneWidget);
    expect(find.text('HTTPRoute gateway-demo/admin-api'), findsOneWidget);
    expect(find.text('NOT COVERED BY THIS GRANT'), findsOneWidget);
    expect(find.text('HTTPRoute gateway-demo/cache-admin'), findsOneWidget);
  });

  testWidgets('no overflow from 320 to 760px', (tester) async {
    final objects = [
      'gateway-demo-gw',
      'gateway-legacy-gw',
      'gateway-pending-gw',
      'httproute-web-route',
      'httproute-admin-api',
      'httproute-cache-admin',
      'grpcroute-greeter',
      'tcproute-redis',
      'gatewayclass-eg',
      'gatewayclass-orphan',
      'referencegrant-allow-gateway-demo-to-web',
    ];
    final failures = <String>[];
    for (final w in [320.0, 400.0, 480.0, 560.0, 640.0, 760.0]) {
      for (final o in objects) {
        await pumpGwPanel(tester, gwFixture(o), size: Size(w, 4000));
        final e = tester.takeException();
        if (e != null) failures.add('$o at ${w}px: $e');
      }
    }
    expect(failures, isEmpty);
  });
}
