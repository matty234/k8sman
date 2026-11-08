import 'package:flutter/material.dart';

import '../panels/dra/index.dart';
import 'module.dart';

/// Dynamic Resource Allocation (resource.k8s.io): claims, templates,
/// device classes and slices, with their panels. The sidebar section only
/// lists the kinds the cluster serves, so it is absent without DRA. The Pod
/// and Node panels' DRA sections are part of those core panels. No backend
/// part: the table columns are the backend's built-in defaults.
class DraModule extends AppModule {
  const DraModule();

  @override
  String get id => 'dra';

  @override
  String get name => 'Dynamic Resource Allocation';

  @override
  String get description => 'Resource claims, device classes and slices (resource.k8s.io), with claims on pods and devices on nodes.';

  @override
  List<ResourcePanel> get panels => draPanels;

  @override
  List<NavGroup> get navGroups => const [
        NavGroup(after: 'Storage', 'Dynamic Resources', [
          'resource.k8s.io/ResourceClaim',
          'resource.k8s.io/ResourceClaimTemplate',
          'resource.k8s.io/DeviceClass',
          'resource.k8s.io/ResourceSlice',
          'resource.k8s.io/DeviceTaintRule',
        ]),
      ];

  @override
  Map<String, IconData> get kindIcons => const {
        'resource.k8s.io/ResourceClaim': Icons.memory,
        'resource.k8s.io/ResourceClaimTemplate': Icons.content_copy_outlined,
        'resource.k8s.io/DeviceClass': Icons.category_outlined,
        'resource.k8s.io/ResourceSlice': Icons.developer_board,
        'resource.k8s.io/DeviceTaintRule': Icons.block_outlined,
      };
}
