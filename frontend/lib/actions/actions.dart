/// Cluster-mutating actions (scale, restart, rollback, …) with consistent
/// confirmation, context safety and feedback. Panels should use the widgets
/// and [runResourceAction] here rather than calling the API directly.
library;

import 'dart:convert';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../panels/panel.dart';
import '../state/app_state.dart';
import '../ui/editor/resource_editor_screen.dart';
import '../ui/nodes/drain_dialog.dart';
import '../ui/theme.dart';
import '../util/k8s.dart';

/// Contexts that are obviously local/disposable get lighter confirmation.
bool isLocalContext(String ctx) {
  final c = ctx.toLowerCase();
  return c.startsWith('kind-') ||
      c.startsWith('k3d-') ||
      c == 'minikube' ||
      c == 'docker-desktop' ||
      c == 'rancher-desktop' ||
      c.startsWith('orbstack') ||
      c.contains('localhost');
}

/// A button-able action for the sidebar header or a panel.
class ResourceAction {
  final String id;
  final String label;
  final IconData icon;
  final bool destructive;
  final String? tooltip;
  final Future<void> Function(BuildContext context) run;
  const ResourceAction({required this.id, required this.label, required this.icon, required this.run, this.destructive = false, this.tooltip});
}

/// Runs a backend action against the object in [ctx]:
/// confirm (unless [confirm] is false) → call → snackbar with result/error.
/// Returns the result, or null if cancelled/failed.
///
/// Confirmation always names the kube context, with a prominent warning on
/// non-local contexts.
Future<ActionResult?> runResourceAction(
  BuildContext context,
  PanelContext ctx,
  String action, {
  Json body = const {},
  required String title,
  String? message,
  bool destructive = false,
  bool confirm = true,
  String? confirmLabel,
}) async {
  final kubeContext = ctx.app.currentContext;
  if (confirm) {
    final ok = await confirmAction(
      context,
      title: title,
      message: message,
      kubeContext: kubeContext,
      objectName: ctx.name,
      destructive: destructive,
      confirmLabel: confirmLabel,
    );
    if (ok != true || !context.mounted) return null;
  }
  try {
    final res = await ctx.api.runAction(ctx.type.ref, namespace: ctx.namespace, name: ctx.name, action: action, body: body);
    if (context.mounted) {
      final created = res.created;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(res.message),
        persist: false,
        action: created == null ? null : SnackBarAction(label: 'Open', onPressed: () => ctx.app.openRef(created)),
      ));
    }
    return res;
  } on ApiException catch (e) {
    if (context.mounted) showActionError(context, e.message);
  } catch (e) {
    if (context.mounted) showActionError(context, '$e');
  }
  return null;
}

void showActionError(BuildContext context, String message) {
  final theme = Theme.of(context);
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
    backgroundColor: theme.colorScheme.errorContainer,
    duration: const Duration(seconds: 6),
    content: Text(message, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
  ));
}

/// The confirm button's label and whether it uses the destructive style.
class ConfirmLook {
  final String label;
  final bool destructive;
  const ConfirmLook(this.label, this.destructive);
}

/// Confirmation dialog shared by all mutations.
Future<bool?> confirmAction(
  BuildContext context, {
  required String title,
  String? message,
  required String kubeContext,

  /// Kept for API compatibility (no longer typed in to confirm).
  required String objectName,
  bool destructive = false,
  String? confirmLabel,
  Widget? extra,
  double width = 460,

  /// Changes the confirm button's label and style while the dialog is open
  /// (the delete dialog's "Force delete").
  ValueListenable<ConfirmLook>? confirmLook,
}) {
  final local = isLocalContext(kubeContext);
  return showDialog<bool>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      final warn = severityColor(context, Severity.warn);
      return AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: width,
          child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (message != null) ...[Text(message), const SizedBox(height: 12)],
            ?extra,
            if (local)
              Row(children: [
                Icon(Icons.computer, size: 15, color: theme.hintColor),
                const SizedBox(width: 6),
                Text('Context: ', style: theme.textTheme.bodySmall),
                Flexible(child: Text(kubeContext, style: monoStyle(context, size: 12))),
              ])
            else
              // Non-local clusters get a clear, unmissable note instead of a
              // typed confirmation.
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                decoration: BoxDecoration(
                  color: warn.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: warn.withValues(alpha: 0.45)),
                ),
                child: Row(children: [
                  Icon(Icons.warning_amber_rounded, size: 16, color: warn),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text.rich(
                      TextSpan(children: [
                        const TextSpan(text: 'You are changing '),
                        TextSpan(text: kubeContext, style: monoStyle(context, size: 12, color: warn).copyWith(fontWeight: FontWeight.w600)),
                        const TextSpan(text: ', not a local cluster.'),
                      ]),
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ]),
              ),
          ])),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          ValueListenableBuilder<ConfirmLook>(
            valueListenable: confirmLook ?? ValueNotifier(ConfirmLook(confirmLabel ?? 'Confirm', destructive)),
            builder: (context, look, _) => FilledButton(
              autofocus: true, // Return confirms, Esc cancels.
              style: look.destructive ? destructiveButtonStyle(context) : null,
              onPressed: () => Navigator.pop(context, true),
              child: Text(look.label),
            ),
          ),
        ],
      );
    },
  );
}

// ---------------------------------------------------------------------------
// Drop-in widgets for panels
// ---------------------------------------------------------------------------

/// Compact "− N +" replica control with an Apply button. Use beside replica
/// status for Deployments / StatefulSets / ReplicaSets / scalable CRs.
class ScaleControl extends StatefulWidget {
  final PanelContext ctx;
  const ScaleControl(this.ctx, {super.key});

  @override
  State<ScaleControl> createState() => _ScaleControlState();
}

class _ScaleControlState extends State<ScaleControl> {
  late int _target = _current;
  bool _busy = false;

  int get _current => (dig<num>(widget.ctx.object, ['spec', 'replicas']) ?? 1).toInt();

  @override
  void didUpdateWidget(covariant ScaleControl old) {
    super.didUpdateWidget(old);
    final prev = (dig<num>(old.ctx.object, ['spec', 'replicas']) ?? 1).toInt();
    if (prev != _current && _target == prev) _target = _current; // follow external changes
  }

  Future<void> _apply() async {
    setState(() => _busy = true);
    await runResourceAction(context, widget.ctx, 'scale',
        body: {'replicas': _target},
        title: 'Scale ${widget.ctx.type.kind} ${widget.ctx.name}',
        message: 'Change replicas from $_current to $_target.${_target == 0 ? ' All pods will be terminated.' : ''}',
        destructive: _target == 0,
        confirmLabel: 'Scale');
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dirty = _target != _current;
    return Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(
        tooltip: 'Fewer replicas',
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        icon: const Icon(Icons.remove),
        onPressed: _busy || _target <= 0 ? null : () => setState(() => _target--),
      ),
      SizedBox(
        width: 32,
        child: Text('$_target',
            textAlign: TextAlign.center,
            style: theme.textTheme.titleSmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], color: dirty ? theme.colorScheme.primary : null)),
      ),
      IconButton(
        tooltip: 'More replicas',
        visualDensity: VisualDensity.compact,
        iconSize: 16,
        icon: const Icon(Icons.add),
        onPressed: _busy ? null : () => setState(() => _target++),
      ),
      if (dirty) ...[
        const SizedBox(width: 4),
        FilledButton.tonal(
          style: FilledButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
          onPressed: _busy ? null : _apply,
          child: Text(_busy ? 'Scaling…' : 'Scale to $_target'),
        ),
        TextButton(onPressed: _busy ? null : () => setState(() => _target = _current), child: const Text('Reset')),
      ],
    ]);
  }
}

/// A small button that runs one action with confirmation. Examples:
/// ```dart
/// ActionButton(ctx, action: 'restart', label: 'Restart', icon: Icons.restart_alt,
///     title: 'Restart deployment web?', message: 'Pods are replaced via a rolling update.')
/// ActionButton(ctx, action: 'rollback', body: {'revision': 3}, label: 'Roll back', ...)
/// ```
class ActionButton extends StatefulWidget {
  final PanelContext ctx;
  final String action;
  final String label;
  final IconData icon;
  final Json body;
  final String title;
  final String? message;
  final bool destructive;
  final bool dense;

  /// Called with the result after a successful run (e.g. to refresh a list).
  final void Function(ActionResult result)? onResult;
  const ActionButton(
    this.ctx, {
    super.key,
    required this.action,
    required this.label,
    required this.icon,
    required this.title,
    this.body = const {},
    this.message,
    this.destructive = false,
    this.dense = true,
    this.onResult,
  });

  @override
  State<ActionButton> createState() => _ActionButtonState();
}

class _ActionButtonState extends State<ActionButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = widget.destructive ? theme.colorScheme.error : null;
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        visualDensity: widget.dense ? VisualDensity.compact : null,
        foregroundColor: color,
        side: color != null ? BorderSide(color: color.withValues(alpha: 0.5)) : null,
        padding: const EdgeInsets.symmetric(horizontal: 10),
      ),
      icon: _busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(widget.icon, size: 16),
      label: Text(widget.label),
      onPressed: _busy
          ? null
          : () async {
              // Confirm first so the spinner only shows while the request runs.
              final ok = await confirmAction(context,
                  title: widget.title,
                  message: widget.message,
                  kubeContext: widget.ctx.app.currentContext,
                  objectName: widget.ctx.name,
                  destructive: widget.destructive,
                  confirmLabel: widget.label);
              if (ok != true || !context.mounted) return;
              setState(() => _busy = true);
              final res = await runResourceAction(context, widget.ctx, widget.action,
                  body: widget.body, title: widget.title, destructive: widget.destructive, confirm: false);
              if (mounted) setState(() => _busy = false);
              if (res != null) widget.onResult?.call(res);
            },
    );
  }
}

// ---------------------------------------------------------------------------
// Standard actions per kind (rendered in the sidebar header)
// ---------------------------------------------------------------------------

const _bespokeScale = {'apps/Deployment', 'apps/StatefulSet', 'apps/ReplicaSet'};

/// Built-in header actions for an object, based on its kind and verbs.
/// Panels can add more via [ResourcePanel.actions].
List<ResourceAction> standardActions(PanelContext ctx) {
  final gk = ctx.type.gk;
  final kind = ctx.type.kind;
  final name = ctx.name;
  final out = <ResourceAction>[];
  ResourceAction simple(String id, String label, IconData icon, String title, {String? message, bool destructive = false, Json body = const {}}) =>
      ResourceAction(
        id: id,
        label: label,
        icon: icon,
        destructive: destructive,
        run: (c) => runResourceAction(c, ctx, id, title: title, message: message, destructive: destructive, body: body, confirmLabel: label),
      );

  if (_bespokeScale.contains(gk)) {
    out.add(ResourceAction(id: 'scale', label: 'Scale', icon: Icons.unfold_more, run: (c) => showScaleDialog(c, ctx)));
  }
  if (const {'apps/Deployment', 'apps/StatefulSet', 'apps/DaemonSet'}.contains(gk)) {
    out.add(simple('restart', 'Restart', Icons.restart_alt, 'Restart $kind $name?',
        message: 'Pods are replaced gradually using the rollout strategy (same as kubectl rollout restart).'));
  }
  if (gk == 'apps/Deployment') {
    final paused = ctx.spec['paused'] == true;
    out.add(paused
        ? simple('resume', 'Resume rollout', Icons.play_arrow, 'Resume rollout of $name?')
        : simple('pause', 'Pause rollout', Icons.pause, 'Pause rollout of $name?', message: 'Template changes will not roll out until resumed.'));
    out.add(simple('rollback', 'Roll back', Icons.history, 'Roll back $name to the previous revision?',
        message: 'The previous ReplicaSet\'s pod template is restored (kubectl rollout undo).', destructive: true));
  }
  if (gk == 'batch/CronJob') {
    out.add(simple('trigger', 'Run now', Icons.play_circle_outline, 'Run CronJob $name now?', message: 'Creates a Job from the job template.'));
  }
  if (gk == 'batch/CronJob' || gk == 'batch/Job') {
    final suspended = ctx.spec['suspend'] == true;
    out.add(suspended
        ? simple('unsuspend', 'Resume', Icons.play_arrow, 'Resume $kind $name?')
        : simple('suspend', 'Suspend', Icons.pause, 'Suspend $kind $name?',
            message: gk == 'batch/Job' ? 'Active pods are terminated until resumed.' : 'No new jobs will be scheduled.'));
  }
  if (gk == '/Node') {
    final cordoned = ctx.spec['unschedulable'] == true;
    out.add(cordoned
        ? simple('uncordon', 'Uncordon', Icons.lock_open, 'Uncordon node $name?')
        : simple('cordon', 'Cordon', Icons.block, 'Cordon node $name?', message: 'New pods will not be scheduled here. Existing pods keep running.', destructive: true));
    out.add(ResourceAction(id: 'drain', label: 'Drain…', icon: Icons.move_down, destructive: true, run: (c) => showDrainDialog(c, name)));
  }
  if (gk == '/Pod' && ownerRefs(ctx.object).isNotEmpty) {
    out.add(simple('delete', 'Restart pod', Icons.refresh, 'Delete pod $name so its controller recreates it?', destructive: true));
  }
  if (ctx.type.hasSubresource('status') && ctx.type.can('update')) {
    out.add(ResourceAction(
      id: 'edit-status',
      label: 'Edit status…',
      icon: Icons.edit_note,
      tooltip: 'Edit .status through the status subresource',
      run: (c) => openResourceEditor(c, DetailTarget(type: ctx.type, name: name, namespace: ctx.namespace), statusMode: true),
    ));
  }
  // Deployments, StatefulSets and ReplicaSets have the replica stepper above.
  if (ctx.type.hasSubresource('scale') && !_bespokeScale.contains(gk)) {
    out.add(ResourceAction(id: 'scale-sub', label: 'Scale…', icon: Icons.unfold_more, run: (c) => showSubresourceScaleDialog(c, ctx)));
  }
  if (ctx.type.can('delete')) {
    out.add(ResourceAction(id: 'delete', label: 'Delete', icon: Icons.delete_outline, destructive: true, run: (c) => showDeleteDialog(c, ctx)));
  }
  return out;
}

/// What the delete dialog's Advanced section has ticked.
class DeleteChoice {
  final bool force;
  final bool removeFinalizers;
  const DeleteChoice({this.force = false, this.removeFinalizers = false});
}

/// The delete dialog's collapsed "Advanced" disclosure: force (pods only) and,
/// for an object already terminating with [finalizers], removing them.
class DeleteAdvanced extends StatelessWidget {
  final ValueNotifier<DeleteChoice> choice;
  final bool offerForce;
  final List<String> finalizers;
  const DeleteAdvanced({super.key, required this.choice, this.offerForce = false, this.finalizers = const []});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warn = severityColor(context, Severity.warn);
    return Theme(
      data: theme.copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        key: const Key('delete-advanced'),
        tilePadding: EdgeInsets.zero,
        childrenPadding: EdgeInsets.zero,
        dense: true,
        title: Text('Advanced', style: theme.textTheme.bodyMedium),
        children: [
          ValueListenableBuilder<DeleteChoice>(
            valueListenable: choice,
            builder: (context, c, _) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (offerForce)
                CheckboxListTile(
                  key: const Key('delete-force'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: c.force,
                  onChanged: (v) => choice.value = DeleteChoice(force: v ?? false, removeFinalizers: c.removeFinalizers),
                  title: const Text('Force (no grace period)'),
                  subtitle: const Text('Removes the pod from the API immediately. The container may keep running on its node until the kubelet notices.'),
                ),
              if (finalizers.isNotEmpty)
                CheckboxListTile(
                  key: const Key('delete-finalizers'),
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: c.removeFinalizers,
                  onChanged: (v) => choice.value = DeleteChoice(force: c.force, removeFinalizers: v ?? false),
                  title: const Text('Remove finalizers'),
                  subtitle: Text(c.removeFinalizers
                      ? 'This clears ${finalizers.join(', ')} without letting what owns them finish its cleanup. '
                          'The resources they protect (for example cloud volumes or load balancers) may be left behind.'
                      : 'Clears the finalizers holding this object: ${finalizers.join(', ')}.'),
                  secondary: c.removeFinalizers ? Icon(Icons.warning_amber_rounded, size: 18, color: warn) : null,
                ),
            ]),
          ),
        ],
      ),
    );
  }
}

/// Delete confirmation. An Advanced section (collapsed, nothing ticked)
/// offers force delete for pods and, for an object already being deleted that
/// is held by finalizers, removing them.
Future<void> showDeleteDialog(BuildContext context, PanelContext ctx) async {
  if (ctx.app.readOnly) return;
  final kind = ctx.type.kind, name = ctx.name;
  final meta = asMap(ctx.object['metadata']);
  final terminating = meta['deletionTimestamp'] != null;
  final finalizers = [for (final f in (meta['finalizers'] as List? ?? const [])) '$f'];
  final isPod = ctx.type.gk == '/Pod';
  final canFinalize = terminating && finalizers.isNotEmpty && ctx.type.can('patch');
  final choice = ValueNotifier(const DeleteChoice());
  final look = ValueNotifier(const ConfirmLook('Delete', true));
  choice.addListener(() {
    final c = choice.value;
    look.value = c.removeFinalizers
        ? const ConfirmLook('Remove finalizers', true)
        : c.force
            ? const ConfirmLook('Force delete', true)
            : const ConfirmLook('Delete', true);
  });
  final String message;
  if (!terminating) {
    message = 'Dependents are garbage-collected in the background.';
  } else if (finalizers.isNotEmpty) {
    message = '$kind $name is already being deleted. It is waiting on ${finalizers.join(', ')}, so deleting it again changes nothing.'
        '${canFinalize ? ' Open Advanced to remove the finalizers if whatever owns them is gone.' : ''}';
  } else if (isPod) {
    message = 'Pod $name is already being deleted. Open Advanced to force it out of the API now.';
  } else {
    message = '$kind $name is already being deleted.';
  }
  final ok = await confirmAction(
    context,
    title: terminating ? '$kind $name is already terminating' : 'Delete $kind $name?',
    message: message,
    kubeContext: ctx.app.currentContext,
    objectName: name,
    destructive: true,
    confirmLabel: 'Delete',
    confirmLook: look,
    extra: isPod || canFinalize ? DeleteAdvanced(choice: choice, offerForce: isPod, finalizers: canFinalize ? finalizers : const []) : null,
  );
  final picked = choice.value;
  if (ok != true || !context.mounted) return;
  if (picked.removeFinalizers) {
    await runResourceAction(context, ctx, 'finalize', confirm: false, title: 'Remove finalizers');
  } else {
    await runResourceAction(context, ctx, 'delete', confirm: false, title: 'Delete', body: picked.force ? const {'gracePeriodSeconds': 0} : const {});
  }
}

Future<void> showScaleDialog(BuildContext context, PanelContext ctx) async {
  final current = (dig<num>(ctx.object, ['spec', 'replicas']) ?? 1).toInt();
  final controller = TextEditingController(text: '$current');
  final target = await showDialog<int>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Scale ${ctx.type.kind} ${ctx.name}'),
      content: SizedBox(
        width: 320,
        child: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: InputDecoration(labelText: 'Replicas (currently $current)'),
          onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, int.tryParse(controller.text)), child: const Text('Next')),
      ],
    ),
  );
  if (target == null || target < 0 || target == current || !context.mounted) return;
  await runResourceAction(context, ctx, 'scale',
      body: {'replicas': target},
      title: 'Scale ${ctx.name} to $target?',
      message: 'Replicas $current → $target.${target == 0 ? ' All pods will be terminated.' : ''}',
      destructive: target == 0,
      confirmLabel: 'Scale');
}

/// Scale dialog for kinds that only expose the generic `scale` subresource:
/// reads the autoscaling/v1 Scale, then PUTs it back with the new replicas.
Future<void> showSubresourceScaleDialog(BuildContext context, PanelContext ctx) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  final ref = ctx.type.ref, ns = ctx.namespace, name = ctx.name;
  final Json scale;
  try {
    scale = await ctx.api.subresource(ref, 'scale', namespace: ns, name: name);
  } catch (e) {
    if (context.mounted) showActionError(context, '$e');
    return;
  }
  if (!context.mounted) return;
  final current = (dig<num>(scale, ['spec', 'replicas']) ?? 0).toInt();
  final controller = TextEditingController(text: '$current');
  final target = await showDialog<int>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final value = int.tryParse(controller.text);
        return AlertDialog(
          title: Text('Scale ${ctx.type.kind} $name'),
          content: SizedBox(
            width: 320,
            child: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: 'Replicas (currently $current)'),
              onChanged: (_) => setState(() {}),
              onSubmitted: (v) => Navigator.pop(context, int.tryParse(v)),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
            FilledButton(
              style: value == 0 ? destructiveButtonStyle(context) : null,
              onPressed: value == null || value < 0 ? null : () => Navigator.pop(context, value),
              child: const Text('Apply'),
            ),
          ],
        );
      },
    ),
  );
  if (target == null || target == current) return;
  scale['spec'] = {...asMap(scale['spec']), 'replicas': target};
  try {
    await ctx.api.updateSubresource(ref, 'scale', namespace: ns, name: name, yaml: jsonEncode(scale));
    messenger?.showSnackBar(SnackBar(content: Text('Scaled $name to $target')));
  } catch (e) {
    if (context.mounted) showActionError(context, '$e');
  }
}
