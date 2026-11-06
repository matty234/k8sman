import '../panel.dart';
import 'cron_panel.dart';
import 'template_panel.dart';
import 'workflow_panel.dart';

/// Argo Workflows panels (argoproj.io Workflow, CronWorkflow,
/// WorkflowTemplate, ClusterWorkflowTemplate). Registered by their module in lib/modules.
final List<ResourcePanel> argoWorkflowsPanels = [const WorkflowPanel(), const CronWorkflowPanel(), const WorkflowTemplatePanel()];
