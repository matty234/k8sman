import '../api/backend_http.dart';
import '../api/client.dart';
import '../util/k8s.dart' show asMapList;
import '../panels/gateway/index.dart';
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

  /// The CRDs are served, and which controllers own the GatewayClasses
  /// (`GET /api/gateway/status`).
  @override
  Future<ModuleStatus> Function(ApiClient api) get detect => (api) async {
        final j = jsonObjectBody(await BackendHttp(api, '/api/').get('gateway/status'));
        if (j['crd'] != true) return const ModuleStatus(ModuleState.notInstalled, 'Gateway API CRDs not served');
        final classes = asMapList(j['classes']);
        if (classes.isEmpty) return const ModuleStatus(ModuleState.connected, 'CRDs served · no GatewayClass (no controller installed)');
        final n = classes.length;
        final controllers = {for (final c in classes) if ('${c['controller']}'.isNotEmpty) '${c['controller']}'}.toList()..sort();
        final shown = controllers.take(2).join(', ') + (controllers.length > 2 ? ' +${controllers.length - 2}' : '');
        final msg = 'GatewayClasses: $n · controllers: ${shown.isEmpty ? 'none' : shown}';
        return classes.any((c) => c['accepted'] == true) ? ModuleStatus(ModuleState.connected, msg) : ModuleStatus(ModuleState.error, '$msg · none accepted');
      };
}
