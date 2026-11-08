import '../panel.dart';
import 'claim_panel.dart';
import 'device_panels.dart';
import 'slice_panel.dart';

/// Panels of Dynamic Resource Allocation (resource.k8s.io). Registered by
/// their module in lib/modules. DeviceTaintRule uses the generic panel.
final List<ResourcePanel> draPanels = [
  const ResourceClaimPanel(),
  const ResourceClaimTemplatePanel(),
  const DeviceClassPanel(),
  const ResourceSlicePanel(),
];
