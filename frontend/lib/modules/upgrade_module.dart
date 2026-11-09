import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../ui/upgrade/upgrade_view.dart';
import 'module.dart';

/// Upgrade readiness: the page that checks what stands between the cluster
/// and a newer Kubernetes minor (removed APIs, version skew, drain blockers,
/// webhooks, CRD storage versions, node health, add-ons). Read-only. The
/// backend's /api/upgrade belongs to the same module.
class UpgradeModule extends AppModule {
  const UpgradeModule();

  static const page = MainView('upgrade');

  @override
  String get id => 'upgrade';

  @override
  String get name => 'Upgrade readiness';

  @override
  String get description => 'What a Kubernetes version upgrade would break: removed APIs, version skew, drain blockers and more.';

  @override
  List<AppPage> get pages => [
        AppPage(
          view: page,
          icon: Icons.upgrade_outlined,
          label: 'Upgrade readiness',
          commands: const ['upgrade', 'readiness'],
          after: MainView.security,
          underMore: true,
          builder: (_) => const UpgradeView(),
        ),
      ];
}
