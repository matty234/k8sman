import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../panels/panel.dart';
import '../../state/app_state.dart';
import 'overview_api.dart';

/// An in-context fix offered next to an issue. Runs through
/// [runResourceAction] (confirmation, context check, snackbar).
class QuickAction {
  final ObjectRef target;
  final String action;
  final String label;
  final IconData icon;
  final String title;
  final String? message;
  final bool destructive;
  final Json body;
  const QuickAction({
    required this.target,
    required this.action,
    required this.label,
    required this.icon,
    required this.title,
    this.message,
    this.destructive = false,
    this.body = const {},
  });
}

const _restartable = {'apps/Deployment', 'apps/StatefulSet', 'apps/DaemonSet'};
const _podProblems = {'crashLoop', 'oomKilled', 'highRestarts', 'notReady'};

/// Actions for a group: owner-level ones (restart the workload) and, when
/// [includeObject], ones for the object itself (delete a stuck pod, resume).
List<QuickAction> quickActionsFor(IssueGroup g, {bool includeOwner = true, bool includeObject = true}) {
  final out = <QuickAction>[];
  final i = g.first;
  final owner = g.owner;
  if (includeOwner && owner != null && _podProblems.contains(i.category) && _restartable.contains('${owner.group}/${owner.kind}')) {
    out.add(QuickAction(
      target: ObjectRef(group: owner.group, kind: owner.kind, name: owner.name, namespace: i.namespace),
      action: 'restart',
      label: 'Restart',
      icon: Icons.restart_alt,
      title: 'Restart ${owner.kind} ${owner.name}?',
      message: 'Pods are replaced gradually using the rollout strategy (same as kubectl rollout restart).',
    ));
  }
  if (!includeObject) return out;
  final ref = i.ref;
  switch (i.category) {
    case 'stuckTerminating':
      out.add(QuickAction(
        target: ref,
        action: 'delete',
        label: 'Force delete',
        icon: Icons.delete_forever_outlined,
        title: 'Force delete pod ${i.name}?',
        message: 'Removes the pod immediately (grace period 0) without waiting for the kubelet to confirm. '
            'Finalizers still have to be cleared by their controller.',
        destructive: true,
        body: const {'gracePeriodSeconds': 0},
      ));
    case 'stuckPending' || 'initBlocked' || 'imagePull' || 'createContainerConfigError' when i.kind == 'Pod':
      out.add(QuickAction(
        target: ref,
        action: 'delete',
        label: 'Delete pod',
        icon: Icons.delete_outline,
        title: 'Delete pod ${i.name}?',
        message: i.owner != null ? 'Its ${i.owner!.kind} will create a replacement.' : 'This pod has no controller and will not be recreated.',
        destructive: true,
      ));
    case 'cronJobSuspended' || 'jobSuspended':
      out.add(QuickAction(target: ref, action: 'unsuspend', label: 'Resume', icon: Icons.play_arrow, title: 'Resume ${i.kind} ${i.name}?'));
    case 'deploymentPaused':
      out.add(QuickAction(target: ref, action: 'resume', label: 'Resume rollout', icon: Icons.play_arrow, title: 'Resume rollout of ${i.name}?'));
  }
  return out;
}

/// Fetches the target (runResourceAction needs the live object), then runs
/// the action. Calls [onDone] after a successful run so the overview refreshes.
class QuickActionButton extends StatefulWidget {
  final QuickAction action;
  final VoidCallback onDone;
  const QuickActionButton({super.key, required this.action, required this.onDone});

  @override
  State<QuickActionButton> createState() => _QuickActionButtonState();
}

class _QuickActionButtonState extends State<QuickActionButton> {
  bool _busy = false;

  Future<void> _run() async {
    final a = widget.action;
    final app = context.read<AppState>();
    final api = context.read<ApiClient>();
    final type = app.typeFor(a.target.group, a.target.kind);
    if (type == null) return;
    setState(() => _busy = true);
    try {
      final obj = await api.object(type.ref, namespace: type.namespaced ? a.target.namespace : null, name: a.target.name);
      if (!mounted) return;
      final ctx = PanelContext(object: obj, type: type, api: api, app: app);
      final res = await runResourceAction(context, ctx, a.action,
          title: a.title, message: a.message, destructive: a.destructive, body: a.body, confirmLabel: a.label);
      if (res != null) widget.onDone();
    } on ApiException catch (e) {
      if (mounted) showActionError(context, e.message);
    } catch (e) {
      if (mounted) showActionError(context, '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final a = widget.action;
    final color = a.destructive ? theme.colorScheme.error : null;
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        visualDensity: VisualDensity.compact,
        foregroundColor: color,
        side: color != null ? BorderSide(color: color.withValues(alpha: 0.5)) : null,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 28),
        textStyle: theme.textTheme.labelSmall,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
      icon: _busy ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 2)) : Icon(a.icon, size: 14),
      label: Text(a.label),
      onPressed: _busy ? null : _run,
    );
  }
}
