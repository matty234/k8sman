import 'package:flutter/material.dart';

import '../panels/argoworkflows/index.dart';
import '../state/app_state.dart';
import 'module.dart';

/// Argo Workflows: Workflow, CronWorkflow and template panels (graph,
/// stop, retry, resubmit, submit) and their sidebar section. The backend
/// adds the argowf-* actions and failed Workflows in the overview.
class ArgoWorkflowsModule extends AppModule {
  const ArgoWorkflowsModule();

  @override
  String get id => 'argoworkflows';

  @override
  String get name => 'Argo Workflows';

  @override
  List<ResourcePanel> get panels => argoWorkflowsPanels;

  @override
  List<NavGroup> get navGroups => const [
        NavGroup('Argo Workflows', [
          'argoproj.io/Workflow',
          'argoproj.io/CronWorkflow',
          'argoproj.io/WorkflowTemplate',
          'argoproj.io/ClusterWorkflowTemplate',
          'argoproj.io/WorkflowEventBinding',
          'argoproj.io/WorkflowTaskSet',
          'argoproj.io/WorkflowTaskResult',
          'argoproj.io/WorkflowArtifactGCTask',
        ]),
      ];

  @override
  Map<String, IconData> get kindIcons => const {
        'argoproj.io/Workflow': Icons.account_tree_outlined,
        'argoproj.io/CronWorkflow': Icons.update,
        'argoproj.io/WorkflowTemplate': Icons.description_outlined,
        'argoproj.io/ClusterWorkflowTemplate': Icons.library_books_outlined,
      };

  @override
  bool isAvailable(AppState app) => app.typeFor('argoproj.io', 'Workflow') != null;
}
