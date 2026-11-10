import 'module.dart';

/// Add-ons: one-click Helm installs of cluster tools (catalog in
/// lib/addons/addons.dart). Installs go through Helm, so it needs the Helm
/// module. It has no page of its own: it lives in Settings ▸ Add-ons.
class AddonsModule extends AppModule {
  const AddonsModule();

  @override
  String get id => 'addons';

  @override
  String get name => 'Add-ons';

  @override
  String get description => 'Installs common cluster add-ons (metrics-server, Prometheus, Trivy, …) through Helm.';

  @override
  List<String> get requires => const ['helm'];
}
