import '../panels/argocd/index.dart';
import '../state/app_state.dart';
import 'module.dart';

/// Argo CD: Application, ApplicationSet and AppProject panels (sync,
/// refresh, diffs; see docs/ARGOCD.md) and their sidebar section. The
/// backend adds the argocd-* actions and Application health in the
/// overview.
class ArgoCdModule extends AppModule {
  const ArgoCdModule();

  @override
  String get id => 'argocd';

  @override
  String get name => 'Argo CD';

  @override
  List<ResourcePanel> get panels => argocdPanels;

  @override
  List<NavGroup> get navGroups => const [
        NavGroup('Argo CD', ['argoproj.io/Application', 'argoproj.io/ApplicationSet', 'argoproj.io/AppProject']),
      ];

  @override
  bool isAvailable(AppState app) => app.typeFor('argoproj.io', 'Application') != null;
}
