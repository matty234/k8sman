import '../panel.dart';
import 'configmap_panel.dart';
import 'secret_panel.dart';
import 'serviceaccount_panel.dart';

/// Panels owned by the "config" feature area. Registered in ../registry.dart.
final List<ResourcePanel> configPanels = [
  const ConfigMapPanel(),
  const SecretPanel(),
  const ServiceAccountPanel(),
];
