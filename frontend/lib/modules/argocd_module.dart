import 'package:flutter/material.dart';

import '../api/client.dart';
import '../panels/argocd/app_diff.dart';
import '../panels/argocd/argocd_settings.dart';
import '../panels/argocd/index.dart';
import 'module.dart';

/// Argo CD: Application, ApplicationSet and AppProject panels (sync,
/// refresh, diffs; see docs/ARGOCD.md) and their sidebar section. The
/// backend adds the argocd-* actions and Application health in the
/// overview. Sign-in to the Argo CD API (for diffs) is the module's
/// settings form.
class ArgoCdModule extends AppModule {
  const ArgoCdModule();

  @override
  String get id => 'argocd';

  @override
  String get name => 'Argo CD';

  @override
  String get description => 'Applications and ApplicationSets: sync status, history and per-resource diffs.';

  @override
  List<ResourcePanel> get panels => argocdPanels;

  @override
  List<NavGroup> get navGroups => const [
        NavGroup('Argo CD', ['argoproj.io/Application', 'argoproj.io/ApplicationSet', 'argoproj.io/AppProject']),
      ];

  /// The CRD is served; argocd-server is found and reachable, or the
  /// module works through kubectl only; and how the API sign-in stands.
  @override
  Future<ModuleStatus> Function(ApiClient api) get detect => (api) async {
        final s = await ArgoDiffApi.of(api).status();
        if (!s.crd) return const ModuleStatus(ModuleState.notInstalled, 'Application CRD not served');
        final server = s.version == null || s.version!.isEmpty ? 'argocd-server' : 'argocd-server ${s.version}';
        if (!s.found) return const ModuleStatus(ModuleState.connected, 'using kubectl only (no argocd-server)');
        if (!s.reachable) return const ModuleStatus(ModuleState.connected, 'using kubectl only (argocd-server not reachable)');
        final who = s.username == null || s.username!.isEmpty ? '' : ' as ${s.username}';
        if (s.auth != 'none' && s.authValid == false) return ModuleStatus(ModuleState.error, '$server · sign-in rejected');
        if (s.auth != 'none' && s.error != null) return ModuleStatus(ModuleState.error, '$server · ${s.error}');
        return ModuleStatus(ModuleState.connected, s.auth == 'none' ? '$server · not signed in (no diffs)' : '$server · signed in$who');
      };

  @override
  WidgetBuilder get settingsBuilder => (_) => const ArgoCdSettingsForm(inline: true);
}
