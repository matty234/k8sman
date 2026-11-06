import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../ui/helm/helm_view.dart';
import 'module.dart';

/// Helm: the Helm page (releases, values, history diffs, rollback, upgrade,
/// uninstall). The backend's /api/helm/* belongs to the same module.
class HelmModule extends AppModule {
  const HelmModule();

  static const page = MainView('helm');

  @override
  String get id => 'helm';

  @override
  String get name => 'Helm';

  @override
  List<AppPage> get pages => [
        AppPage(
          view: page,
          icon: Icons.sailing_outlined,
          label: 'Helm',
          commands: const ['helm'],
          after: const MainView('metrics'),
          underMore: true,
          builder: (_) => const HelmView(),
        ),
      ];
}

/// Opens the Helm page on release [namespace]/[name], widening the
/// namespace filter if it hides the release.
void showHelmRelease(AppState app, String namespace, String name) {
  if (app.namespace != null && app.namespace != namespace) app.namespace = null;
  app.showView(HelmModule.page, focus: '$namespace/$name');
}
