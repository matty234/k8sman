/// Helm mutations (rollback, upgrade with new values, uninstall, recovering
/// stuck releases). Every one goes through [confirmAction], which names the
/// kube context and requires typing the release name on non-local clusters.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:re_editor/re_editor.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../util/diff.dart';
import '../../util/k8s.dart';
import '../detail/yaml_editor.dart' show DiffView;
import '../theme.dart';
import 'helm_api.dart';
import 'yaml_view.dart';

/// Runs [op] behind a small modal progress dialog, then reports the result
/// (snackbar) or error. Returns the result, or null on failure.
Future<HelmResult?> _runWithProgress(BuildContext context, String label, Future<HelmResult> Function() op) async {
  final nav = Navigator.of(context, rootNavigator: true);
  final messenger = ScaffoldMessenger.maybeOf(context);
  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (c) => PopScope(
      canPop: false,
      child: AlertDialog(
        content: Row(mainAxisSize: MainAxisSize.min, children: [
          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          const SizedBox(width: 12),
          Flexible(child: Text(label)),
        ]),
      ),
    ),
  );
  try {
    final res = await op();
    nav.pop();
    messenger?.showSnackBar(SnackBar(content: Text(res.message)));
    return res;
  } on ApiException catch (e) {
    nav.pop();
    if (context.mounted) showActionError(context, e.message);
  } catch (e) {
    nav.pop();
    if (context.mounted) showActionError(context, '$e');
  }
  return null;
}

/// Manifest / values diff with a toggle, for confirm dialogs and history.
class HelmDiffPane extends StatefulWidget {
  final String oldManifest, newManifest;
  final String? oldValues, newValues;
  const HelmDiffPane({super.key, required this.oldManifest, required this.newManifest, this.oldValues, this.newValues});

  @override
  State<HelmDiffPane> createState() => _HelmDiffPaneState();
}

class _HelmDiffPaneState extends State<HelmDiffPane> {
  bool _values = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final manifest = diffLines(widget.oldManifest, widget.newManifest);
    final hasValues = widget.oldValues != null && widget.newValues != null;
    final values = hasValues ? diffLines(widget.oldValues!, widget.newValues!) : const <DiffLine>[];
    String stat(List<DiffLine> l) {
      final s = diffStats(l);
      return s.added + s.removed == 0 ? 'no changes' : '+${s.added} −${s.removed}';
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (hasValues)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Row(children: [
            SegmentedButton<bool>(
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              showSelectedIcon: false,
              segments: [
                ButtonSegment(value: false, label: Text('Manifest  ${stat(manifest)}')),
                ButtonSegment(value: true, label: Text('Values  ${stat(values)}')),
              ],
              selected: {_values},
              onSelectionChanged: (s) => setState(() => _values = s.first),
            ),
          ]),
        )
      else
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: Text('Manifest ${stat(manifest)}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ),
      Expanded(child: DiffView(lines: _values ? values : manifest)),
    ]);
  }
}

/// Shows the diff between two revisions (read-only, no action).
Future<void> showRevisionDiff(BuildContext context, HelmApi api, HelmRelease r, {required int from, required int to}) async {
  HelmDiff d;
  try {
    d = await api.diff(r.namespace, r.name, from: from, to: to);
  } on ApiException catch (e) {
    if (context.mounted) showActionError(context, e.message);
    return;
  }
  if (!context.mounted) return;
  await showDialog<void>(
    context: context,
    builder: (c) {
      final size = MediaQuery.sizeOf(c);
      return AlertDialog(
        title: Text('${r.name}: revision $from → $to'),
        content: SizedBox(
          width: (size.width - 120).clamp(320.0, 900.0),
          height: (size.height - 240).clamp(240.0, 640.0),
          child: HelmDiffPane(oldManifest: d.from.manifest, newManifest: d.to.manifest, oldValues: d.from.values, newValues: d.to.values),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(c), child: const Text('Close'))],
      );
    },
  );
}

/// Roll back [r] (whose latest revision is [current]) to [target]: shows the
/// manifest diff in the confirmation, then rolls back.
Future<HelmResult?> rollbackRelease(
  BuildContext context,
  HelmApi api,
  HelmRelease r, {
  required int current,
  required int target,
  required String kubeContext,
  String? title,
  String? message,
}) async {
  HelmDiff d;
  try {
    d = await api.diff(r.namespace, r.name, from: current, to: target);
  } on ApiException catch (e) {
    if (context.mounted) showActionError(context, e.message);
    return null;
  }
  if (!context.mounted) return null;
  final ok = await confirmAction(
    context,
    title: title ?? 'Roll back ${r.name} to revision $target?',
    message: message ??
        'Creates revision ${current + 1} from revision $target\'s chart (${d.to.chart}) and values. '
            'Below: what changes compared with the current revision $current.',
    kubeContext: kubeContext,
    objectName: r.name,
    destructive: true,
    confirmLabel: 'Roll back',
    width: 760,
    extra: Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: SizedBox(
        height: 340,
        child: HelmDiffPane(oldManifest: d.from.manifest, newManifest: d.to.manifest, oldValues: d.from.values, newValues: d.to.values),
      ),
    ),
  );
  if (ok != true || !context.mounted) return null;
  return _runWithProgress(context, 'Rolling back ${r.name} to revision $target…', () => api.rollback(r.namespace, r.name, target));
}

/// Uninstall, optionally keeping history so it can be rolled back later.
Future<HelmResult?> uninstallRelease(BuildContext context, HelmApi api, HelmReleaseDetail d, {required String kubeContext}) async {
  final r = d.release;
  var keepHistory = false;
  final ok = await confirmAction(
    context,
    title: 'Uninstall ${r.name}?',
    message: 'Deletes the ${d.resources.length} resource${d.resources.length == 1 ? '' : 's'} in this release from ${r.namespace} '
        '(PersistentVolumeClaims created by StatefulSets and resources with "helm.sh/resource-policy: keep" stay).',
    kubeContext: kubeContext,
    objectName: r.name,
    destructive: true,
    confirmLabel: 'Uninstall',
    extra: StatefulBuilder(
      builder: (context, setState) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Row(children: [
          SizedBox(
            width: 28,
            child: Checkbox(value: keepHistory, onChanged: (v) => setState(() => keepHistory = v == true)),
          ),
          const SizedBox(width: 4),
          Flexible(child: Text('Keep history (allows rolling back later)', style: Theme.of(context).textTheme.bodySmall)),
        ]),
      ),
    ),
  );
  if (ok != true || !context.mounted) return null;
  return _runWithProgress(context, 'Uninstalling ${r.name}…', () => api.uninstall(r.namespace, r.name, keepHistory: keepHistory));
}

/// Edit user values → dry run → review the manifest diff → confirm → apply.
/// Cancelling the review returns to the editor with the edits intact.
Future<HelmResult?> upgradeReleaseValues(BuildContext context, HelmApi api, HelmReleaseDetail d, {required String kubeContext}) async {
  final r = d.release;
  var text = d.values;
  while (context.mounted) {
    final edited = await showDialog<(String, HelmResult)>(
      context: context,
      barrierDismissible: false,
      builder: (c) => _ValuesEditorDialog(api: api, detail: d, initial: text),
    );
    if (edited == null || !context.mounted) return null;
    text = edited.$1;
    final dry = edited.$2;
    final stats = diffStats(diffLines(dry.currentManifest, dry.manifest));
    final ok = await confirmAction(
      context,
      title: 'Upgrade ${r.name} with these values?',
      message: 'Creates revision ${r.revision + 1} from the stored chart ${r.chartRef}. '
          'Manifest +${stats.added} −${stats.removed} lines, validated by a dry run.',
      kubeContext: kubeContext,
      objectName: r.name,
      destructive: true,
      confirmLabel: 'Upgrade',
      width: 760,
      extra: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: SizedBox(
          height: 340,
          child: HelmDiffPane(oldManifest: dry.currentManifest, newManifest: dry.manifest, oldValues: d.values, newValues: text),
        ),
      ),
    );
    if (!context.mounted) return null;
    if (ok == true) {
      return _runWithProgress(context, 'Upgrading ${r.name}…', () => api.upgrade(r.namespace, r.name, text));
    }
  }
  return null;
}

class _ValuesEditorDialog extends StatefulWidget {
  final HelmApi api;
  final HelmReleaseDetail detail;
  final String initial;
  const _ValuesEditorDialog({required this.api, required this.detail, required this.initial});

  @override
  State<_ValuesEditorDialog> createState() => _ValuesEditorDialogState();
}

class _ValuesEditorDialogState extends State<_ValuesEditorDialog> {
  late final _controller = CodeLineEditingController.fromText(widget.initial);
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _dryRun() async {
    setState(() => (_busy = true, _error = null));
    final r = widget.detail.release;
    try {
      final res = await widget.api.upgrade(r.namespace, r.name, _controller.text, dryRun: true);
      if (mounted) Navigator.pop(context, (_controller.text, res));
    } on ApiException catch (e) {
      if (mounted) setState(() => (_busy = false, _error = e.message));
    } catch (e) {
      if (mounted) setState(() => (_busy = false, _error = '$e'));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final size = MediaQuery.sizeOf(context);
    final r = widget.detail.release;
    return CallbackShortcuts(
      bindings: {const SingleActivator(LogicalKeyboardKey.enter, meta: true): () => _busy ? null : _dryRun()},
      child: AlertDialog(
        title: Text('Edit values of ${r.name}'),
        content: SizedBox(
          width: (size.width - 120).clamp(320.0, 760.0),
          height: (size.height - 260).clamp(220.0, 560.0),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text(
              'User-supplied values for ${r.chartRef}. They replace the current user values; chart defaults apply to anything you leave out. '
              'A dry run renders the result for review before anything changes.',
              style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor),
            ),
            const SizedBox(height: 8),
            Expanded(child: HelmYamlView(controller: _controller, readOnly: false)),
            if (_error != null)
              Container(
                margin: const EdgeInsets.only(top: 8),
                padding: const EdgeInsets.all(8),
                constraints: const BoxConstraints(maxHeight: 120),
                decoration: BoxDecoration(
                  color: severityColor(context, Severity.error).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: severityColor(context, Severity.error).withValues(alpha: 0.4)),
                ),
                child: SingleChildScrollView(child: SelectableText(_error!, style: theme.textTheme.bodySmall)),
              ),
          ]),
        ),
        actions: [
          TextButton(onPressed: _busy ? null : () => _controller.text = widget.detail.values, child: const Text('Reset')),
          TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
          FilledButton(onPressed: _busy ? null : _dryRun, child: Text(_busy ? 'Rendering…' : 'Dry run & review')),
        ],
      ),
    );
  }
}
