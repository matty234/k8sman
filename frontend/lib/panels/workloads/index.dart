import '../panel.dart';
import 'daemonset_panel.dart';
import 'deployment_panel.dart';
import 'hpa_panel.dart';
import 'pdb_panel.dart';
import 'replicaset_panel.dart';
import 'statefulset_panel.dart';

/// Panels owned by the "workloads" feature area. Registered in ../registry.dart.
final List<ResourcePanel> workloadsPanels = [
  const DeploymentPanel(),
  const StatefulSetPanel(),
  const DaemonSetPanel(),
  const ReplicaSetPanel(),
  const HpaPanel(),
  const PdbPanel(),
];
