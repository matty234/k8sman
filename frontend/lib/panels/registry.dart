import 'package:flutter/material.dart';

import '../api/models.dart';
import '../modules/modules.dart';
import '../plugins/plugin_host.dart';
import '../plugins/plugin_panel.dart';
import '../state/app_state.dart';
import '../ui/widgets/common.dart';
import 'admission/admission_panels.dart';
import 'batch/index.dart';
import 'cluster/index.dart';
import 'config/index.dart';
import 'custom/generic_panel.dart' show GenericPanel;
import 'custom/index.dart';
import 'network/index.dart';
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
  ...admissionPanels,
  ...customPanels,
];

/// Kind → its panel, and the module it comes from (null = core).
final Map<String, (ResourcePanel, String?)> _byKind = {
  for (final p in corePanels)
    for (final k in p.kinds) k: (p, null),
  for (final m in builtInModules)
    for (final p in m.panels)
      for (final k in p.kinds) k: (p, m.id),
};

/// The panel for a resource type: a dedicated one, else the fallback. With
/// [app], panels of modules the user turned off are skipped.
///
/// Runtime plugins that add sections or actions to the kind wrap it (see
/// [PluginComposedPanel]).
ResourcePanel panelFor(ResourceType t, [AppState? app]) {
  final e = _byKind[t.gk];
  final on = e != null && (e.$2 == null || app == null || moduleEnabled(e.$2!, app.disabledModules));
  final panel = (on ? e.$1 : null) ?? customFallbackPanel ?? const BasicFallbackPanel();
  if (app == null) return panel;
  pluginHost.attach(app.api);
  if (!pluginHost.contributesTo(t.gk, namespaced: t.namespaced)) return panel;
  if (on) return PluginComposedPanel(panel);
  // Without a dedicated panel, the plugin's sections lead and the generic
  // ones follow, collapsed or left out if the plugin says so
  // (`panel.generic`, docs/PLUGINS.md §4).
  return switch (pluginHost.genericFor(t.gk)) {
    'replace' => PluginComposedPanel(panel, pluginFirst: true, replaceBase: true),
    'collapse' => PluginComposedPanel(panel is GenericPanel ? const GenericPanel(collapsed: true) : panel, pluginFirst: true),
    _ => PluginComposedPanel(panel, pluginFirst: true),
  };
}

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
