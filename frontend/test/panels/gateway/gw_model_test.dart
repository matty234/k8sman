import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/panels/gateway/gw_model.dart';
import 'package:k8sman/panels/gateway/routed_by.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';
import 'gw_support.dart';

RouteObj route(String fixture) => RouteObj(routeKindOf('${gwFixture(fixture)['kind']}')!, gwFixture(fixture));

void main() {
  group('model', () {
    test('ParentRef defaults and status lookup', () {
      final r = route('httproute-cache-admin');
      final p = r.parentRefs.single;
      expect(p.namespace, 'gateway-demo');
      expect(p.kind, 'Gateway');
      expect(p.sectionName, isNull);
      expect(r.statusFor(p)?['controllerName'], 'gateway.envoyproxy.io/gatewayclass-controller');
    });

    test('weights as percentages', () {
      final refs = route('httproute-web-route').rules.first['backendRefs'] as List;
      final b = [for (final x in refs) BackendRef.fromJson(Map<String, dynamic>.from(x as Map), 'demo')];
      expect(weightPercent(b, b[0]), 90);
      expect(weightPercent(b, b[1]), 10);
      expect(weightPercent([b[0]], b[0]), isNull);
    });

    test('grantPermits honours from kind, namespace and to name', () {
      final grant = gwFixture('referencegrant-allow-gateway-demo-to-web');
      const web = BackendRef(namespace: 'demo', name: 'web');
      const redis = BackendRef(namespace: 'demo', name: 'redis');
      expect(anyGrantPermits([grant], fromKind: 'HTTPRoute', fromNamespace: 'gateway-demo', to: web), isTrue);
      expect(anyGrantPermits([grant], fromKind: 'HTTPRoute', fromNamespace: 'gateway-demo', to: redis), isFalse);
      expect(anyGrantPermits([grant], fromKind: 'TCPRoute', fromNamespace: 'gateway-demo', to: web), isFalse);
      expect(anyGrantPermits([grant], fromKind: 'HTTPRoute', fromNamespace: 'other', to: web), isFalse);
      expect(describeGrant(grant).first, 'Allows HTTPRoutes in namespace gateway-demo to reference the Service web in demo.');
    });

    test('hostname intersection', () {
      expect(hostnamesIntersect('*.example.com', ['app.example.com']), isTrue);
      expect(hostnamesIntersect('*.example.com', ['example.com']), isFalse);
      expect(hostnamesIntersect('admin.example.com', ['*.example.com']), isTrue);
      expect(hostnamesIntersect('admin.example.com', ['shop.example.com']), isFalse);
      expect(hostnamesIntersect(null, ['x']), isTrue);
    });

    test('listener refusal reasons', () {
      final gw = gwFixture('gateway-demo-gw');
      final listeners = [for (final l in gw['spec']['listeners'] as List) Map<String, dynamic>.from(l as Map)];
      final sneaky = route('httproute-sneaky-admin');
      expect(listenerRefusal(listeners[2], 'gateway-demo', sneaky), contains('only accepts routes from its own namespace'));
      expect(listenerRefusal(listeners[3], 'gateway-demo', sneaky), contains('only accepts TCPRoutes'));
      expect(
          listenerRefusal(listeners[1], 'gateway-demo', sneaky, nsLabels: {
            'demo': {'kubernetes.io/metadata.name': 'demo'},
          }),
          contains("namespace demo doesn't match"));
      expect(listenerRefusal(listeners[0], 'gateway-demo', sneaky), isNull);
    });

    test('explanations', () {
      final gw = gwFixture('gateway-demo-gw');
      final admin = route('httproute-admin-api');
      final d = explainRouteParent(admin, admin.parentRefs.single, gateway: gw);
      expect(d.single.title, "Listener 'admin-api' not found on Gateway gateway-demo/demo-gw");
      final cache = route('httproute-cache-admin');
      expect(explainRouteParent(cache, cache.parentRefs.single, gateway: gw, grants: [gwFixture('referencegrant-allow-gateway-demo-to-web')]).single.title,
          'backendRef to Service demo/redis requires a ReferenceGrant in demo');
      expect(explainRouteParent(cache, cache.parentRefs.single, gatewayMissing: true).single.title, 'Gateway gateway-demo/demo-gw does not exist');
      expect(explainGateway(gw), isEmpty);
      expect(explainGateway(gwFixture('gateway-pending-gw')).single.title, 'No controller has picked up this Gateway');
      final noAddr = gwFixture('gateway-demo-gw');
      (noAddr['status']['conditions'] as List)[1] = {'type': 'Programmed', 'status': 'False', 'reason': 'AddressNotAssigned', 'message': 'x'};
      expect(explainGateway(noAddr).single.detail, contains('LoadBalancer Service stuck pending'));
    });

    test('filters and matches render readably', () {
      expect(describeFilter({
        'type': 'URLRewrite',
        'urlRewrite': {'hostname': 'new.example.com', 'path': {'type': 'ReplaceFullPath', 'replaceFullPath': '/x'}},
      }), 'Rewrite host new.example.com, path /x');
      expect(describeFilter({'type': 'RequestRedirect', 'requestRedirect': {'scheme': 'https'}}), 'Redirect to scheme https (302)');
      expect(describeFilter({'type': 'ResponseHeaderModifier', 'responseHeaderModifier': {'set': [{'name': 'a', 'value': 'b'}]}}), 'Response headers: set a: b');
      expect(describeMatch({'path': {'type': 'RegularExpression', 'value': '^/v[0-9]'}, 'queryParams': [{'name': 'q', 'value': '1'}]}), ['path ~ ^/v[0-9]', 'query q=1']);
    });

    test('RouteHealth aggregation', () {
      expect(RouteHealth.of(route('httproute-web-route')).label, 'Accepted');
      expect(RouteHealth.of(route('httproute-admin-api')).label, 'Not accepted');
      expect(RouteHealth.of(route('httproute-cache-admin')).label, 'Unresolved refs');
    });
  });

  group('Service "Routed by"', () {
    test('routesTargeting finds backends and mirrors with weights', () {
      final routes = [for (final n in ['httproute-web-route', 'httproute-shop', 'grpcroute-greeter', 'httproute-cache-admin']) route(n)];
      final web = routesTargeting(routes, 'demo', 'web');
      expect(web.map((u) => u.route.name), ['web-route', 'shop', 'greeter']);
      expect(web.first.percent, 90);
      final np = routesTargeting(routes, 'demo', 'web-nodeport');
      expect(np.single.percent, 10);
      expect(routesTargeting(routes, 'other', 'web'), isEmpty);
    });

    testWidgets('Service web lists routes that send it traffic', (tester) async {
      await loadRealFonts();
      final svc = Map<String, dynamic>.from((gwFixtureRaw('services-demo') as List).first as Map);
      final app = await pumpGwPanel(tester, svc);
      await saveScreenshot(tester, 'service-web-routed-by');
      expect(find.text('Routed by'), findsOneWidget);
      expect(find.text('HTTPRoute demo/web-route'), findsOneWidget);
      expect(find.text('90% of its rule'), findsOneWidget);
      expect(find.text('GRPCRoute gateway-demo/greeter'), findsOneWidget);
      await tester.tap(find.text('HTTPRoute gateway-demo/shop'));
      expect(app.detail?.type.kind, 'HTTPRoute');
    });

    testWidgets('hidden when the Gateway API is not served', (tester) async {
      final svc = Map<String, dynamic>.from((gwFixtureRaw('services-demo') as List).first as Map);
      await pumpGwPanel(tester, svc, types: testTypes);
      expect(find.text('Routed by'), findsNothing);
    });

    testWidgets('hidden when no route targets the Service', (tester) async {
      final svc = Map<String, dynamic>.from((gwFixtureRaw('services-demo') as List)[2] as Map); // redis: only a TCPRoute in demo
      await pumpGwPanel(tester, svc, api: gwApi(), size: const Size(560, 1600));
      expect(find.text('TCPRoute demo/redis'), findsOneWidget);
      final none = Map<String, dynamic>.from(svc)..['metadata'] = {...svc['metadata'] as Map, 'name': 'nothing'};
      await pumpGwPanel(tester, none);
      expect(find.text('Routed by'), findsNothing);
    });
  });
}
