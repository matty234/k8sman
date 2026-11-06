import '../panels/gateway/index.dart';
import '../state/app_state.dart';
import 'module.dart';

/// Gateway API: Gateway, GatewayClass, route and ReferenceGrant panels and
/// their sidebar section (see docs/GATEWAY_API.md). The backend adds
/// Gateway and route health in the overview.
class GatewayModule extends AppModule {
  const GatewayModule();

  @override
  String get id => 'gateway';

  @override
  String get name => 'Gateway API';

  @override
  List<ResourcePanel> get panels => gatewayPanels;

  @override
  List<NavGroup> get navGroups => const [
        NavGroup(after: 'Network', 'Gateway API', [
          'gateway.networking.k8s.io/GatewayClass',
          'gateway.networking.k8s.io/Gateway',
          'gateway.networking.k8s.io/HTTPRoute',
          'gateway.networking.k8s.io/GRPCRoute',
          'gateway.networking.k8s.io/TLSRoute',
          'gateway.networking.k8s.io/TCPRoute',
          'gateway.networking.k8s.io/UDPRoute',
          'gateway.networking.k8s.io/ReferenceGrant',
        ]),
      ];

  @override
  bool isAvailable(AppState app) => app.typeFor('gateway.networking.k8s.io', 'Gateway') != null;
}
