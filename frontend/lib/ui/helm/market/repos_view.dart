import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../../actions/actions.dart' show showActionError;
import '../../../api/client.dart';
import '../../../state/app_state.dart';
import '../../../util/k8s.dart';
import '../../theme.dart';
import '../../widgets/atoms.dart';
import '../../widgets/common.dart';
import '../../widgets/editorial.dart';
import 'market_actions.dart';
import 'market_api.dart';

/// The user's Helm repositories (helm repo list), with Update, Add and
/// Remove; and the OCI registries helm has credentials for (read-only).
class HelmReposView extends StatefulWidget {
  final Widget Function(bool compact)? modeSwitch;
  final HelmMarketApi? api;
  const HelmReposView({super.key, this.modeSwitch, this.api});

  @override
  State<HelmReposView> createState() => _HelmReposViewState();
}

class _HelmReposViewState extends State<HelmReposView> {
  late final HelmMarketApi _api = widget.api ?? HelmMarketApi.of(context);
  HelmRepoList? _list;
  Object? _error;
  final _updating = <String>{};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final l = await _api.repos();
      if (mounted) setState(() => (_list = l, _error = null));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _update(Iterable<String> names) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    setState(() => _updating.addAll(names));
    final failed = <String>[];
    for (final n in names.toList()) {
      try {
        await _api.updateRepo(n);
      } on ApiException catch (e) {
        failed.add('$n: ${e.message}');
      } catch (e) {
        failed.add('$n: $e');
      }
      if (mounted) setState(() => _updating.remove(n));
    }
    await _load();
    if (failed.isNotEmpty && mounted) {
      showActionError(context, failed.join('\n'));
    } else {
      messenger?.showSnackBar(SnackBar(content: Text(names.length == 1 ? 'Updated ${names.first}' : 'Updated ${names.length} repositories')));
    }
  }

  Future<void> _add() async {
    final l = _list;
    if (l == null) return;
    final r = await showAddRepoDialog(context, _api, l.configPath);
    if (r == null || !mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Added ${r.name}')));
    _load();
  }

  Future<void> _remove(HelmRepo r) async {
    final l = _list;
    if (l == null || !await confirmRemoveRepo(context, r, l.configPath) || !mounted) return;
    try {
      await _api.removeRepo(r.name);
      if (mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Removed ${r.name}')));
    } on ApiException catch (e) {
      if (mounted) showActionError(context, e.message);
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final l = _list;
    return LayoutBuilder(builder: (context, box) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        PageHeader(
          title: 'Helm',
          afterTitle: widget.modeSwitch?.call(box.maxWidth < 760),
          subtitle: l == null ? null : Text('${l.repositories.length} repositor${l.repositories.length == 1 ? 'y' : 'ies'}'),
          actions: [
            IconButton(tooltip: 'Reload', iconSize: 18, icon: const Icon(Icons.refresh), onPressed: _load),
            if (l != null && l.repositories.isNotEmpty)
              OutlinedButton(
                onPressed: _updating.isNotEmpty ? null : () => _update(l.repositories.map((r) => r.name)),
                child: Text(_updating.isNotEmpty ? 'Updating…' : 'Update all'),
              ),
            Tooltip(
              message: app.readOnly ? 'This context is read-only' : 'Add a repository to your helm configuration',
              child: FilledButton.tonal(
                key: const ValueKey('repo-add'),
                onPressed: app.readOnly || l == null ? null : _add,
                child: const Text('Add repository…'),
              ),
            ),
          ],
        ),
        const Divider(),
        Expanded(
          child: l == null
              ? (_error == null ? const Center(child: CircularProgressIndicator()) : LoadFailure(_error!, title: 'Couldn\'t read your Helm repositories', onRetry: _load))
              : PageScroll(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                  children: [
                    if (_error != null) Padding(padding: const EdgeInsets.only(top: 12), child: ErrorNotice(_error!, title: 'Reload failed', note: 'Showing the last result.', onRetry: _load)),
                    EditorialSection(
                      title: 'Repositories',
                      trailing: Text('${l.repositories.length}'),
                      collapsible: false,
                      top: 16,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        if (l.repositories.isEmpty) const HintText('No repositories yet. Add one to browse its charts.'),
                        for (final r in l.repositories)
                          _RepoRow(repo: r, updating: _updating.contains(r.name), readOnly: app.readOnly, onUpdate: () => _update([r.name]), onRemove: () => _remove(r)),
                        const SizedBox(height: 8),
                        HintText('From ${l.configPath}', mono: true),
                      ]),
                    ),
                    EditorialSection(
                      title: 'OCI registries',
                      trailing: Text('${l.registries.length}'),
                      collapsible: false,
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (final h in l.registries) Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: MonoText(h)),
                        HintText(
                          '${l.registries.isEmpty ? 'None logged in. ' : ''}Registries helm has credentials for, from ${l.registryConfig}. '
                          'Manage them with helm registry login and logout; install their charts with an oci:// reference.',
                        ),
                      ]),
                    ),
                  ],
                ),
        ),
      ]);
    });
  }
}

class _RepoRow extends StatelessWidget {
  final HelmRepo repo;
  final bool updating, readOnly;
  final VoidCallback onUpdate, onRemove;
  const _RepoRow({required this.repo, required this.updating, required this.readOnly, required this.onUpdate, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final r = repo;
    final status = [
      r.updated == null ? 'never updated' : 'updated ${formatAge(r.updated)} ago',
      if (r.charts != null) '${r.charts} chart${r.charts == 1 ? '' : 's'}',
    ].join(' · ');
    return Hoverable(
      cursor: SystemMouseCursors.basic,
      builder: (h) => Container(
        key: ValueKey('repo-${r.name}'),
        height: 44,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: h ? colors.hover : null,
          borderRadius: BorderRadius.circular(5),
          border: Border(bottom: BorderSide(color: colors.separator.withValues(alpha: 0.5))),
        ),
        child: Row(children: [
          Expanded(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Flexible(child: Text(r.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600))),
                if (r.hasCredentials)
                  Padding(padding: const EdgeInsets.only(left: 6), child: Tooltip(message: 'Uses credentials from repositories.yaml', child: Icon(Icons.lock_outline, size: 12, color: theme.hintColor))),
                const SizedBox(width: 10),
                Flexible(child: Text(r.url, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11, color: theme.hintColor))),
              ]),
              const SizedBox(height: 2),
              Text(status, style: r.updated == null ? hint?.copyWith(color: severityColor(context, Severity.warn)) : hint),
            ]),
          ),
          if (updating)
            const Padding(padding: EdgeInsets.symmetric(horizontal: 18), child: SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.5)))
          else
            TextButton(style: TextButton.styleFrom(visualDensity: VisualDensity.compact), onPressed: onUpdate, child: const Text('Update')),
          Opacity(
            opacity: h ? 1 : 0.0,
            child: IconButton(
              tooltip: readOnly ? 'This context is read-only' : 'Remove ${r.name}',
              iconSize: 15,
              visualDensity: VisualDensity.compact,
              icon: const Icon(Icons.delete_outline),
              onPressed: readOnly ? null : onRemove,
            ),
          ),
        ]),
      ),
    );
  }
}
