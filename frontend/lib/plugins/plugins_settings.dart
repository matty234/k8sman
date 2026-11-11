/// Settings ▸ Integrations ▸ Plugins: developer mode, the plugin folders,
/// every plugin with its errors (file:line, inline) and evaluation
/// timings, and Browse: the plugin directory, to install, update and
/// uninstall plugins (docs/PLUGINS.md §10).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../app/kubeconfig_picker.dart' show NativeFiles;
import '../state/app_state.dart';
import '../ui/settings/settings_widgets.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart' show Severity, asMap;
import 'plugin_api.dart';
import 'plugin_host.dart';
import 'plugin_notices.dart';
import 'plugin_actions.dart' show showPluginConsent;

/// A plugin id to install, from a `k8sman://plugins/install?id=<id>`
/// link: the Plugins settings take it (and ask for consent) when shown.
final pluginInstallRequest = ValueNotifier<String?>(null);

class PluginsSettings extends StatefulWidget {
  const PluginsSettings({super.key});

  @override
  State<PluginsSettings> createState() => _PluginsSettingsState();
}

class _PluginsSettingsState extends State<PluginsSettings> {
  bool _busy = false;
  String? _error;

  /// The plugin directory (null until fetched), the Browse search, and
  /// the plugin being installed.
  DirectoryState? _dir;
  final _search = TextEditingController();
  String? _installing;
  final _browseKey = GlobalKey(debugLabel: 'plugins-browse');

  @override
  void initState() {
    super.initState();
    final api = context.read<ApiClient?>();
    if (api != null) {
      pluginHost.attach(api);
      pluginHost.refresh();
    }
    // Opening the page checks the directory (and so for updates).
    _loadDirectory(refresh: true);
    pluginInstallRequest.addListener(_takeInstallRequest);
    pluginBrowseRequest.addListener(_takeBrowseRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _takeInstallRequest();
      _takeBrowseRequest();
    });
  }

  @override
  void dispose() {
    pluginInstallRequest.removeListener(_takeInstallRequest);
    pluginBrowseRequest.removeListener(_takeBrowseRequest);
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadDirectory({bool refresh = false}) async {
    final api = context.read<ApiClient?>();
    if (api == null) return;
    DirectoryState d;
    try {
      d = DirectoryState.fromJson(await api.pluginDirectory(refresh: refresh));
    } on ApiException catch (e) {
      d = DirectoryState(status: 'offline', error: e.message);
    } catch (e) {
      d = DirectoryState(status: 'offline', error: '$e');
    }
    if (mounted) setState(() => _dir = d);
    // The page's own check feeds the update badges and notice.
    pluginNotices.takeDirectory(d);
  }

  /// A notice's Review: Browse, once the settings form has opened.
  void _takeBrowseRequest() {
    if (!pluginBrowseRequest.value || !mounted) return;
    pluginBrowseRequest.value = false;
    Future<void>.delayed(const Duration(milliseconds: 250), () {
      final c = _browseKey.currentContext;
      if (c != null && c.mounted) Scrollable.ensureVisible(c, alignment: 0.05, duration: const Duration(milliseconds: 200));
    });
  }

  void _takeInstallRequest() {
    final id = pluginInstallRequest.value;
    if (id == null || !mounted) return;
    pluginInstallRequest.value = null;
    _install(id);
  }

  /// Installs or updates plugin [id]. With [hash] (permissions already
  /// agreed to: an update that asks for nothing new) it installs at once;
  /// otherwise the backend answers with what to ask, and it installs on
  /// consent.
  Future<void> _install(String id, {String? hash}) async {
    final api = context.read<ApiClient?>();
    if (api == null || _installing != null) return;
    setState(() {
      _installing = id;
      _error = null;
    });
    try {
      var r = await api.installPlugin(id, permissionsHash: hash);
      if (r['consent'] != null) {
        final c = asMap(r['consent']);
        final p = PluginInfo(
          id: id,
          name: '${c['name'] ?? id}',
          version: '${c['version'] ?? ''}',
          permissions: PluginPermissions.fromJson(asMap(c['permissions'])),
          permissionsHash: '${c['permissionsHash'] ?? ''}',
        );
        if (!mounted) return;
        if (await showPluginConsent(context, p, install: true) != true) return;
        r = await api.installPlugin(id, permissionsHash: p.permissionsHash);
      }
      if (r['consent'] == null) pluginHost.applyJson(r);
    } on ApiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = '$e';
    } finally {
      if (mounted) setState(() => _installing = null);
    }
    await _loadDirectory();
  }

  Future<void> _uninstall(PluginInfo p) async {
    await _call((api) => api.uninstallPlugin(p.id));
    await _loadDirectory();
  }

  Future<void> _call(Future<Map<String, dynamic>> Function(ApiClient api) f) async {
    final api = context.read<ApiClient?>();
    if (api == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      pluginHost.applyJson(await f(api));
    } on ApiException catch (e) {
      _error = e.message;
    } catch (e) {
      _error = '$e';
    }
    if (mounted) setState(() => _busy = false);
  }

  Future<void> _addFolder(PluginsState s) async {
    var dir = await NativeFiles.chooseDirectory();
    if (!mounted) return;
    dir ??= await _askPath(context);
    if (dir == null || dir.trim().isEmpty) return;
    await _call((api) => api.putPluginSettings(devMode: true, devFolders: [...s.devFolders.where((d) => d != dir), dir!.trim()]));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35);
    return ListenableBuilder(
      listenable: pluginHost,
      builder: (context, _) {
        final s = pluginHost.state;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SettingRow(
            label: 'Developer mode',
            description: 'Load unpacked plugins from folders on this computer and reload them as you edit. Plugins from the directory (Browse) load without it.',
            trailing: SettingSwitch(
              key: const ValueKey('plugins-dev-mode'),
              value: s.devModeSaved || s.flagFolders.isNotEmpty,
              onChanged: _busy || s.flagFolders.isNotEmpty ? null : (v) => _call((api) => api.putPluginSettings(devMode: v)),
            ),
          ),
          if (s.flagFolders.isNotEmpty) Text('On: the backend was started with --plugin-dev ${s.flagFolders.join(', ')}', style: hint),
          if (s.devMode) ...[
            const SizedBox(height: 4),
            for (final d in s.devFolders)
              Row(children: [
                Icon(Icons.folder_outlined, size: 15, color: theme.hintColor),
                const SizedBox(width: 8),
                Expanded(child: Text(d, style: monoStyle(context, size: 11.5), overflow: TextOverflow.ellipsis)),
                IconButton(
                  tooltip: 'Remove this folder',
                  iconSize: 15,
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close),
                  onPressed: _busy ? null : () => _call((api) => api.putPluginSettings(devFolders: [...s.devFolders.where((x) => x != d)])),
                ),
              ]),
            const SizedBox(height: 6),
            Wrap(spacing: 8, runSpacing: 6, children: [
              OutlinedButton.icon(
                key: const ValueKey('plugins-load-folder'),
                icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                label: const Text('Load plugin folder…'),
                onPressed: _busy ? null : () => _addFolder(s),
              ),
              TextButton.icon(
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('Reload'),
                onPressed: _busy ? null : () => _call((api) => api.reloadPlugins()),
              ),
            ]),
            if (s.installedDir.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text('Plugins in ${s.installedDir} load too.', style: hint),
            ],
          ],
          if (_error != null) Padding(padding: const EdgeInsets.only(top: 8), child: InlineMessage(_error!, isError: true)),
          if (s.devMode && s.readOnly)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: InlineMessage('This context is read-only: plugin shell actions are hidden.', icon: Icons.lock_outline),
            ),
          const SizedBox(height: 10),
          if (s.devMode && !s.plugins.any((p) => !p.bundled)) Text('No plugins loaded. Load a folder with a plugin.yaml (see examples/plugins).', style: hint),
          // Bundled plugins have their own rows under Integrations; here
          // only in dev mode, with their timings and the module comparison.
          for (final p in s.plugins)
            if (s.devMode || !p.bundled)
              _PluginCard(
                key: ValueKey('plugin-${p.dir}'),
                plugin: p,
                state: s,
                busy: _busy || _installing != null,
                call: _call,
                update: p.fromDirectory ? _dir?.byId(p.id) : null,
                onUpdate: (d) => _install(d.id, hash: d.permissionsChanged ? null : d.permissionsHash),
                onUninstall: () => _uninstall(p),
              ),
          const SizedBox(height: 12),
          SettingRow(
            label: 'Install plugin updates automatically',
            description: 'When they don’t ask for new permissions (checked daily). Updates that ask for new permissions always wait for you.',
            trailing: SettingSwitch(
              key: const ValueKey('plugins-auto-update'),
              value: s.autoUpdate,
              onChanged: _busy ? null : (v) => _call((api) => api.putPluginSettings(autoUpdate: v)),
            ),
          ),
          const SizedBox(height: 12),
          _browse(context),
        ]);
      },
    );
  }
}

extension on _PluginsSettingsState {
  /// Browse: the plugin directory, searchable. Its problems (not set up
  /// in this build, offline, an expired list) show as one quiet line.
  Widget _browse(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35);
    final d = _dir;
    final quiet = switch (d?.status) {
      null => 'Loading the plugin directory…',
      'not-configured' => 'The plugin directory isn’t set up in this build.',
      'offline' => d!.plugins.isEmpty ? 'Can’t reach the plugin directory right now.' : 'Can’t reach the plugin directory: showing the last list.',
      'expired' => 'The plugin directory’s list has expired. Try again later.',
      'invalid' => 'The plugin directory’s list couldn’t be verified, so it isn’t shown.',
      _ => d!.plugins.isEmpty ? 'The plugin directory is empty.' : null,
    };
    void install(DirectoryPlugin p) => _install(p.id, hash: p.state == 'update' && !p.permissionsChanged ? p.permissionsHash : null);
    return Column(key: _browseKey, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SettingsGroupTitle(
        'Browse',
        trailing: IconButton(
          tooltip: 'Check the plugin directory again',
          iconSize: 15,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.refresh),
          onPressed: () => _loadDirectory(refresh: true),
        ),
      ),
      if (d != null && d.plugins.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: TextField(
            key: const ValueKey('plugins-browse-search'),
            controller: _search,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 15), hintText: 'Search plugins', isDense: true),
          ),
        ),
      if (quiet != null) Tooltip(message: d?.error ?? '', child: Text(quiet, style: hint)),
      ListenableBuilder(
        listenable: _search,
        builder: (context, _) {
          final q = _search.text.trim().toLowerCase();
          // Suggested for this cluster: on top, while not searching (and
          // then not again in the list below).
          final suggested = q.isEmpty ? d?.suggested ?? const <DirectoryPlugin>[] : const <DirectoryPlugin>[];
          final ids = {for (final p in suggested) p.id};
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (suggested.isNotEmpty) ...[
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Suggested for this cluster', key: const ValueKey('plugins-suggested'), style: theme.textTheme.titleSmall),
              ),
              for (final p in suggested)
                _DirectoryCard(
                  key: ValueKey('plugin-suggested-${p.id}'),
                  plugin: p,
                  why: p.matchReason,
                  installing: _installing == p.id,
                  busy: _busy || _installing != null,
                  onInstall: () => install(p),
                ),
              Padding(padding: const EdgeInsets.only(top: 14), child: Text('All plugins', style: theme.textTheme.titleSmall)),
            ],
            for (final p in d?.plugins ?? const <DirectoryPlugin>[])
              if (!ids.contains(p.id) && (q.isEmpty || [p.id, p.name, p.description, ...p.kinds, ...p.authors].any((s) => s.toLowerCase().contains(q))))
                _DirectoryCard(
                  key: ValueKey('plugin-dir-${p.id}'),
                  plugin: p,
                  installing: _installing == p.id,
                  busy: _busy || _installing != null,
                  onInstall: () => install(p),
                ),
          ]);
        },
      ),
    ]);
  }
}

/// One plugin in Browse: icon, name, version, description, kinds and
/// authors, and its state (Built in, Installed, Update, Install).
class _DirectoryCard extends StatelessWidget {
  final DirectoryPlugin plugin;
  final bool installing;
  final bool busy;
  final VoidCallback onInstall;

  /// Why it's suggested ("This cluster has …"), or null.
  final String? why;
  const _DirectoryCard({super.key, required this.plugin, required this.installing, required this.busy, required this.onInstall, this.why});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final p = plugin;
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35);
    final fallback = Icon(Icons.extension_outlined, size: 18, color: theme.hintColor);
    final Widget state = installing
        ? Row(mainAxisSize: MainAxisSize.min, children: [
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
            const SizedBox(width: 8),
            Text(p.state == 'update' ? 'Updating…' : 'Installing…', style: hint),
          ])
        : switch (p.state) {
            'builtin' => const Chipish(text: 'Built in'),
            'installed' => const Chipish(text: 'Installed'),
            'update' => FilledButton.tonal(onPressed: busy ? null : onInstall, child: Text('Update to ${p.version}')),
            'incompatible' => Text(p.reason, style: hint),
            _ => FilledButton(key: ValueKey('plugin-install-${p.id}'), onPressed: busy ? null : onInstall, child: const Text('Install')),
          };
    final about = [
      if (p.kinds.isNotEmpty) p.kinds.map((k) => k.split('/').last).join(', '),
      if (p.authors.isNotEmpty) 'by ${p.authors.join(', ')}',
    ].join(' · ');
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: colors.separator), borderRadius: BorderRadius.circular(8)),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: p.icon.isEmpty ? fallback : Image.network(p.icon, width: 18, height: 18, errorBuilder: (_, _, _) => fallback),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(p.name, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 6),
              Text(p.state == 'update' ? '${p.installedVersion} → ${p.version}' : p.version, style: hint),
            ]),
            if (why case final w? when w.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 2), child: Text(w, style: hint?.copyWith(color: theme.colorScheme.primary))),
            if (p.description.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: Text(p.description, style: theme.textTheme.bodySmall)),
            if (about.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(about, style: hint)),
            if (p.state == 'update' && p.permissionsChanged)
              Padding(padding: const EdgeInsets.only(top: 2), child: Text('This version asks for new permissions.', style: hint)),
          ]),
        ),
        const SizedBox(width: 10),
        state,
      ]),
    );
  }
}

Future<String?> _askPath(BuildContext context) {
  final c = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Load plugin folder'),
      content: SizedBox(
        width: 460,
        child: TextField(
          controller: c,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder (absolute path)', hintText: '/path/to/my-plugin'),
          onSubmitted: (v) => Navigator.pop(context, v),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, c.text), child: const Text('Load')),
      ],
    ),
  );
}

class _PluginCard extends StatelessWidget {
  final PluginInfo plugin;
  final PluginsState state;
  final bool busy;
  final Future<void> Function(Future<Map<String, dynamic>> Function(ApiClient api) f) call;

  /// A directory plugin's entry in the directory (for Update), and its
  /// Update and Uninstall.
  final DirectoryPlugin? update;
  final void Function(DirectoryPlugin d) onUpdate;
  final VoidCallback onUninstall;
  const _PluginCard({
    super.key,
    required this.plugin,
    required this.state,
    required this.busy,
    required this.call,
    this.update,
    required this.onUpdate,
    required this.onUninstall,
  });

  /// Switches a bundled plugin and the module it replaces (one or the
  /// other, never both), then reloads the app's module switches.
  Future<void> _useModule(BuildContext context, bool useModule) async {
    final app = context.read<AppState>();
    final ids = {for (final p in state.plugins) if (p.bundled && p.usingModule) p.id};
    useModule ? ids.add(plugin.id) : ids.remove(plugin.id);
    await call((api) => api.putPluginSettings(useModule: [...ids]..sort()));
    await app.loadDisabledModules();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final p = plugin;
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35);
    final sev = switch (p.status) { 'error' => Severity.error, 'warning' => Severity.warn, _ => Severity.ok };
    final icon = p.hasIcon ? pluginHost.iconBytes(p.id) : null;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(border: Border.all(color: colors.separator), borderRadius: BorderRadius.circular(8)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          icon != null ? Image.memory(icon, width: 18, height: 18) : Icon(Icons.extension_outlined, size: 18, color: theme.hintColor),
          const SizedBox(width: 10),
          Flexible(child: Text(p.name, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          const SizedBox(width: 6),
          if (p.version.isNotEmpty) Text(p.version, style: hint),
          const SizedBox(width: 8),
          Chipish(
              text: p.bundled
                  ? (p.overridden ? 'Built in · overridden' : 'Built in')
                  : '${p.fromDirectory ? 'Directory' : 'Unpacked'}${p.overrides ? ' · overrides built in' : ''}'),
          const SizedBox(width: 8),
          StatusBadge(switch (p.status) { 'error' => p.loaded ? 'Reload failed' : 'Error', 'warning' => 'Warnings', _ => 'Loaded' }, severity: sev),
          const Spacer(),
          if (p.loaded)
            SettingSwitch(
              key: ValueKey('plugin-enabled-${p.id}'),
              value: !p.disabled,
              onChanged: busy ? null : (v) => call((api) => api.setPluginEnabled(p.id, v)),
            ),
        ]),
        if (p.description.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(p.description, style: theme.textTheme.bodySmall)),
        Padding(padding: const EdgeInsets.only(top: 4), child: Text(p.dir, style: monoStyle(context, size: 11, color: colors.faint))),
        if (p.revoked != null) Padding(padding: const EdgeInsets.only(top: 6), child: InlineMessage('Off: ${p.revoked}', icon: Icons.block)),
        if (p.fromDirectory)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Wrap(spacing: 8, children: [
              if (update case final d? when d.state == 'update')
                FilledButton.tonal(onPressed: busy ? null : () => onUpdate(d), child: Text('Update to ${d.version}${d.permissionsChanged ? '…' : ''}')),
              TextButton(key: ValueKey('plugin-uninstall-${p.id}'), onPressed: busy ? null : onUninstall, child: const Text('Uninstall')),
            ]),
          ),
        if (p.loaded && p.status == 'error')
          Padding(padding: const EdgeInsets.only(top: 6), child: Text('The previous version keeps running until this loads.', style: hint)),
        if (p.bundled && p.replacesModule != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: SettingRow(
              label: 'Use the built-in module instead',
              description: 'Compare: turns this plugin off and the ${p.replacesModule} module it replaces on (never both).',
              trailing: SettingSwitch(
                key: ValueKey('plugin-use-module-${p.id}'),
                value: p.usingModule,
                onChanged: busy ? null : (v) => _useModule(context, v),
              ),
            ),
          ),
        if (p.diags.isNotEmpty) ...[
          const SizedBox(height: 8),
          for (final d in p.diags) _DiagView(d),
        ],
        if (p.loaded) ...[
          const SizedBox(height: 10),
          _kinds(context, p),
          const SizedBox(height: 8),
          _permissions(context, p),
          const SizedBox(height: 8),
          _timings(context, p),
        ],
      ]),
    );
  }

  Widget _kinds(BuildContext context, PluginInfo p) {
    final theme = Theme.of(context);
    String parts(PluginKind k) => [
          if (k.columns > 0) '${k.columns} column${k.columns == 1 ? '' : 's'}',
          if (k.sections > 0) '${k.sections} section${k.sections == 1 ? '' : 's'}',
          if (k.actions > 0) '${k.actions} action${k.actions == 1 ? '' : 's'}',
          if (k.alerts > 0) '${k.alerts} alert${k.alerts == 1 ? '' : 's'}',
          if (k.related > 0) '${k.related} related',
          if (k.metrics > 0) '${k.metrics} metric${k.metrics == 1 ? '' : 's'}',
        ].join(' · ');
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final k in p.kinds)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 1),
          child: Row(children: [
            Tooltip(
              message: k.served ? 'Active: this cluster serves the kind' : 'Inactive: this cluster doesn’t serve the kind',
              child: StatusBadge(k.errors > 0 ? 'errors' : (k.served ? 'active' : 'not on cluster'), dense: true, severity: k.errors > 0 ? Severity.error : (k.served ? Severity.ok : Severity.neutral)),
            ),
            const SizedBox(width: 8),
            Text(k.key, style: monoStyle(context, size: 11.5)),
            const SizedBox(width: 8),
            Flexible(child: Text(parts(k), style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor), overflow: TextOverflow.ellipsis)),
          ]),
        ),
    ]);
  }

  Widget _permissions(BuildContext context, PluginInfo p) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final perms = p.permissions;
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(
        child: Text(
          'Reads ${perms.read.isEmpty ? 'nothing' : perms.read.map((k) => k == '*' ? 'every object you inspect' : k).join(', ')}. Runs ${perms.commands.isEmpty ? 'nothing' : perms.commands.join(', ')} on this computer.',
          style: hint,
        ),
      ),
      if (perms.commands.isNotEmpty) ...[
        const SizedBox(width: 8),
        p.consented
            ? TextButton(onPressed: busy ? null : () => call((api) => api.deletePluginConsent(p.id)), child: const Text('Revoke'))
            : TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        final ok = await showPluginConsent(context, p);
                        if (ok == true) await call((api) => api.putPluginConsent(p.id, p.permissionsHash));
                      },
                child: const Text('Allow…'),
              ),
      ],
    ]);
  }

  Widget _timings(BuildContext context, PluginInfo p) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontFeatures: const [FontFeature.tabularFigures()]);
    String us(double v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)} ms' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} µs';
    const labels = {'column': 'Columns', 'panel': 'Panels', 'action': 'Actions', 'alert': 'Alerts'};
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Load ${p.loadMs.toStringAsFixed(1)} ms · compile ${p.compileMs.toStringAsFixed(1)} ms', style: hint),
      for (final e in labels.entries)
        if (p.stats[e.key] case final st? when st.count > 0)
          Text(
            '${e.value}: ${st.count} evaluations · p50 ${us(st.p50us)} · p95 ${us(st.p95us)} · max ${us(st.maxUs)}'
            '${st.errors > 0 ? ' · ${st.errors} errors' : ''}${st.limitHits > 0 ? ' · ${st.limitHits} over a limit' : ''}',
            key: ValueKey('plugin-stats-${p.id}-${e.key}'),
            style: hint,
          ),
      if (p.stats['budget'] case final st? when st.count > 0)
        Text('"*" lookups skipped over budget: ${st.count} inspections', key: ValueKey('plugin-stats-${p.id}-budget'), style: hint),
    ]);
  }
}

/// One problem: "plugin.yaml:12:5: message", the line and a caret.
class _DiagView extends StatelessWidget {
  final PluginDiag d;
  const _DiagView(this.d);

  @override
  Widget build(BuildContext context) {
    final c = severityColor(context, d.warning ? Severity.warn : Severity.error);
    final mono = monoStyle(context, size: 11);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${d.where}: ${d.warning ? 'warning: ' : ''}${d.message}', style: mono.copyWith(color: c)),
        if (d.snippet.isNotEmpty) Text('  ${d.snippet}\n  ${' ' * (d.col - 1).clamp(0, 400)}^', style: mono.copyWith(color: Theme.of(context).hintColor)),
      ]),
    );
  }
}
