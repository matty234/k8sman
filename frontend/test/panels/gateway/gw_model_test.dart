import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/panels/gateway/gateway_panel.dart' show Attachment, groupByListener;
import 'package:k8sman/panels/gateway/gw_model.dart';
import 'package:k8sman/panels/gateway/routed_by.dart';

import 'gw_support.dart';

RouteObj route(String fixture) => RouteObj(routeKindOf('${gwFixture(fixture)['kind']}')!, gwFixture(fixture));

void main() {
  group('model', () {
    test('a route reaching one listener through two parentRefs is listed once', () {
      final gw = {
        'metadata': {'name': 'gw', 'namespace': 'demo'},
        'spec': {
          'listeners': [
            {'name': 'https', 'protocol': 'HTTPS', 'port': 443},
          ],
        },
      };
      final r = RouteObj(routeKindOf('HTTPRoute')!, {
        'kind': 'HTTPRoute',
        'metadata': {'name': 'web', 'namespace': 'demo'},
        'spec': {
          'parentRefs': [
            {'name': 'gw'},
            {'name': 'gw', 'port': 443},
          ],
        },
      });
      final grouped = groupByListener(gw, [for (final p in r.parentRefs) Attachment(r, p)]);
      expect(grouped['https'], hasLength(1));
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
      final svc = Map<String, dynamic>.from((gwFixtureRaw('services-demo') as List).first as Map);
      final app = await pumpGwPanel(tester, svc);
      expect(find.text('Routed by'), findsOneWidget);
      expect(find.text('HTTPRoute demo/web-route'), findsOneWidget);
      expect(find.textContaining('90% of its rule'), findsOneWidget);
      expect(find.text('GRPCRoute gateway-demo/greeter'), findsOneWidget);
      await tester.tap(find.text('HTTPRoute gateway-demo/shop'));
      expect(app.detail?.type.kind, 'HTTPRoute');
    });

  });
}
