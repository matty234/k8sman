import '../panel.dart';

/// Panels owned by the "custom" feature area. Registered in ../registry.dart.
final List<ResourcePanel> customPanels = [];

/// Panel used for any kind without a dedicated panel (custom resources and
/// uncommon built-ins). null → the registry's BasicFallbackPanel.
const ResourcePanel? customFallbackPanel = null;
