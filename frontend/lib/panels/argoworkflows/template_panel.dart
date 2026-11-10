import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'cron_panel.dart' show RelatedWorkflows;
import 'wf_actions.dart';
import 'wf_common.dart';
import 'wf_spec.dart';

/// argoproj.io WorkflowTemplate and ClusterWorkflowTemplate: entrypoint,
/// parameters, templates, and the workflows that used it.
class WorkflowTemplatePanel extends ResourcePanel {
  const WorkflowTemplatePanel();

  @override
  Set<String> get kinds => {'argoproj.io/WorkflowTemplate', 'argoproj.io/ClusterWorkflowTemplate'};

  @override
  List<ResourceAction> actions(PanelContext ctx) => templateActions(ctx);

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final cluster = ctx.type.kind == 'ClusterWorkflowTemplate';
    final params = asMapList(dig(ctx.spec, ['arguments', 'parameters']));
    final wfMeta = asMap(ctx.spec['workflowMetadata']);
    return [
      CoreSection('template', DetailSection(
        title: 'Template',
        icon: Icons.description_outlined,
        card: true,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SpecSummary(ctx.spec, namespace: ctx.namespace),
          if (asMap(wfMeta['labels']).isNotEmpty) ...[
            const SizedBox(height: 6),
            KeyValueTable([('Workflow labels', LabelChips(asMap(wfMeta['labels']).map((k, v) => MapEntry(k, '$v'))))], keyWidth: 120),
          ],
        ]),
      )),
      CoreSection('parameters', DetailSection(title: 'Parameters', icon: Icons.tune, child: DeclaredParams(params))),
      CoreSection('templates', DetailSection(
        title: 'Templates',
        icon: Icons.view_list_outlined,
        child: TemplateList(asMapList(ctx.spec['templates']), entrypoint: ctx.spec['entrypoint'] as String?),
      )),
      CoreSection('workflows', DetailSection(
        title: 'Recent workflows',
        icon: Icons.history,
        child: RelatedWorkflows(
          key: ValueKey('tmpl-${ctx.uid}'),
          api: ctx.api,
          // Runs submitted by argo carry the template label; kubectl-created
          // ones only spec.workflowTemplateRef, so filter the list instead.
          fetch: (api) async => [
            for (final w in await api.items(workflowsRef, namespace: cluster ? null : ctx.namespace))
              if (workflowUsesTemplate(w, ctx.name, cluster: cluster)) w,
          ],
          empty: 'No workflows currently reference this template',
        ),
      )),
    ];
  }
}
