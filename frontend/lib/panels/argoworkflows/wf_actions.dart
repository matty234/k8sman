/// Workflow / CronWorkflow / WorkflowTemplate actions. They run the
/// backend's `argowf-*` actions (see backend/internal/argowf): most patch
/// or create CRs directly, as the argo CLI does; retry and memoized
/// resubmit go through argo-server and are only offered when it is usable.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/models.dart';
import '../../state/log_dock.dart';
import '../../ui/logs/open_logs.dart' show kLogsActionId, kMaxWorkloadLogTabs;
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'wf_common.dart';

// ---------------------------------------------------------------------------
// Workflow
// ---------------------------------------------------------------------------

bool _running(Json wf) => !workflowCompleted(wf);
bool _failed(Json wf) => const {'Failed', 'Error'}.contains(dig<String>(wf, ['status', 'phase']));

/// Header (and right-click) actions for a Workflow.
List<ResourceAction> workflowActions(PanelContext ctx) {
  final wf = ctx.object;
  final name = ctx.name;
  final status = ArgoWFApi.of(ctx.api).cached(ctx.app.currentContext);
  ResourceAction simple(String id, String label, IconData icon, String title, {String? message, bool destructive = false}) => ResourceAction(
        id: id,
        label: label,
        icon: icon,
        destructive: destructive,
        run: (c) => runResourceAction(c, ctx, id, title: title, message: message, destructive: destructive, confirmLabel: label),
      );
  return [
    ResourceAction(id: kLogsActionId, label: 'Logs', icon: Icons.notes, tooltip: 'Open logs of failed or running steps', run: (c) => openWorkflowLogs(c, ctx)),
    if (_running(wf)) ...[
      if (workflowSuspended(wf))
        simple('argowf-resume', 'Resume', Icons.play_arrow, 'Resume workflow $name?',
            message: 'Clears spec.suspend and approves any suspend step that is waiting (argo resume).')
      else
        simple('argowf-suspend', 'Suspend', Icons.pause, 'Suspend workflow $name?',
            message: 'No new steps are started until it is resumed. Running steps continue.'),
      simple('argowf-stop', 'Stop', Icons.stop_circle_outlined, 'Stop workflow $name?',
          message: 'Running steps are stopped; exit handlers still run (argo stop: spec.shutdown=Stop).', destructive: true),
      simple('argowf-terminate', 'Terminate', Icons.cancel_outlined, 'Terminate workflow $name?',
          message: 'Running steps are killed and exit handlers are skipped (argo terminate: spec.shutdown=Terminate).', destructive: true),
    ],
    if (_failed(wf) && (status == null || status.available))
      ResourceAction(id: 'argowf-retry', label: 'Retry', icon: Icons.replay, tooltip: 'Re-run failed steps (argo retry, via argo-server)', run: (c) => showRetryDialog(c, ctx)),
    if (!_running(wf))
      ResourceAction(id: 'argowf-resubmit', label: 'Resubmit', icon: Icons.restart_alt, tooltip: 'Run again as a new workflow (argo resubmit)', run: (c) => showResubmitDialog(c, ctx)),
  ];
}

/// Opens logs (main container) of the workflow's failed pods, else running
/// ones, else the latest, up to [kMaxWorkloadLogTabs].
Future<void> openWorkflowLogs(BuildContext context, PanelContext ctx) async {
  final dock = context.read<LogDock>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  List<Json> pods;
  try {
    pods = await fetchWorkflowPods(ctx.api, ctx.object);
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('Could not list pods: $e')));
    return;
  }
  if (pods.isEmpty) {
    messenger?.showSnackBar(SnackBar(content: Text('${ctx.name} has no pods left (garbage-collected or archived)')));
    return;
  }
  int rank(Json p) => switch ('${dig(p, ['status', 'phase'])}') {
        'Failed' => 0,
        'Running' => 1,
        'Pending' => 3,
        _ => 2,
      };
  pods.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    if (r != 0) return r;
    return '${dig(b, ['metadata', 'creationTimestamp'])}'.compareTo('${dig(a, ['metadata', 'creationTimestamp'])}');
  });
  final take = pods.take(kMaxWorkloadLogTabs).toList();
  for (final (i, p) in take.indexed) {
    final cs = [for (final c in asMapList(dig(p, ['spec', 'containers']))) '${c['name']}'];
    dock.open(p, container: cs.contains('main') ? 'main' : cs.firstOrNull, focus: i == 0);
  }
  if (pods.length > take.length) messenger?.showSnackBar(SnackBar(content: Text('Opened logs for ${take.length} of ${pods.length} pods')));
}

Future<void> showRetryDialog(BuildContext context, PanelContext ctx) async {
  final status = await ArgoWFApi.of(ctx.api).status(ctx.app.currentContext);
  if (!context.mounted) return;
  if (!status.available) {
    showActionError(context, 'Retry needs argo-server, which is not usable here: ${status.error ?? 'unknown error'}');
    return;
  }
  var restartSuccessful = false;
  final ok = await confirmAction(
    context,
    title: 'Retry workflow ${ctx.name}?',
    message: 'Failed steps are reset and run again in this workflow (argo retry). '
        'Their pods are deleted first. Through argo-server (${status.authLabel}).',
    kubeContext: ctx.app.currentContext,
    objectName: ctx.name,
    confirmLabel: 'Retry',
    extra: StatefulBuilder(
      builder: (context, setState) => CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: restartSuccessful,
        onChanged: (v) => setState(() => restartSuccessful = v ?? false),
        title: const Text('Also re-run steps that succeeded'),
      ),
    ),
  );
  if (ok != true || !context.mounted) return;
  await runResourceAction(context, ctx, 'argowf-retry', body: {if (restartSuccessful) 'restartSuccessful': true}, title: 'Retry ${ctx.name}', confirm: false);
}

Future<void> showResubmitDialog(BuildContext context, PanelContext ctx) async {
  final canMemoize = _failed(ctx.object);
  final status = canMemoize ? await ArgoWFApi.of(ctx.api).status(ctx.app.currentContext) : null;
  if (!context.mounted) return;
  var memoized = false;
  final params = asMapList(dig(ctx.spec, ['arguments', 'parameters']));
  final ok = await confirmAction(
    context,
    title: 'Resubmit workflow ${ctx.name}?',
    message: 'Creates a new workflow from the same spec${params.isEmpty ? '' : ' and parameters'} (argo resubmit). This one is kept.',
    kubeContext: ctx.app.currentContext,
    objectName: ctx.name,
    confirmLabel: 'Resubmit',
    extra: canMemoize && status != null && status.available
        ? StatefulBuilder(
            builder: (context, setState) => CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: memoized,
              onChanged: (v) => setState(() => memoized = v ?? false),
              title: const Text('Memoized: reuse the results of steps that succeeded'),
              subtitle: Text('Through argo-server (${status.authLabel})'),
            ),
          )
        : null,
  );
  if (ok != true || !context.mounted) return;
  await runResourceAction(context, ctx, 'argowf-resubmit', body: {if (memoized) 'memoized': true}, title: 'Resubmit ${ctx.name}', confirm: false);
}

// ---------------------------------------------------------------------------
// CronWorkflow
// ---------------------------------------------------------------------------

List<ResourceAction> cronWorkflowActions(PanelContext ctx) {
  final name = ctx.name;
  final suspended = ctx.spec['suspend'] == true;
  return [
    ResourceAction(
      id: 'argowf-submit',
      label: 'Submit now',
      icon: Icons.play_circle_outline,
      tooltip: 'Run the workflow now, outside the schedule',
      run: (c) => runResourceAction(c, ctx, 'argowf-submit',
          title: 'Submit $name now?',
          message: 'Creates a Workflow from the CronWorkflow\'s workflowSpec, labelled and owned like a scheduled run (argo submit --from cronwf/$name).'
              '${suspended ? ' The CronWorkflow stays suspended.' : ''}',
          confirmLabel: 'Submit'),
    ),
    suspended
        ? ResourceAction(
            id: 'unsuspend',
            label: 'Resume',
            icon: Icons.play_arrow,
            run: (c) => runResourceAction(c, ctx, 'unsuspend', title: 'Resume CronWorkflow $name?', message: 'Runs start again at the next scheduled time.', confirmLabel: 'Resume'),
          )
        : ResourceAction(
            id: 'suspend',
            label: 'Suspend',
            icon: Icons.pause,
            run: (c) => runResourceAction(c, ctx, 'suspend',
                title: 'Suspend CronWorkflow $name?', message: 'No new workflows are scheduled. Running ones continue.', confirmLabel: 'Suspend'),
          ),
  ];
}

// ---------------------------------------------------------------------------
// WorkflowTemplate / ClusterWorkflowTemplate
// ---------------------------------------------------------------------------

List<ResourceAction> templateActions(PanelContext ctx) => [
      ResourceAction(id: 'argowf-submit', label: 'Submit…', icon: Icons.play_circle_outline, tooltip: 'Run a workflow from this template', run: (c) => showSubmitDialog(c, ctx)),
    ];

/// What the submit dialog returns.
class SubmitRequest {
  final List<(String, String)> parameters;
  final String? entrypoint;
  final String? namespace;
  const SubmitRequest(this.parameters, {this.entrypoint, this.namespace});

  Json body() => {
        if (parameters.isNotEmpty) 'parameters': [for (final (n, v) in parameters) {'name': n, 'value': v}],
        'entrypoint': ?entrypoint,
        'targetNamespace': ?namespace,
      };
}

Future<void> showSubmitDialog(BuildContext context, PanelContext ctx) async {
  final cluster = ctx.type.kind == 'ClusterWorkflowTemplate';
  final req = await showDialog<SubmitRequest>(
    context: context,
    builder: (_) => SubmitTemplateDialog(template: ctx.object, cluster: cluster, defaultNamespace: ctx.app.namespace ?? 'default'),
  );
  if (req == null || !context.mounted) return;
  final where = cluster ? ' in namespace ${req.namespace}' : '';
  await runResourceAction(
    context,
    ctx,
    'argowf-submit',
    body: req.body(),
    title: 'Submit a workflow from ${ctx.name}$where?',
    message: [
      if (req.parameters.isNotEmpty) req.parameters.map((p) => '${p.$1}=${p.$2}').join(', '),
      if (req.entrypoint != null) 'Entrypoint: ${req.entrypoint}',
    ].join('\n').ifEmpty('No parameters.'),
    confirmLabel: 'Submit',
  );
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}

/// The parameters form, prefilled from defaults; enums are menus.
class SubmitTemplateDialog extends StatefulWidget {
  final Json template;
  final bool cluster;
  final String defaultNamespace;
  const SubmitTemplateDialog({super.key, required this.template, required this.cluster, required this.defaultNamespace});

  @override
  State<SubmitTemplateDialog> createState() => _SubmitTemplateDialogState();
}

class _SubmitTemplateDialogState extends State<SubmitTemplateDialog> {
  late final List<Json> _params = asMapList(dig(widget.template, ['spec', 'arguments', 'parameters']));
  late final Map<String, TextEditingController> _text = {
    for (final p in _params)
      if (p['enum'] is! List) '${p['name']}': TextEditingController(text: p['value'] == null ? '' : '${p['value']}'),
  };
  late final Map<String, String> _enum = {
    for (final p in _params)
      if (p['enum'] is List) '${p['name']}': '${p['value'] ?? (p['enum'] as List).firstOrNull ?? ''}',
  };
  late final TextEditingController _ns = TextEditingController(text: widget.defaultNamespace);
  late String _entry = dig<String>(widget.template, ['spec', 'entrypoint']) ?? '';

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    _ns.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final templates = [for (final t in asMapList(dig(widget.template, ['spec', 'templates']))) '${t['name']}'];
    final defaultEntry = dig<String>(widget.template, ['spec', 'entrypoint']) ?? '';
    return AlertDialog(
      title: Text('Submit ${dig(widget.template, ['metadata', 'name'])}'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (widget.cluster) ...[
              TextField(
                controller: _ns,
                style: monoStyle(context),
                decoration: const InputDecoration(isDense: true, labelText: 'Namespace', helperText: 'Where the Workflow is created'),
              ),
              const SizedBox(height: 12),
            ],
            if (templates.isNotEmpty)
              Row(children: [
                SizedBox(width: 130, child: Text('Entrypoint', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
                Flexible(
                  child: MenuSelect<String>(
                    value: _entry,
                    options: [for (final t in templates) (t, Text(t + (t == defaultEntry ? '  (default)' : ''), style: monoStyle(context, size: 12)))],
                    onChanged: (v) => setState(() => _entry = v),
                  ),
                ),
              ]),
            const SizedBox(height: 8),
            if (_params.isEmpty)
              Text('This template takes no parameters.', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))
            else
              for (final p in _params) _paramField(context, p),
            if (!widget.cluster && dig<String>(widget.template, ['metadata', 'namespace']) != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Created in ${dig(widget.template, ['metadata', 'namespace'])}.', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: widget.cluster && _ns.text.trim().isEmpty
              ? null
              : () => Navigator.pop(
                    context,
                    SubmitRequest(
                      [
                        for (final p in _params)
                          ('${p['name']}', _enum['${p['name']}'] ?? _text['${p['name']}']?.text ?? ''),
                      ],
                      entrypoint: _entry.isNotEmpty && _entry != defaultEntry ? _entry : null,
                      namespace: widget.cluster ? _ns.text.trim() : null,
                    ),
                  ),
          child: const Text('Next'),
        ),
      ],
    );
  }

  Widget _paramField(BuildContext context, Json p) {
    final theme = Theme.of(context);
    final name = '${p['name']}';
    final desc = p['description'] as String?;
    if (p['enum'] is List) {
      final options = [for (final v in p['enum'] as List) '$v'];
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          SizedBox(width: 130, child: Text(name, style: monoStyle(context, size: 12))),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              MenuSelect<String>(
                value: _enum[name],
                options: [for (final o in options) (o, Text(o, style: monoStyle(context, size: 12)))],
                onChanged: (v) => setState(() => _enum[name] = v),
              ),
              if (desc != null) Text(desc, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ]),
          ),
        ]),
      );
    }
    final hasDefault = p['value'] != null;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextField(
        controller: _text[name],
        style: monoStyle(context),
        minLines: 1,
        maxLines: 4,
        decoration: InputDecoration(
          isDense: true,
          labelText: name,
          helperText: desc ?? (hasDefault ? null : 'Required (no default)'),
          helperMaxLines: 2,
        ),
      ),
    );
  }
}

/// Shows argo-server's version and auth mode (or why it can't be used).
class ArgoServerLine extends StatelessWidget {
  final ArgoWFStatus status;
  const ArgoServerLine(this.status, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = status.available ? severityColor(context, Severity.ok) : theme.hintColor;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(status.available ? Icons.link : Icons.link_off, size: 14, color: c),
      const SizedBox(width: 6),
      Expanded(
        child: Text(
          status.available
              ? 'argo-server ${status.version ?? ''} in ${status.serverNamespace ?? '?'} (${status.authLabel})'
              : 'argo-server unavailable${status.error == null ? '' : ': ${status.error}'}',
          style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
        ),
      ),
    ]);
  }
}
