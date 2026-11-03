import '../panel.dart';
import 'crd_panel.dart';
import 'generic_panel.dart';

/// Panels owned by the "custom" feature area. Registered in ../registry.dart.
final List<ResourcePanel> customPanels = [const CrdPanel()];

/// Panel used for any kind without a dedicated panel (custom resources and
/// uncommon built-ins).
// Kept nullable: registry.dart falls back with `??`.
// ignore: unnecessary_nullable_for_final_variable_declarations
const ResourcePanel? customFallbackPanel = GenericPanel();
