/// Actions on many objects at once (the table's multi-selection): one
/// confirmation naming the context, then the calls run concurrently with a
/// small limit, with progress and a summary of what failed.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';
import 'actions.dart';

/// One object a bulk action applies to.
class BulkTarget {
  final ResourceType type;
  final String name;
  final String? namespace;
  const BulkTarget({required this.type, required this.name, this.namespace});

  factory BulkTarget.fromRow(ResourceType type, TableRowData row) =>
      BulkTarget(type: type, name: row.name, namespace: type.namespaced ? row.namespace : null);

  String get qualified => namespace == null ? name : '$namespace/$name';
}

/// An action offered for a multi-selection.
class BulkAction {
  /// Backend action id (`POST /api/actions/<action>`).
  final String action;
  final String label;

  /// The bare verb for "Delete 3 Pods?" ("Delete pods" → "Delete").
  final String verb;
  final IconData icon;
  final bool destructive;

  /// "Deleting", "Restarting" (progress) and "Deleted", "Restarted" (summary).
  final String doing;
  final String done;

  /// Shown in the confirmation under the title.
  final String? message;

  /// The action's request body (same for every object).
  final Json body;

  /// Ask first. Off for actions that change nothing (Argo CD refresh).
  final bool confirm;

  /// Offer "Force (no grace period)" under Advanced (deleting pods).
  final bool offerForce;
  const BulkAction({
    required this.action,
    required this.label,
    required this.verb,
    required this.icon,
    required this.doing,
    required this.done,
    this.destructive = false,
    this.message,
    this.body = const {},
    this.confirm = true,
    this.offerForce = false,
  });

  BulkAction withBody(Json b) => BulkAction(
        action: action,
        label: label,
        verb: verb,
        icon: icon,
        doing: doing,
        done: done,
        destructive: destructive,
        message: message,
        body: b,
        confirm: confirm,
        offerForce: offerForce,
      );
}

const _restartable = {'apps/Deployment', 'apps/StatefulSet', 'apps/DaemonSet'};

/// Actions available on every one of [rows] (all of [type]). Scale is per
/// object, so it's never offered in bulk. Empty when the backend is
/// read-only.
List<BulkAction> bulkActionsFor(AppState app, ResourceType type, List<TableRowData> rows) {
  if (app.readOnly || rows.isEmpty) return const [];
  final n = rows.length;
  final out = <BulkAction>[];
  if (_restartable.contains(type.gk)) {
    out.add(BulkAction(
      action: 'restart',
      label: 'Restart',
      verb: 'Restart',
      icon: Icons.restart_alt,
      doing: 'Restarting',
      done: 'Restarted',
      message: 'Pods of each ${type.kind} are replaced gradually using its rollout strategy (kubectl rollout restart).',
    ));
  }
  final isPod = type.gk == '/Pod';
  if (isPod && rows.every((r) => r.controlled)) {
    out.add(BulkAction(
      action: 'delete',
      label: 'Restart pods',
      verb: 'Restart',
      icon: Icons.refresh,
      doing: 'Restarting',
      done: 'Restarted',
      destructive: true,
      message: 'Each pod is deleted and its controller creates a replacement.',
    ));
  }
  if (type.can('delete')) {
    out.add(BulkAction(
      action: 'delete',
      label: isPod ? 'Delete pods' : 'Delete',
      offerForce: isPod,
      verb: 'Delete',
      icon: Icons.delete_outline,
      doing: 'Deleting',
      done: 'Deleted',
      destructive: true,
      message: !isPod
          ? 'Dependents are garbage-collected in the background.'
          : rows.every((r) => !r.controlled)
          ? 'These pods have no controller and will not come back.'
          : rows.any((r) => !r.controlled)
          ? '${rows.where((r) => !r.controlled).length} of these $n pods have no controller and will not come back.'
          : 'Their controllers will create replacements.',
    ));
  }
  if (type.gk == 'argoproj.io/Application') {
    out.addAll(const [
      BulkAction(
        action: 'argocd-sync',
        label: 'Sync',
        verb: 'Sync',
        icon: Icons.sync,
        doing: 'Syncing',
        done: 'Synced',
        message: 'Each application syncs to its target revision with its own sync options. Nothing is pruned. '
            'For prune, dry run or a specific revision, sync one application from its inspector.',
      ),
      BulkAction(action: 'argocd-refresh', label: 'Refresh', verb: 'Refresh', icon: Icons.refresh, doing: 'Refreshing', done: 'Refreshed', confirm: false),
      BulkAction(
        action: 'argocd-refresh',
        label: 'Hard refresh',
        verb: 'Hard refresh',
        icon: Icons.cached,
        doing: 'Hard refreshing',
        done: 'Hard refreshed',
        body: {'hard': true},
        confirm: false,
      ),
    ]);
  }
  return out;
}

/// The outcome of a bulk run.
class BulkResult {
  final List<BulkTarget> succeeded;
  final List<(BulkTarget, String)> failed;
  const BulkResult(this.succeeded, this.failed);
}

/// Progress of a running bulk action, for a selection bar or snackbar.
class BulkProgress {
  final String doing;
  final int done;
  final int total;
  const BulkProgress(this.doing, this.done, this.total);
  @override
  String toString() => '$doing $done/$total…';
}

/// Confirms once (listing the objects and naming the context), then runs
/// [action] on [targets], [concurrency] at a time. Progress goes to
/// [progress] (if given) and a snackbar; failures are listed in a dialog
/// whose text can be copied. Returns null if cancelled.
Future<BulkResult?> runBulkAction(
  BuildContext context, {
  required ApiClient api,
  required AppState app,
  required List<BulkTarget> targets,
  required BulkAction action,
  int concurrency = 4,
  ValueNotifier<BulkProgress?>? progress,
}) async {
  if (targets.isEmpty || app.readOnly) return null;
  final n = targets.length;
  final kind = targets.first.type.kind;
  final what = n == 1 ? kind : _plural(kind);
  final choice = ValueNotifier(const DeleteChoice());
  final look = ValueNotifier(ConfirmLook('${action.verb} $n', action.destructive));
  if (action.offerForce) {
    choice.addListener(() => look.value = ConfirmLook(choice.value.force ? 'Force delete $n' : '${action.verb} $n', true));
  }
  final ok = !action.confirm || await confirmAction(
    context,
    title: '${action.verb} $n $what?',
    message: action.message,
    kubeContext: app.currentContext,
    objectName: '$n $what',
    destructive: action.destructive,
    confirmLabel: '${action.verb} $n',
    confirmLook: look,
    extra: Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        BulkTargetList(targets),
        if (action.offerForce) DeleteAdvanced(choice: choice, offerForce: true),
      ]),
    ),
  ) == true;
  if (!ok || !context.mounted) return null;
  if (choice.value.force) action = action.withBody({...action.body, 'gracePeriodSeconds': 0});

  final messenger = ScaffoldMessenger.maybeOf(context);
  final notifier = progress ?? ValueNotifier<BulkProgress?>(null);
  notifier.value = BulkProgress(action.doing, 0, n);
  // The progress toast must be the one showing, not queued behind others:
  // only the showing toast can be removed, so a queued one would surface
  // after the run and sit there. Toasts shown during the run queue behind it.
  messenger
    ?..clearSnackBars()
    ..removeCurrentSnackBar();
  var progressShowing = messenger != null;
  messenger
      ?.showSnackBar(SnackBar(
        duration: const Duration(days: 1),
        content: ValueListenableBuilder<BulkProgress?>(
          valueListenable: notifier,
          builder: (_, p, _) => Text(p == null ? '${action.doing}…' : '$p'),
        ),
      ))
      .closed
      .whenComplete(() => progressShowing = false);

  final succeeded = <BulkTarget>[];
  final failed = <(BulkTarget, String)>[];
  var next = 0;
  var finished = 0;
  Future<void> worker() async {
    while (next < n) {
      final t = targets[next++];
      try {
        await api.runAction(t.type.ref, namespace: t.namespace, name: t.name, action: action.action, body: action.body);
        succeeded.add(t);
      } on ApiException catch (e) {
        failed.add((t, e.message));
      } catch (e) {
        failed.add((t, '$e'));
      }
      finished++;
      notifier.value = BulkProgress(action.doing, finished, n);
    }
  }

  await Future.wait([for (var i = 0; i < math.min(concurrency, n); i++) worker()]);
  // Remove the toast before disposing the notifier it listens to. Only
  // remove it if it's still up (something may have dismissed it, and then
  // the current toast is someone else's).
  if (progressShowing) messenger?.removeCurrentSnackBar();
  notifier.value = null;
  if (progress == null) notifier.dispose();
  // Keep the input order in the summary.
  failed.sort((a, b) => targets.indexOf(a.$1).compareTo(targets.indexOf(b.$1)));
  final result = BulkResult(succeeded, failed);

  if (failed.isEmpty) {
    messenger?.showSnackBar(SnackBar(content: Text('${action.done} $n $what')));
  } else if (context.mounted) {
    await showBulkFailures(context, action: action, result: result, kind: kind);
  }
  return result;
}

/// "Deleted 11, 1 failed" with each failure, selectable and copyable.
Future<void> showBulkFailures(BuildContext context, {required BulkAction action, required BulkResult result, required String kind}) {
  final summary = bulkSummary(action, result);
  final details = [for (final (t, err) in result.failed) '${t.qualified}: $err'].join('\n');
  return showDialog<void>(
    context: context,
    builder: (context) {
      final theme = Theme.of(context);
      return AlertDialog(
        title: Text(summary),
        content: SizedBox(
          width: 520,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 320),
            child: SingleChildScrollView(
              child: SelectableText.rich(TextSpan(children: [
                for (final (i, (t, err)) in result.failed.indexed) ...[
                  if (i > 0) const TextSpan(text: '\n'),
                  TextSpan(text: t.qualified, style: monoStyle(context, size: 12).copyWith(fontWeight: FontWeight.w600)),
                  TextSpan(text: ': $err', style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.error)),
                ],
              ])),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Clipboard.setData(ClipboardData(text: '$summary\n$details')),
            child: const Text('Copy'),
          ),
          FilledButton(autofocus: true, onPressed: () => Navigator.pop(context), child: const Text('OK')),
        ],
      );
    },
  );
}

/// "Deleted 11, 1 failed".
String bulkSummary(BulkAction action, BulkResult r) {
  final ok = r.succeeded.length;
  if (r.failed.isEmpty) return '${action.done} $ok';
  if (ok == 0) return '${action.verb} failed for all ${r.failed.length}';
  return '${action.done} $ok, ${r.failed.length} failed';
}

/// The first [shown] names, then "and N more".
class BulkTargetList extends StatelessWidget {
  final List<BulkTarget> targets;
  final int shown;
  const BulkTargetList(this.targets, {super.key, this.shown = 10});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final more = targets.length - shown;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.onSurface.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final t in targets.take(shown))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 1),
            child: Text(t.qualified, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 12)),
          ),
        if (more > 0)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text('and $more more', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ),
      ]),
    );
  }
}

String _plural(String kind) {
  if (kind.endsWith('s')) return '${kind}es';
  if (kind.endsWith('y') && !kind.endsWith('ay') && !kind.endsWith('ey')) return '${kind.substring(0, kind.length - 1)}ies';
  return '${kind}s';
}
