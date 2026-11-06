import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../ui/addons/addons_view.dart';
import 'module.dart';

/// Add-ons: one-click Helm installs of cluster tools (catalog in
/// lib/addons/addons.dart). Installs go through Helm, so it needs the Helm
/// module.
class AddonsModule extends AppModule {
  const AddonsModule();

  static const page = MainView('addons');

  @override
  String get id => 'addons';

  @override
  String get name => 'Add-ons';

  @override
  List<String> get requires => const ['helm'];

  @override
  List<AppPage> get pages => [
        AppPage(
          view: page,
          icon: Icons.extension_outlined,
          label: 'Add-ons',
          commands: const ['addons', 'add-ons'],
          after: MainView.portForwards,
          underMore: true,
          builder: (_) => const AddonsView(),
        ),
      ];
}
