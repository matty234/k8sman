import '../panel.dart';
import 'event_panel.dart';
import 'namespace_panel.dart';
import 'node_panel.dart';
import 'quota_panel.dart';
import 'rbac_panel.dart';

/// Panels owned by the "cluster" feature area. Registered in ../registry.dart.
final List<ResourcePanel> clusterPanels = [
  const NodePanel(),
  const NamespacePanel(),
  const EventPanel(),
  const ResourceQuotaPanel(),
  const LimitRangePanel(),
  const RolePanel(),
  const BindingPanel(),
];
