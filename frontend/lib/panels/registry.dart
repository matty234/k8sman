import 'package:flutter/material.dart';

import '../api/models.dart';
import '../modules/modules.dart';
import '../ui/widgets/common.dart';
import 'batch/index.dart';
import 'cluster/index.dart';
import 'config/index.dart';
import 'custom/index.dart';
import 'network/index.dart';
import 'panel.dart';
import 'pod/index.dart';
import 'storage/index.dart';
import 'workloads/index.dart';

export 'panel.dart';

/// The core panels. Integration modules bring their own (see
/// lib/modules).
final List<ResourcePanel> corePanels = [
  ...podPanels,
  ...workloadsPanels,
  ...batchPanels,
  ...networkPanels,
  ...configPanels,
  ...storagePanels,
  ...clusterPanels,
  ...customPanels,
];

final Map<String, ResourcePanel> _byKind = {
  for (final p in corePanels)
    for (final k in p.kinds) k: p,
  for (final m in builtInModules)
    for (final p in m.panels)
      for (final k in p.kinds) k: p,
};

/// The panel for a resource type: a dedicated one, else the fallback.
ResourcePanel panelFor(ResourceType t) => _byKind[t.gk] ?? customFallbackPanel ?? const BasicFallbackPanel();

/// Minimal fallback: spec + status trees and conditions.
class BasicFallbackPanel extends ResourcePanel {
  const BasicFallbackPanel();

  @override
  Set<String> get kinds => const {};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final conds = ctx.status['conditions'];
    final rest = {for (final e in ctx.object.entries) if (!const {'apiVersion', 'kind', 'metadata', 'spec', 'status'}.contains(e.key)) e.key: e.value};
    return [
      if (conds is List && conds.isNotEmpty) DetailSection(title: 'Conditions', icon: Icons.checklist, child: ConditionsTable(conds)),
      if (ctx.spec.isNotEmpty) DetailSection(title: 'Spec', icon: Icons.tune, child: JsonTree(ctx.spec)),
      if (ctx.status.isNotEmpty) DetailSection(title: 'Status', icon: Icons.monitor_heart_outlined, child: JsonTree(ctx.status)),
      if (rest.isNotEmpty) DetailSection(title: 'Data', icon: Icons.data_object, child: JsonTree(rest)),
    ];
  }
}
