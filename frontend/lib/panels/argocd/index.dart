import '../panel.dart';
import 'application_panel.dart';
import 'applicationset_panel.dart';
import 'appproject_panel.dart';

/// Argo CD panels (argoproj.io Application, ApplicationSet, AppProject).
/// Registered in ../registry.dart.
final List<ResourcePanel> argocdPanels = [const ApplicationPanel(), const ApplicationSetPanel(), const AppProjectPanel()];
