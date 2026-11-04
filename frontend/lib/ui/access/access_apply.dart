/// Applying RBAC changes: server-side dry run, a diff in the shared confirm
/// dialog, then the real apply; and removing a subject from a binding.
library;

import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import 'package:provider/provider.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../util/diff.dart';
import '../../util/k8s.dart';
import '../detail/yaml_editor.dart' show DiffView;
import '../theme.dart';
import 'access_api.dart';
import 'access_widgets.dart';
import 'rbac_model.dart';

/// Explains an apply failure. Escalation refusals get a plain-English
/// headline; everything else shows the API server's message.
class ApplyErrorView extends StatelessWidget {
  final Object error;
  const ApplyErrorView(this.error, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = severityColor(context, Severity.error);
    final escalation = isEscalationError(error);
    final msg = errorText(error);
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(color: c.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(6), border: Border.all(color: c.withValues(alpha: 0.5))),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Icon(escalation ? Icons.lock_outline : Icons.error_outline, size: 16, color: c),
        const SizedBox(width: 8),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(escalation ? 'You can\'t grant permissions you don\'t hold' : 'The API server rejected this', style: theme.textTheme.bodyMedium?.copyWith(color: c, fontWeight: FontWeight.w600)),
            if (escalation) ...[
              const SizedBox(height: 2),
              Text(
                'Kubernetes refuses roles and bindings that would give out more than your own credentials have, '
                'unless you hold the escalate (roles) or bind (bindings) verb. Remove the permissions listed below, or ask a cluster admin.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 4),
            SelectableText(msg, style: monoStyle(context, size: 11)),
          ]),
        ),
      ]),
    );
  }
}

/// Dry-runs [object], shows the diff in the standard confirm dialog, and
/// applies it if confirmed. Returns the result, or null if cancelled or
/// failed. A failed dry run goes to [onError] (or a dialog when null).
Future<ApplyResult?> reviewAndApply(
  BuildContext context, {
  required AccessApi api,
  required Json object,
  required String title,
  String? message,
  String confirmLabel = 'Apply',
  bool destructive = false,
  void Function(Object error)? onError,
}) async {
  final app = context.read<AppState>();
  ApplyResult dry;
  try {
    dry = await api.apply(object, dryRun: true);
  } catch (e) {
    if (!context.mounted) return null;
    if (onError != null) {
      onError(e);
    } else {
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SizedBox(width: 520, child: ApplyErrorView(e)),
          actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
        ),
      );
    }
    return null;
  }
  if (!context.mounted) return null;
  final lines = diffLines(dry.before, dry.after);
  final ok = await confirmAction(
    context,
    title: title,
    message: message ?? (dry.created ? 'Creates a new object. The server accepted it in a dry run.' : 'The server accepted this change in a dry run.'),
    kubeContext: app.currentContext,
    objectName: dig<String>(object, ['metadata', 'name']) ?? '',
    destructive: destructive,
    confirmLabel: confirmLabel,
    width: 620,
    extra: Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(height: 300, child: DiffView(lines: lines)),
    ),
  );
  if (ok != true || !context.mounted) return null;
  try {
    final res = await api.apply(object);
    if (context.mounted) {
      final kind = '${object['kind']}';
      final name = dig<String>(object, ['metadata', 'name']);
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('$kind $name ${res.created ? 'created' : 'updated'}')));
    }
    return res;
  } catch (e) {
    if (context.mounted) {
      if (onError != null) {
        onError(e);
      } else {
        showActionError(context, errorText(e));
      }
    }
  }
  return null;
}

ResourceRef bindingResource(String kind) =>
    ResourceRef(group: rbacApiGroup, resource: kind == 'ClusterRoleBinding' ? 'clusterrolebindings' : 'rolebindings');

/// Removes [subject] from a binding (dry run, diff, confirm). When it is
/// the binding's only subject, offers to delete the binding instead.
/// Returns true when something changed.
Future<bool> removeSubjectFromBinding(BuildContext context, {required AccessApi api, required RbacRef binding, required RbacSubject subject}) async {
  final app = context.read<AppState>();
  final ref = bindingResource(binding.kind);
  Json obj;
  try {
    obj = await app.api.object(ref, namespace: binding.namespace, name: binding.name);
  } catch (e) {
    if (context.mounted) showActionError(context, errorText(e));
    return false;
  }
  if (!context.mounted) return false;
  final updated = bindingWithout(obj, subject);
  final remaining = asMapList(updated['subjects']);
  if (remaining.length == asMapList(obj['subjects']).length) {
    showActionError(context, '${subject.label} is not a direct subject of ${binding.name}');
    return false;
  }
  if (remaining.isEmpty) {
    final ok = await confirmAction(
      context,
      title: 'Delete ${binding.kind} ${binding.name}?',
      message: '${subject.label} is its only subject, so removing it leaves a binding that grants nothing. Delete the binding instead.',
      kubeContext: app.currentContext,
      objectName: binding.name,
      destructive: true,
      confirmLabel: 'Delete binding',
    );
    if (ok != true || !context.mounted) return false;
    try {
      final res = await app.api.runAction(ref, namespace: binding.namespace, name: binding.name, action: 'delete');
      if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(res.message)));
      return true;
    } catch (e) {
      if (context.mounted) showActionError(context, errorText(e));
      return false;
    }
  }
  final res = await reviewAndApply(
    context,
    api: api,
    object: updated,
    title: 'Remove ${subject.label} from ${binding.name}?',
    message: '${subject.kind} ${subject.label} loses what ${binding.kind} ${binding.label} grants. ${remaining.length} other subject${remaining.length == 1 ? '' : 's'} keep it.',
    confirmLabel: 'Remove',
    destructive: true,
  );
  return res != null;
}
