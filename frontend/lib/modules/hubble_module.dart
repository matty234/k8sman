import 'package:flutter/material.dart';

import '../api/client.dart';
import '../hubble/flows_tab.dart';
import '../hubble/hubble_api.dart';
import '../hubble/hubble_settings.dart';
import '../hubble/hubble_view.dart';
import '../state/app_state.dart';
import 'module.dart';
import 'module_nav_gate.dart';
import 'modules.dart' show moduleStatuses;

/// Cilium Hubble: network flows from Hubble Relay. The Hubble page (the
/// traffic map of namespaces and the world, live flows, grouped drops,
/// "Can A reach B?"), a Flows tab in the inspector
/// of pods, services, namespaces and workloads, and per-context relay
/// settings. The backend's /api/hubble and its overview findings belong to
/// the same module. Shown only on clusters where Hubble is found.
class HubbleModule extends AppModule {
  const HubbleModule();

  static const page = MainView('hubble');

  @override
  String get id => 'hubble';

  @override
  String get name => 'Cilium Hubble';

  @override
  List<AppPage> get pages => [
        AppPage(
          view: page,
          icon: Icons.hub_outlined,
          label: 'Hubble',
          commands: const ['hubble', 'flows', 'drops'],
          after: MainView.security,
          navGate: (item) => ModuleNavGate(module: this, child: item),
          navNote: 'Only on clusters with Cilium Hubble',
          builder: (_) => const HubbleView(),
        ),
      ];

  @override
  Future<ModuleStatus> Function(ApiClient api) get detect => (api) async {
        final s = await HubbleApi.of(api).status();
        return switch (s.state) {
          'connected' => ModuleStatus(ModuleState.connected, s.summary),
          'notInstalled' => ModuleStatus(ModuleState.notInstalled, s.message),
          _ => ModuleStatus(ModuleState.error, s.message),
        };
      };

  @override
  List<PanelTab> inspectorTabs(PanelContext ctx) {
    if (!flowKinds.contains(ctx.type.gk)) return const [];
    // Only where Hubble is found (detection runs once per context).
    final s = moduleStatuses.of(this, ctx.api, ctx.app.currentContext);
    if (s == null || s.state == ModuleState.checking || s.state == ModuleState.notInstalled) return const [];
    final tab = flowsTab(ctx);
    return tab == null ? const [] : [tab];
  }

  @override
  WidgetBuilder get settingsBuilder => (_) => const HubbleSettingsForm();
}
