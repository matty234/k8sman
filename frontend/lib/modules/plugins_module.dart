import '../plugins/plugin_host.dart';
import 'module.dart';

/// The runtime plugin host (docs/PLUGINS.md). Plugins aren't modules: they
/// are folders with a plugin.yaml that the backend loads. Turning this off
/// turns the user's own plugins off; bundled plugins have their own rows in
/// Settings ▸ Integrations. Its row heads Installed's Plugins group, over
/// the user's own plugins (see plugins/plugins_settings.dart); Marketplace
/// installs them. Plugins' sidebar sections and kind icons come from
/// [pluginHost] (see ui/resource_nav.dart), whether this is on or not.
class PluginsModule extends AppModule {
  const PluginsModule();

  @override
  String get id => pluginsModuleId;

  @override
  String get name => 'Plugins';

  @override
  String get description => 'Columns, inspector sections and shell actions for your own kinds, from the Marketplace or plugin.yaml folders.';
}
