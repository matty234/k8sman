import 'package:flutter/material.dart';

import '../panels/argoworkflows/index.dart';
import '../panels/argoworkflows/wf_common.dart' show ArgoWFApi;
import '../api/client.dart';
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
  String get description => 'Workflows, templates and cron workflows, with their steps and logs.';

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

  /// Workflows are served; argo-server (retry and memoized resubmit go
  /// through it) is reachable, or the module works on the CRs alone.
  @override
  Future<ModuleStatus> Function(ApiClient api) get detect => (api) async {
        final s = await ArgoWFApi.of(api).fetchStatus();
        if (!s.crd) return const ModuleStatus(ModuleState.notInstalled, 'Workflow CRD not served');
        if (!s.found) return const ModuleStatus(ModuleState.connected, 'Workflows served · no argo-server (retry and memoized resubmit off)');
        final server = s.version == null || s.version!.isEmpty ? 'argo-server' : 'argo-server ${s.version}';
        if (!s.reachable || !s.available) {
          return ModuleStatus(ModuleState.error, '$server · ${s.error ?? 'not usable'}');
        }
        return ModuleStatus(ModuleState.connected, 'Workflows served · $server (${s.auth} auth)');
      };
}
