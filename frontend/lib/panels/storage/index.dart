import '../panel.dart';
import 'pv_panel.dart';
import 'pvc_panel.dart';
import 'sc_panel.dart';

/// Panels owned by the "storage" feature area. Registered in ../registry.dart.
final List<ResourcePanel> storagePanels = [
  const PvcPanel(),
  const PvPanel(),
  const StorageClassPanel(),
];
