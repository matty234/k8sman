import '../panel.dart';
import 'endpoints_panel.dart';
import 'ingress_panel.dart';
import 'netpol_panel.dart';
import 'service_panel.dart';

/// Panels owned by the "network" feature area. Registered in ../registry.dart.
final List<ResourcePanel> networkPanels = [
  const ServicePanel(),
  const IngressPanel(),
  const IngressClassPanel(),
  const EndpointSlicePanel(),
  const EndpointsPanel(),
  const NetworkPolicyPanel(),
];
