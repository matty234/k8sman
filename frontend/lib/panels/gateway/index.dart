import '../panel.dart';
import 'gateway_panel.dart';
import 'gatewayclass_panel.dart';
import 'referencegrant_panel.dart';
import 'route_panel.dart';

/// Panels owned by the "gateway" feature area (Gateway API). Registered by
/// their module in lib/modules.
final List<ResourcePanel> gatewayPanels = [
  const GatewayClassPanel(),
  const GatewayPanel(),
  const RoutePanel(),
  const ReferenceGrantPanel(),
];
