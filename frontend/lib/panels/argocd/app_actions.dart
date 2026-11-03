/// Sync / Refresh / Terminate for Argo CD Applications. These run the
/// backend's `argocd-*` actions, which patch the Application CR the same way
/// the Argo CD API server does (see docs/ARGOCD.md).
library;

import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'argo_common.dart';

/// Whether the app has a pending or running operation.
bool operationInProgress(Json app) {
  final phase = dig<String>(app, ['status', 'operationState', 'phase']);
  return phase == 'Running' || phase == 'Terminating' || app['operation'] != null;
}

bool operationRunning(Json app) => dig<String>(app, ['status', 'operationState', 'phase']) == 'Running' && app['operation'] != null;

/// Options chosen in the sync dialog.
class SyncRequest {
  final bool prune;
  final bool dryRun;
  final String revision;
  final bool applyOutOfSyncOnly;
  final bool force;
  const SyncRequest({this.prune = false, this.dryRun = false, this.revision = '', this.applyOutOfSyncOnly = false, this.force = false});

  /// The `argocd-sync` action body. [appSyncOptions] are the app's own
  /// `syncPolicy.syncOptions`, which an explicit list would otherwise replace.
  Json body(List<String> appSyncOptions) => {
        if (prune) 'prune': true,
        if (dryRun) 'syncDryRun': true,
        if (revision.trim().isNotEmpty) 'targetRevision': revision.trim(),
        if (applyOutOfSyncOnly) 'syncOptions': [...appSyncOptions.where((o) => !o.startsWith('ApplyOutOfSyncOnly=')), 'ApplyOutOfSyncOnly=true'],
        if (force) 'force': true,
      };

  String summary(String name, String target) {
    final parts = <String>[
      revision.trim().isEmpty ? 'Sync $name to its target revision ($target).' : 'Sync $name to revision ${revision.trim()}.',
      if (prune) 'Resources no longer in git will be deleted (prune).',
      if (dryRun) 'Dry run: nothing is changed in the cluster.',
      if (applyOutOfSyncOnly) 'Only out-of-sync resources are applied.',
      if (force) 'The operation in progress will be replaced.',
      'Argo CD\'s application controller performs the sync.',
    ];
    return parts.join(' ');
  }
}

/// Options dialog, then the shared confirmation, then `argocd-sync`.
Future<void> showArgoSyncDialog(BuildContext context, PanelContext ctx) async {
  final req = await showDialog<SyncRequest>(context: context, builder: (_) => SyncOptionsDialog(app: ctx.object));
  if (req == null || !context.mounted) return;
  final sources = appSources(ctx.spec);
  final target = sources.length == 1 ? '${sources.first['targetRevision'] ?? 'HEAD'}' : 'per source';
  final appOpts = [for (final o in (dig<List>(ctx.spec, ['syncPolicy', 'syncOptions']) ?? const [])) '$o'];
  await runResourceAction(
    context,
    ctx,
    'argocd-sync',
    body: req.body(appOpts),
    title: '${req.dryRun ? 'Dry-run sync' : 'Sync'} ${ctx.name}?',
    message: req.summary(ctx.name, target),
    destructive: req.prune && !req.dryRun,
    confirmLabel: req.dryRun ? 'Dry run' : 'Sync',
  );
}

Future<void> argoRefresh(BuildContext context, PanelContext ctx, {bool hard = false}) => runResourceAction(
      context,
      ctx,
      'argocd-refresh',
      body: {if (hard) 'hard': true},
      // A refresh only asks the controller to compare again: no confirmation.
      confirm: false,
      title: hard ? 'Hard refresh ${ctx.name}' : 'Refresh ${ctx.name}',
    );

Future<void> argoTerminate(BuildContext context, PanelContext ctx) => runResourceAction(
      context,
      ctx,
      'argocd-terminate',
      title: 'Terminate the running sync of ${ctx.name}?',
      message: 'Argo CD stops the operation after the current step. Resources already applied stay as they are.',
      confirmLabel: 'Terminate',
    );

/// Header actions for an Application.
List<ResourceAction> argoAppActions(PanelContext ctx) => [
      ResourceAction(id: 'argocd-sync', label: 'Sync', icon: Icons.sync, tooltip: 'Sync with git (Argo CD)', run: (c) => showArgoSyncDialog(c, ctx)),
      ResourceAction(id: 'argocd-refresh', label: 'Refresh', icon: Icons.refresh, tooltip: 'Compare with git again', run: (c) => argoRefresh(c, ctx)),
      ResourceAction(
          id: 'argocd-hard-refresh',
          label: 'Hard refresh',
          icon: Icons.cached,
          tooltip: 'Regenerate manifests (drops the repo-server cache) and compare',
          run: (c) => argoRefresh(c, ctx, hard: true)),
      if (operationRunning(ctx.object))
        ResourceAction(id: 'argocd-terminate', label: 'Terminate sync', icon: Icons.stop_circle_outlined, run: (c) => argoTerminate(c, ctx)),
    ];

/// The sync options form. Pops a [SyncRequest] or null.
class SyncOptionsDialog extends StatefulWidget {
  final Json app;
  const SyncOptionsDialog({super.key, required this.app});

  @override
  State<SyncOptionsDialog> createState() => _SyncOptionsDialogState();
}

class _SyncOptionsDialogState extends State<SyncOptionsDialog> {
  final _revision = TextEditingController();
  bool _prune = false;
  bool _dryRun = false;
  bool _outOfSyncOnly = false;
  bool _force = false;

  @override
  void initState() {
    super.initState();
    final spec = asMap(widget.app['spec']);
    _prune = dig<bool>(spec, ['syncPolicy', 'automated', 'prune']) ?? false;
  }

  @override
  void dispose() {
    _revision.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spec = asMap(widget.app['spec']);
    final sources = appSources(spec);
    final multi = asMapList(spec['sources']).isNotEmpty;
    final target = sources.isEmpty ? 'HEAD' : '${sources.first['targetRevision'] ?? 'HEAD'}';
    final auto = autoSyncEnabled(spec);
    final busy = operationInProgress(widget.app);
    final outOfSync = asMapList(dig(widget.app, ['status', 'resources'])).where((r) => r['status'] != 'Synced').length;
    final pruneCount = asMapList(dig(widget.app, ['status', 'resources'])).where((r) => r['requiresPruning'] == true).length;
    Widget check(String label, String help, bool value, ValueChanged<bool> onChanged) => CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.leading,
          visualDensity: VisualDensity.compact,
          value: value,
          onChanged: (v) => setState(() => onChanged(v ?? false)),
          title: Text(label, style: theme.textTheme.bodyMedium),
          subtitle: Text(help, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        );
    return AlertDialog(
      title: Text('Sync ${dig(widget.app, ['metadata', 'name'])}'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (busy)
              ArgoCallout(
                severity: Severity.warn,
                icon: Icons.sync_problem,
                title: 'An operation is already in progress',
                message: 'Syncing now is refused unless you replace it.',
              ),
            Text(
              '$outOfSync out-of-sync resource${outOfSync == 1 ? '' : 's'}${pruneCount > 0 ? ', $pruneCount to prune' : ''}.',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            check('Prune', 'Delete resources that are no longer in git', _prune, (v) => _prune = v),
            check('Dry run', 'Run the sync with --dry-run: nothing changes', _dryRun, (v) => _dryRun = v),
            check('Apply out of sync only', 'Skip resources that are already synced', _outOfSyncOnly, (v) => _outOfSyncOnly = v),
            if (busy) check('Replace the running operation', 'Overwrites the operation in progress', _force, (v) => _force = v),
            const SizedBox(height: 8),
            TextField(
              controller: _revision,
              enabled: !multi,
              style: monoStyle(context),
              decoration: InputDecoration(
                isDense: true,
                labelText: 'Revision (optional)',
                hintText: multi ? 'Not supported for multi-source apps' : target,
                helperText: multi
                    ? 'Each source syncs to its own target revision.'
                    : (auto ? 'Auto-sync is on: only $target is allowed (except for dry runs).' : 'Branch, tag or commit. Empty = $target.'),
                helperMaxLines: 2,
              ),
            ),
          ]),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: busy && !_force
              ? null
              : () => Navigator.pop(
                    context,
                    SyncRequest(prune: _prune, dryRun: _dryRun, revision: _revision.text, applyOutOfSyncOnly: _outOfSyncOnly, force: _force),
                  ),
          child: const Text('Next'),
        ),
      ],
    );
  }
}
