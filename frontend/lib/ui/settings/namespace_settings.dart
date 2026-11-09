import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../state/app_state.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/namespace_picker.dart';
import 'settings_widgets.dart';
import '../../api/error_info.dart' show errorText;

/// Settings ▸ Clusters ▸ Namespaces: where the current context opens, and
/// the namespaces it is limited to (for multi-tenant clusters).
List<SettingItem> namespaceSettings() => [
      SettingItem(
        key: const ValueKey('settings-default-namespace'),
        group: 'Namespaces',
        label: 'Default namespace',
        description: 'Where the current context opens, and where clearing a selection goes. A namespace you pick in the toolbar still wins until you switch context.',
        keywords: const ['namespace', 'default', 'all namespaces', 'kubeconfig', 'open', 'launch', 'start'],
        builder: (_) => const _DefaultNamespace(),
      ),
      SettingItem(
        key: const ValueKey('settings-allowed-namespaces'),
        group: 'Namespaces',
        label: 'Only show these namespaces',
        description: 'For multi-tenant clusters: the namespace picker offers only these, and All namespaces reads each of them '
            'instead of the whole cluster, so lists you have no access to don\'t fail. Empty shows every namespace.',
        keywords: const ['namespace', 'allowed', 'allowlist', 'restrict', 'tenant', 'multi-tenant', 'access', 'rbac', 'forbidden', 'limit'],
        builder: (_) => const _AllowedNamespaces(),
      ),
    ];

final _dns1123 = RegExp(r'^[a-z0-9]([-a-z0-9]*[a-z0-9])?$');

class _DefaultNamespace extends StatelessWidget {
  const _DefaultNamespace();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final small = Theme.of(context).textTheme.bodySmall;
    final mode = app.defaultNamespaceMode;
    Future<void> save(String mode, List<String> namespaces) async {
      try {
        await app.setDefaultNamespace(mode, namespaces);
      } catch (e) {
        if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Could not save: ${errorText(e)}')));
      }
    }

    final kube = app.kubeconfigNamespace;
    return SettingRow(
      label: 'Default namespace',
      description: 'Where ${app.currentContext.isEmpty ? 'the current context' : app.currentContext} opens, and where clearing a selection goes. '
          'A namespace you pick in the toolbar still wins until you switch context.'
          '${app.scopeChosen ? " Applies next time; you've picked a namespace in this session." : ''}',
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (mode == 'namespaces') ...[
          SizedBox(
            width: 170,
            child: NamespacePicker.scope(
              value: NamespaceScope.of(app.defaultNamespaces),
              onChanged: (s) => s.isAll ? save('all', const []) : save('namespaces', s.namespaces),
            ),
          ),
          const SizedBox(width: 8),
        ],
        MenuSelect<String>(
          key: const ValueKey('default-namespace-select'),
          value: mode,
          options: [
            ('all', Text(app.allNamespacesLabel, style: small)),
            ('kubeconfig', Text(kube == null ? 'From kubeconfig' : 'From kubeconfig ($kube)', style: small)),
            ('namespaces', Text('Specific namespaces', style: small)),
          ],
          onChanged: (v) {
            if (v == mode) return;
            if (v == 'namespaces') {
              // Start from the current selection, else the kubeconfig's.
              final start = app.namespaceScope.isAll ? [?kube ?? app.namespaces.firstOrNull] : app.namespaceScope.namespaces;
              if (start.isNotEmpty) save('namespaces', start);
              return;
            }
            save(v, const []);
          },
        ),
      ]),
    );
  }
}

/// The allowlist: chips with a remove button, a field to add one, and
/// "Suggest from my access".
class _AllowedNamespaces extends StatefulWidget {
  const _AllowedNamespaces();

  @override
  State<_AllowedNamespaces> createState() => _AllowedNamespacesState();
}

class _AllowedNamespacesState extends State<_AllowedNamespaces> {
  final _add = TextEditingController();
  String? _error;
  String? _note;
  bool _suggesting = false;

  @override
  void dispose() {
    _add.dispose();
    super.dispose();
  }

  Future<void> _save(List<String> list) async {
    try {
      await context.read<AppState>().setAllowedNamespaces(list);
      if (mounted) setState(() => _error = null);
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  void _submit(String text) {
    final app = context.read<AppState>();
    final names = [for (final n in text.split(RegExp(r'[\s,]+'))) if (n.isNotEmpty) n.toLowerCase()];
    final bad = names.where((n) => n.length > 63 || !_dns1123.hasMatch(n)).toList();
    if (bad.isNotEmpty) {
      setState(() => _error = 'Not a namespace name: ${bad.join(', ')}');
      return;
    }
    if (names.isEmpty) return;
    _add.clear();
    _save({...app.allowedNamespaces, ...names}.toList());
  }

  Future<void> _suggest() async {
    final app = context.read<AppState>();
    setState(() {
      _suggesting = true;
      _error = null;
      _note = null;
    });
    try {
      final s = await context.read<ApiClient>().suggestAllowedNamespaces();
      if (!mounted) return;
      if (s.namespaces.isEmpty) {
        setState(() => _note = 'You can list pods in none of the ${s.checked} namespaces checked.'
            '${s.listed ? '' : ' Namespaces can\'t be listed here: add yours by hand, then suggest again.'}');
      } else {
        await _save({...app.allowedNamespaces, ...s.namespaces}.toList());
        if (mounted) {
          setState(() => _note = 'Pods can be listed in ${s.namespaces.length} of ${s.checked} namespaces checked.'
              '${s.listed ? '' : ' Namespaces can\'t be listed here, so only ones you added or starred were checked.'}');
        }
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    } finally {
      if (mounted) setState(() => _suggesting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final faint = theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).faint);
    final allowed = app.allowedNamespaces;
    return SettingRow(
      label: 'Only show these namespaces',
      description: 'For multi-tenant clusters: the namespace picker offers only these, and All namespaces reads each of them '
          'instead of the whole cluster, so lists you have no access to don\'t fail. Empty shows every namespace.',
      trailing: Row(mainAxisSize: MainAxisSize.min, children: [
        if (allowed.isNotEmpty) TextButton(key: const ValueKey('allowed-namespaces-clear'), onPressed: () => _save(const []), child: const Text('Clear')),
        Tooltip(
          message: 'Checks which known namespaces you may list pods in (SelfSubjectAccessReview). Nothing is changed in the cluster.',
          child: TextButton.icon(
            key: const ValueKey('allowed-namespaces-suggest'),
            onPressed: _suggesting || app.currentContext.isEmpty ? null : _suggest,
            icon: _suggesting ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)) : const Icon(Icons.auto_fix_high, size: 14),
            label: const Text('Suggest from my access'),
          ),
        ),
      ]),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          for (final n in allowed) _NamespaceChip(n, onRemove: () => _save([for (final x in allowed) if (x != n) x])),
          SizedBox(
            width: 200,
            height: 26,
            child: TextField(
              key: const ValueKey('allowed-namespaces-add'),
              controller: _add,
              style: theme.textTheme.bodySmall,
              onSubmitted: _submit,
              decoration: InputDecoration(
                isDense: true,
                hintText: allowed.isEmpty ? 'Add a namespace, e.g. team-a' : 'Add a namespace',
                prefixIcon: const Icon(Icons.add, size: 14),
                prefixIconConstraints: const BoxConstraints(minWidth: 26),
              ),
            ),
          ),
        ]),
        if (allowed.isEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Every namespace is shown in ${app.currentContext}.', style: faint)),
        if (_note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_note!, style: faint)),
        if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: InlineMessage(_error!, isError: true)),
      ]),
    );
  }
}

class _NamespaceChip extends StatelessWidget {
  final String name;
  final VoidCallback onRemove;
  const _NamespaceChip(this.name, {required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      key: ValueKey('allowed-namespace-$name'),
      height: 24,
      padding: const EdgeInsets.only(left: 8, right: 2),
      decoration: BoxDecoration(color: chipFill(context), borderRadius: BorderRadius.circular(5)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(Icons.folder_outlined, size: 12, color: theme.hintColor),
        const SizedBox(width: 5),
        Text(name, style: monoStyle(context, size: 11.5)),
        Tooltip(
          message: 'Remove',
          child: Hoverable(
            onTap: onRemove,
            builder: (h) => Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close, size: 12, color: h ? theme.colorScheme.onSurface : theme.hintColor),
            ),
          ),
        ),
      ]),
    );
  }
}
