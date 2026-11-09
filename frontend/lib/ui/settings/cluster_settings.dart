import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../app/kubeconfig_picker.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart' show Severity;
import '../context_badge.dart';
import '../helm/market/artifacthub_setting.dart';
import '../resource_nav.dart' show lockContext;
import '../theme.dart';
import '../security/security_api.dart';
import '../widgets/common.dart';
import 'namespace_settings.dart';
import 'settings_widgets.dart';
import '../../api/error_info.dart' show errorText;

/// Settings ▸ Clusters: the kubeconfig, read-only contexts, namespaces and icons.
List<SettingItem> clusterSettings() => [
      SettingItem.row(
        key: const ValueKey('settings-kubeconfig'),
        group: 'Kubeconfig',
        label: 'Kubeconfig file',
        description: 'Where k8sman finds its contexts. The default follows \$KUBECONFIG, else ~/.kube/config.',
        keywords: const ['kubeconfig', 'file', 'config', 'path', 'choose'],
        child: (_) => const Align(alignment: Alignment.centerLeft, child: KubeconfigPicker(compact: false)),
      ),
      SettingItem.row(
        key: const ValueKey('settings-kubeconfig-files'),
        group: 'Kubeconfig',
        label: 'Recent and found files',
        description: 'Files you used before and ones found in ~/.kube. Pick one to switch to it.',
        keywords: const ['recent', 'kubeconfig', 'files', 'switch'],
        child: (_) => const _KubeconfigFiles(),
      ),
      SettingItem.row(
        key: const ValueKey('settings-read-only'),
        group: 'Contexts',
        label: 'Read-only contexts',
        description: 'A locked context blocks edits, deletes, scaling, Helm changes and exec. Contexts whose names look like production start locked.',
        keywords: const ['read-only', 'readonly', 'lock', 'locked', 'production', 'prod', 'safe', 'context'],
        child: (_) => const _ReadOnlyContexts(),
      ),
      ...namespaceSettings(),
      SettingItem.row(
        key: const ValueKey('settings-link-clusters'),
        group: 'Links',
        label: 'Cluster fingerprints',
        description: 'Shared links name a cluster by this hash of its API server address, so they open in the right context '
            'whatever it is called here. Click one to copy it.',
        keywords: const ['links', 'share', 'fingerprint', 'hash', 'cluster', 'mapping', 'always open'],
        child: (_) => const _LinkClusters(),
      ),
      SettingItem.row(
        key: const ValueKey('settings-security-ignores'),
        group: 'Security',
        label: 'Ignored findings',
        description: 'Security findings you chose to ignore in the current context. Removing a rule brings its findings back.',
        keywords: const ['security', 'ignore', 'ignored', 'findings', 'suppress', 'rules'],
        child: (_) => const _SecurityIgnores(),
      ),
      SettingItem(
        key: const ValueKey('settings-remote-icons'),
        group: 'Icons',
        label: 'Icons from the internet',
        description: 'Custom resource groups can show their project\'s icon, fetched from its Helm chart or website. That tells those sites (and DNS) which CRDs your cluster runs.',
        keywords: const ['icons', 'favicon', 'remote', 'privacy', 'network', 'crd'],
        builder: (_) => const _RemoteIcons(),
      ),
      artifactHubSetting(),
    ];

class _KubeconfigFiles extends StatefulWidget {
  const _KubeconfigFiles();

  @override
  State<_KubeconfigFiles> createState() => _KubeconfigFilesState();
}

class _KubeconfigFilesState extends State<_KubeconfigFiles> {
  @override
  void initState() {
    super.initState();
    // New files show up (quick: local file reads only).
    context.read<AppState>().loadKubeconfigs().catchError((Object _) {});
  }

  Future<void> _use(KubeconfigList list, String path) async {
    final err = await context.read<AppState>().switchKubeconfig(path);
    if (err != null && mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('Could not use ${list.shorten(path)}: $err')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final list = app.kubeconfigs;
    final faint = theme.textTheme.bodySmall?.copyWith(color: colors.faint);
    if (list.candidates.isEmpty) return const SettingsEmpty('No other kubeconfig files found.');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final c in list.candidates)
        SizedBox(
          height: 36,
          child: Row(children: [
            SizedBox(width: 20, child: c.path == list.current ? Icon(Icons.check, size: 14, color: theme.colorScheme.primary) : null),
            Expanded(
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(list.shorten(c.path), maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium),
                Text(
                  c.error ?? _detail(c),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: c.error != null ? faint?.copyWith(color: theme.colorScheme.error) : faint,
                ),
              ]),
            ),
            if (c.path != list.current && c.error == null && c.contexts.isNotEmpty)
              TextButton(onPressed: app.switchingKubeconfig ? null : () => _use(list, c.path), child: const Text('Use')),
          ]),
        ),
    ]);
  }

  static String _detail(KubeconfigCandidate c) {
    final n = c.contexts.length;
    return [
      '$n context${n == 1 ? '' : 's'}',
      switch (c.source) { 'KUBECONFIG' => '\$KUBECONFIG', 'recent' => 'recent', 'default' => 'default', _ => null },
    ].whereType<String>().join(' · ');
  }
}

class _ReadOnlyContexts extends StatelessWidget {
  const _ReadOnlyContexts();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final faint = theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).faint);
    if (app.readOnlyReason == 'flag') return const InlineMessage('The backend was started with --read-only: every context is read-only.');
    if (app.contexts.isEmpty) return const SettingsEmpty('No contexts in this kubeconfig.');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final c in app.contexts)
        SizedBox(
          height: 34,
          child: Row(children: [
            NamedContextBadge(c.name, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: c.name),
                  if (c.name == app.currentContext) TextSpan(text: '   current', style: faint),
                  if (app.readOnlyContexts[c.name] == 'auto') TextSpan(text: '   locked: looks like production', style: faint),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.bodyMedium,
              ),
            ),
            Tooltip(
              message: 'Change icon & colour',
              child: IconButton(
                key: ValueKey('appearance-${c.name}'),
                visualDensity: VisualDensity.compact,
                iconSize: 14,
                icon: const Icon(Icons.edit_outlined),
                onPressed: () => showContextAppearanceDialog(context, c.name),
              ),
            ),
            Icon(app.readOnlyContexts.containsKey(c.name) ? Icons.lock : Icons.lock_open,
                size: 13, color: app.readOnlyContexts.containsKey(c.name) ? severityColor(context, Severity.warn) : AppColors.of(context).faint),
            const SizedBox(width: 6),
            Tooltip(
              message: app.readOnlyContexts.containsKey(c.name) ? 'Read-only' : 'Changes allowed',
              child: SettingSwitch(
                key: ValueKey('read-only-${c.name}'),
                value: app.readOnlyContexts.containsKey(c.name),
                onChanged: (lock) => lockContext(context, c.name, lock),
              ),
            ),
          ]),
        ),
    ]);
  }
}

/// Each context's link fingerprint, then the remembered "always open links
/// for this cluster here" mappings with a remove button each.
class _LinkClusters extends StatelessWidget {
  const _LinkClusters();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final faint = theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).faint);
    final mapped = app.linkClusterMap.entries.toList()..sort((a, b) => a.value.compareTo(b.value));
    if (app.contexts.isEmpty && mapped.isEmpty) return const SettingsEmpty('No contexts in this kubeconfig.');
    Widget row(List<Widget> children) => SizedBox(height: 30, child: Row(children: children));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final c in app.contexts)
        row([
          Expanded(child: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium)),
          if (c.fingerprint case final fp?) Chipish(text: fp, copyValue: fp) else Text('no server', style: faint),
        ]),
      if (mapped.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text('Remembered for links', style: faint),
        for (final e in mapped)
          row([
            Chipish(text: e.key, copyValue: e.key),
            Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: Text('→', style: faint)),
            Expanded(child: Text(e.value, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium)),
            Tooltip(
              message: 'Forget',
              child: IconButton(
                key: ValueKey('forget-link-cluster-${e.key}'),
                visualDensity: VisualDensity.compact,
                iconSize: 14,
                icon: const Icon(Icons.close),
                onPressed: () => app.setLinkCluster(e.key, ''),
              ),
            ),
          ]),
      ],
    ]);
  }
}

/// The current context's Security ignore rules, each with a remove button.
class _SecurityIgnores extends StatefulWidget {
  const _SecurityIgnores();

  @override
  State<_SecurityIgnores> createState() => _SecurityIgnoresState();
}

class _SecurityIgnoresState extends State<_SecurityIgnores> {
  late final SecurityApi _api = SecurityApi(context.read<ApiClient>());
  List<SecIgnoreRule>? _rules;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final r = await _api.ignores();
      if (mounted) setState(() => _rules = r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _remove(SecIgnoreRule r) async {
    try {
      await _api.removeIgnore(r);
    } catch (e) {
      if (mounted) setState(() => _error = e);
      return;
    }
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).faint);
    if (_error != null) return InlineMessage('Could not load ignore rules: $_error', isError: true);
    final rules = _rules;
    if (rules == null) return const SizedBox.shrink();
    if (rules.isEmpty) return const SettingsEmpty('Nothing ignored in this context.');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, r) in rules.indexed)
        SizedBox(
          height: 34,
          child: Row(children: [
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: r.check, style: monoStyle(context, size: 12)),
                  TextSpan(text: '   ${r.scope}', style: theme.textTheme.bodySmall),
                  if (r.reason.isNotEmpty) TextSpan(text: '   ${r.reason}', style: faint),
                ]),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Tooltip(
              message: 'Stop ignoring',
              child: IconButton(
                key: ValueKey('remove-ignore-$i'),
                visualDensity: VisualDensity.compact,
                iconSize: 14,
                icon: const Icon(Icons.close),
                onPressed: () => _remove(r),
              ),
            ),
          ]),
        ),
    ]);
  }
}

/// The remote-icons choice: automatic (local clusters only), on or off.
class _RemoteIcons extends StatefulWidget {
  const _RemoteIcons();

  @override
  State<_RemoteIcons> createState() => _RemoteIconsState();
}

class _RemoteIconsState extends State<_RemoteIcons> {
  ({bool? remoteIcons, bool flag, bool effective})? _state;
  String? _error;

  @override
  void initState() {
    super.initState();
    _run(() => context.read<ApiClient>().getIconSettings());
  }

  Future<void> _run(Future<({bool? remoteIcons, bool flag, bool effective})> Function() f) async {
    try {
      final s = await f();
      if (mounted) {
        setState(() {
          _state = s;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = errorText(e));
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final s = _state;
    final value = switch (s?.remoteIcons) { true => 'on', false => 'off', null => 'auto' };
    final note = s == null
        ? null
        : s.flag
            ? 'Off: the backend was started with --no-remote-icons.'
            : 'Now ${s.effective ? 'on' : 'off'} for ${context.read<AppState>().currentContext}.';
    return SettingRow(
      label: 'Icons from the internet',
      description: 'Custom resource groups can show their project\'s icon, fetched from its Helm chart or website. '
          'That tells those sites (and DNS) which CRDs your cluster runs.${note == null ? '' : ' $note'}',
      trailing: _error != null
          ? Tooltip(message: _error!, child: Text('Unavailable', style: small?.copyWith(color: theme.hintColor)))
          : MenuSelect<String>(
              key: const ValueKey('remote-icons-select'),
              value: s == null ? null : value,
              options: [
                ('auto', Text('Local clusters only', style: small)),
                ('on', Text('Always', style: small)),
                ('off', Text('Never', style: small)),
              ],
              onChanged: (v) {
                if (s == null || s.flag) return;
                _run(() => context.read<ApiClient>().putIconSettings(switch (v) { 'on' => true, 'off' => false, _ => null }));
              },
            ),
    );
  }
}
