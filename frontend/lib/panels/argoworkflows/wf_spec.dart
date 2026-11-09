/// Workflow spec widgets shared by the Workflow, CronWorkflow and
/// (Cluster)WorkflowTemplate panels: the templates list and spec summary.
library;

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../batch/batch_common.dart' show formatSeconds;
import 'wf_common.dart';
import '../../ui/widgets/atoms.dart';

const _templateTypes = ['container', 'script', 'dag', 'steps', 'resource', 'suspend', 'http', 'plugin', 'containerSet', 'data'];

/// What a template does: container, script, dag, steps, resource, …
String templateType(Json t) => _templateTypes.firstWhere((k) => t[k] != null, orElse: () => t['templateRef'] != null ? 'ref' : '?');

IconData templateTypeIcon(String type) => switch (type) {
      'container' || 'containerSet' => Icons.inventory_2_outlined,
      'script' => Icons.code,
      'dag' => Icons.account_tree_outlined,
      'steps' => Icons.format_list_numbered,
      'resource' => Icons.description_outlined,
      'suspend' => Icons.pause_circle_outline,
      'http' => Icons.http,
      'plugin' => Icons.extension_outlined,
      'data' => Icons.dataset_outlined,
      _ => Icons.help_outline,
    };

/// A one-line summary of a template's body.
String templateSummary(Json t) {
  final type = templateType(t);
  final body = asMap(t[type]);
  switch (type) {
    case 'container':
    case 'script':
      return '${body['image'] ?? ''}';
    case 'dag':
      final n = asMapList(body['tasks']).length;
      return '$n task${n == 1 ? '' : 's'}';
    case 'steps':
      final groups = t['steps'] as List? ?? const [];
      final n = groups.fold<int>(0, (s, g) => s + (g is List ? g.length : 0));
      return '$n step${n == 1 ? '' : 's'} in ${groups.length} group${groups.length == 1 ? '' : 's'}';
    case 'resource':
      return '${body['action'] ?? ''}';
    case 'suspend':
      return body['duration'] != null ? 'for ${body['duration']}' : 'until resumed';
    case 'http':
      return '${body['method'] ?? 'GET'} ${body['url'] ?? ''}';
    case 'containerSet':
      return '${asMapList(body['containers']).length} containers';
  }
  return '';
}

/// Templates with their type and a summary; the entrypoint first.
class TemplateList extends StatelessWidget {
  final List<Json> templates;
  final String? entrypoint;
  const TemplateList(this.templates, {super.key, this.entrypoint});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (templates.isEmpty) return const InlineMessage('No templates');
    final sorted = [...templates]..sort((a, b) => (a['name'] == entrypoint ? 0 : 1).compareTo(b['name'] == entrypoint ? 0 : 1));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final t in sorted)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Tooltip(message: templateType(t), child: Icon(templateTypeIcon(templateType(t)), size: 15, color: theme.hintColor)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text('${t['name']}', overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12).copyWith(fontWeight: FontWeight.w600))),
                  const SizedBox(width: 6),
                  Text(templateType(t), style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
                  if (t['name'] == entrypoint) ...[
                    const SizedBox(width: 6),
                    StatusBadge('entrypoint', severity: Severity.info),
                  ],
                ]),
                if (templateSummary(t).isNotEmpty)
                  Text(templateSummary(t), maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11, color: theme.hintColor)),
                if (asMapList(dig(t, ['inputs', 'parameters'])).isNotEmpty)
                  Text('in: ${asMapList(dig(t, ['inputs', 'parameters'])).map((p) => p['name']).join(', ')}',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              ]),
            ),
          ]),
        ),
    ]);
  }
}

/// Declared parameters (template / workflow arguments) with defaults,
/// enums and descriptions.
class DeclaredParams extends StatelessWidget {
  final List<Json> params;
  const DeclaredParams(this.params, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (params.isEmpty) return const HintText('No parameters');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final p in params)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 150, child: Text('${p['name']}', style: monoStyle(context, size: 12).copyWith(fontWeight: FontWeight.w600))),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                if (p['enum'] is List)
                  Wrap(spacing: 4, runSpacing: 4, children: [
                    for (final v in p['enum'] as List)
                      Chipish(text: '$v', color: '$v' == '${p['value']}' ? theme.colorScheme.primary : null),
                  ])
                else
                  Text(p['value'] == null ? (p['valueFrom'] != null ? 'from ${asMap(p['valueFrom']).keys.join(', ')}' : 'required') : ('${p['value']}'.isEmpty ? '"" (empty)' : '${p['value']}'),
                      style: monoStyle(context, size: 11.5, color: p['value'] == null ? theme.hintColor : null)),
                if (p['description'] != null) Text('${p['description']}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              ]),
            ),
          ]),
        ),
    ]);
  }
}

/// Key settings of a workflow spec (or a template's / cron's workflowSpec).
class SpecSummary extends StatelessWidget {
  final Json spec;
  final String? namespace;
  const SpecSummary(this.spec, {super.key, this.namespace});

  @override
  Widget build(BuildContext context) {
    String? secs(String k) => spec[k] is num ? formatSeconds((spec[k] as num).toInt()) : null;
    final ttl = asMap(spec['ttlStrategy']);
    final ttlText = [
      if (ttl['secondsAfterCompletion'] is num) 'after completion ${formatSeconds((ttl['secondsAfterCompletion'] as num).toInt())}',
      if (ttl['secondsAfterSuccess'] is num) 'after success ${formatSeconds((ttl['secondsAfterSuccess'] as num).toInt())}',
      if (ttl['secondsAfterFailure'] is num) 'after failure ${formatSeconds((ttl['secondsAfterFailure'] as num).toInt())}',
    ].join(' · ');
    final sa = spec['serviceAccountName'] as String?;
    return KeyValueTable([
      ('Entrypoint', spec['entrypoint'] == null ? null : Text('${spec['entrypoint']}', style: monoStyle(context, size: 12))),
      ('On exit', spec['onExit'] == null ? null : Text('${spec['onExit']}', style: monoStyle(context, size: 12))),
      ('Service account', sa == null ? null : ResourceLink(ObjectRef(kind: 'ServiceAccount', name: sa, namespace: namespace), label: sa)),
      ('Parallelism', spec['parallelism'] == null ? null : '${spec['parallelism']}'),
      ('Deadline', secs('activeDeadlineSeconds')),
      ('TTL', ttlText.isEmpty ? null : ttlText),
      ('Pod GC', dig<String>(spec, ['podGC', 'strategy'])),
      ('Retry', spec['retryStrategy'] == null ? null : 'limit ${dig(spec, ['retryStrategy', 'limit']) ?? '∞'}${dig(spec, ['retryStrategy', 'retryPolicy']) != null ? ', ${dig(spec, ['retryStrategy', 'retryPolicy'])}' : ''}'),
      ('Archive logs', spec['archiveLogs'] == null ? null : '${spec['archiveLogs']}'),
      ('Priority', spec['priority'] == null ? null : '${spec['priority']}'),
      ('Volume claims', asMapList(spec['volumeClaimTemplates']).isEmpty ? null : asMapList(spec['volumeClaimTemplates']).map((v) => dig(v, ['metadata', 'name'])).join(', ')),
      ('Synchronization', spec['synchronization'] == null ? null : _sync(asMap(spec['synchronization']))),
    ], keyWidth: 120);
  }

  String _sync(Json s) {
    final parts = <String>[];
    for (final m in [...asMapList(s['mutexes']), if (s['mutex'] is Map) asMap(s['mutex'])]) {
      parts.add('mutex ${m['name']}');
    }
    for (final m in [...asMapList(s['semaphores']), if (s['semaphore'] is Map) asMap(s['semaphore'])]) {
      parts.add('semaphore ${dig(m, ['configMapKeyRef', 'name']) ?? dig(m, ['database', 'key']) ?? ''}');
    }
    return parts.join(', ');
  }
}

/// Workflows that came from a template or cron, by label (or, for
/// templates, spec.workflowTemplateRef, which kubectl-created runs carry
/// without the label).
bool workflowUsesTemplate(Json wf, String name, {required bool cluster}) {
  final labels = asMap(dig(wf, ['metadata', 'labels']));
  if (labels[cluster ? labelClusterWorkflowTemplate : labelWorkflowTemplate] == name) return true;
  final ref = asMap(dig(wf, ['spec', 'workflowTemplateRef']));
  return ref['name'] == name && (ref['clusterScope'] == true) == cluster;
}
