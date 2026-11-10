import 'package:flutter/widgets.dart';

import '../plugins/plugin_host.dart';
import '../plugins/plugins_settings.dart';
import 'module.dart';

/// The runtime plugin host (docs/PLUGINS.md). Plugins aren't modules: they
/// are folders with a plugin.yaml that the backend loads (in this version
/// only in developer mode). Turning this off turns the user's own plugins
/// off; bundled plugins have their own rows in Settings ▸ Integrations.
/// Plugins' sidebar sections and kind icons come from [pluginHost] (see
/// ui/resource_nav.dart), whether this is on or not.
class PluginsModule extends AppModule {
  const PluginsModule();

  @override
  String get id => pluginsModuleId;

  @override
  String get name => 'Plugins';

  @override
  String get description => 'Columns, inspector sections and shell actions for your own kinds, from plugin.yaml folders.';

  @override
  WidgetBuilder? get settingsBuilder => (context) => const PluginsSettings();
}
