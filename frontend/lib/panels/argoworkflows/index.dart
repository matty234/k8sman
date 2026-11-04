import '../panel.dart';
import 'cron_panel.dart';
import 'template_panel.dart';
import 'workflow_panel.dart';

/// Argo Workflows panels (argoproj.io Workflow, CronWorkflow,
/// WorkflowTemplate, ClusterWorkflowTemplate). Registered in ../registry.dart.
final List<ResourcePanel> argoWorkflowsPanels = [const WorkflowPanel(), const CronWorkflowPanel(), const WorkflowTemplatePanel()];
