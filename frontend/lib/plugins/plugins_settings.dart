/// The plugin parts of Settings ▸ Integrations (docs/PLUGINS.md §10):
/// Installed's plugin rows (Update, Uninstall, errors inline with
/// file:line) and its Developer group (developer mode, plugin folders,
/// evaluation timings), and Marketplace, the plugin directory to install
/// from. One [PluginsController] holds what they share.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../app/kubeconfig_picker.dart' show NativeFiles;
import '../modules/module.dart';
import '../state/app_state.dart';
import '../ui/settings/integrations_settings.dart';
import '../ui/settings/settings_widgets.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart' show Severity, asMap;
import 'plugin_actions.dart' show showPluginConsent;
import 'plugin_api.dart';
import 'plugin_host.dart';
import 'plugin_notices.dart';

/// A plugin id to install, from a `k8sman://plugins/install?id=<id>`
/// link: Settings ▸ Integrations takes it (Marketplace, asking for
/// consent) when shown.
final pluginInstallRequest = ValueNotifier<String?>(null);

/// The public plugin directory, and where to ask for a plugin.
const pluginDirectorySite = 'https://k8sman.dev/plugins';
const pluginRequestUrl = 'https://github.com/matty234/k8sman-plugins/issues/new?template=plugin-request.yaml';

/// What Installed and Marketplace share while Settings is open: the
/// plugin directory, the plugin being installed, and the last error.
class PluginsController extends ChangeNotifier {
  final ApiClient? api;
  PluginsController(this.api);

  bool busy = false;
  String? error;

  /// The plugin directory (null until fetched), and the plugin being
  /// installed or updated.
  DirectoryState? dir;
  String? installing;

  /// Marketplace's search.
  final search = TextEditingController();
  bool _disposed = false;

  bool get working => busy || installing != null;

  void _changed() {
    if (!_disposed) notifyListeners();
  }

  Future<void> loadDirectory({bool refresh = false}) async {
    final api = this.api;
    if (api == null) return;
    DirectoryState d;
    try {
      d = DirectoryState.fromJson(await api.pluginDirectory(refresh: refresh));
    } on ApiException catch (e) {
      d = DirectoryState(status: 'offline', error: e.message);
    } catch (e) {
      d = DirectoryState(status: 'offline', error: '$e');
    }
    dir = d;
    _changed();
    // This check feeds the update badges and notice too.
    pluginNotices.takeDirectory(d);
  }

  /// Installs or updates plugin [id]. With [hash] (permissions already
  /// agreed to: an update that asks for nothing new) it installs at once;
  /// otherwise the backend answers with what to ask, and it installs on
  /// consent.
  Future<void> install(BuildContext context, String id, {String? hash}) async {
    final api = this.api;
    if (api == null || installing != null) return;
    installing = id;
    error = null;
    _changed();
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
        if (!context.mounted) return;
        if (await showPluginConsent(context, p, install: true) != true) return;
        r = await api.installPlugin(id, permissionsHash: p.permissionsHash);
      }
      if (r['consent'] == null) pluginHost.applyJson(r);
    } on ApiException catch (e) {
      error = e.message;
    } catch (e) {
      error = '$e';
    } finally {
      installing = null;
      _changed();
    }
    await loadDirectory();
  }

  /// Updates directory plugin [d] (asking first when it wants more).
  Future<void> update(BuildContext context, DirectoryPlugin d) => install(context, d.id, hash: d.permissionsChanged ? null : d.permissionsHash);

  Future<void> uninstall(PluginInfo p) async {
    await call((api) => api.uninstallPlugin(p.id));
    await loadDirectory();
  }

  Future<void> call(Future<Map<String, dynamic>> Function(ApiClient api) f) async {
    final api = this.api;
    if (api == null) return;
    busy = true;
    error = null;
    _changed();
    try {
      pluginHost.applyJson(await f(api));
    } on ApiException catch (e) {
      error = e.message;
    } catch (e) {
      error = '$e';
    }
    busy = false;
    _changed();
  }

  Future<void> addFolder(BuildContext context, PluginsState s) async {
    var dir = await NativeFiles.chooseDirectory();
    if (!context.mounted) return;
    dir ??= await _askPath(context);
    if (dir == null || dir.trim().isEmpty) return;
    await call((api) => api.putPluginSettings(devMode: true, devFolders: [...s.devFolders.where((d) => d != dir), dir!.trim()]));
  }

  @override
  void dispose() {
    _disposed = true;
    search.dispose();
    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Installed
// ---------------------------------------------------------------------------

/// Installed ▸ Plugins, under the Plugins switch: a row per plugin of the
/// user's own (from the directory, or unpacked), and automatic updates.
List<SettingItem> installedPluginItems(PluginsController c, ModuleExpansion expansion) {
  final own = [for (final p in pluginHost.state.plugins) if (!p.bundled) p];
  return [
    for (final p in own)
      SettingItem(
        key: ValueKey('plugin-${p.id}-${p.dir}'),
        group: 'Plugins',
        label: p.name,
        description: p.description,
        keywords: [p.id, 'plugin', 'installed', 'update', 'uninstall', if (p.fromDirectory) 'directory' else 'unpacked'],
        builder: (_) => PluginRow(plugin: p, controller: c, expansion: expansion),
      ),
    if (own.isEmpty)
      SettingItem(
        group: 'Plugins',
        label: 'No plugins installed',
        keywords: const ['plugin', 'marketplace', 'browse', 'install'],
        builder: (_) => const _NoPlugins(),
      ),
    SettingItem(
      key: const ValueKey('settings-plugins-auto-update'),
      group: 'Plugins',
      label: 'Install plugin updates automatically',
      description: 'When they don’t ask for new permissions (checked daily). Updates that ask for new permissions always wait for you.',
      keywords: const ['plugin', 'update', 'updates', 'automatic'],
      builder: (_) => _AutoUpdate(c),
    ),
  ];
}

/// Installed ▸ Developer: developer mode and its plugin folders, the
/// bundled plugins' own rows (in developer mode, to compare with the
/// modules they replace), and evaluation timings.
List<SettingItem> developerItems(PluginsController c, ModuleExpansion expansion) {
  final s = pluginHost.state;
  final shown = [for (final p in s.plugins) if (s.devMode || !p.bundled) p];
  return [
    SettingItem(
      key: const ValueKey('settings-plugins-dev-mode'),
      group: 'Developer',
      label: 'Developer mode',
      description: 'Load unpacked plugins from folders on this computer and reload them as you edit.',
      keywords: const ['plugin', 'plugins', 'developer', 'dev', 'unpacked', 'folder', 'load plugin folder', 'reload'],
      builder: (_) => _DeveloperMode(c),
    ),
    if (s.devMode)
      for (final p in s.plugins)
        if (p.bundled)
          SettingItem(
            key: ValueKey('plugin-${p.id}-${p.dir}'),
            group: 'Developer',
            label: p.name,
            description: p.description,
            keywords: [p.id, 'plugin', 'bundled', 'built in', 'compare', 'module'],
            builder: (_) => PluginRow(plugin: p, controller: c, expansion: expansion),
          ),
    if (shown.any((p) => p.loaded))
      SettingItem(
        key: const ValueKey('settings-plugins-timings'),
        group: 'Developer',
        label: 'Timings',
        description: 'How long each plugin took to load, and its evaluations on this cluster.',
        keywords: const ['plugin', 'timings', 'performance', 'evaluation', 'p95', 'latency'],
        builder: (_) => _Timings([for (final p in shown) if (p.loaded) p]),
      ),
  ];
}

class _NoPlugins extends StatelessWidget {
  const _NoPlugins();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(2, 6, 2, 6),
        child: Row(children: [
          Expanded(child: SettingsEmpty('No plugins installed yet.')),
          TextButton(onPressed: () => integrationsPage.value = IntegrationsPage.marketplace, child: const Text('Browse the Marketplace')),
        ]),
      );
}

class _AutoUpdate extends StatelessWidget {
  final PluginsController c;
  const _AutoUpdate(this.c);

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: Listenable.merge([c, pluginHost]),
        builder: (context, _) => SettingRow(
          label: 'Install plugin updates automatically',
          description: 'When they don’t ask for new permissions (checked daily). Updates that ask for new permissions always wait for you.',
          trailing: SettingSwitch(
            key: const ValueKey('plugins-auto-update'),
            value: pluginHost.state.autoUpdate,
            onChanged: c.busy ? null : (v) => c.call((api) => api.putPluginSettings(autoUpdate: v)),
          ),
        ),
      );
}

/// A plugin's row on Installed, in the anatomy of a module's: icon, name
/// with its source and version, description, one status line, and its
/// switch. A directory plugin has Update and Uninstall under it; errors
/// and a withdrawn version show inline. The chevron opens the details:
/// the folder, kinds and permissions.
class PluginRow extends StatelessWidget {
  final PluginInfo plugin;
  final PluginsController controller;
  final ModuleExpansion expansion;
  const PluginRow({super.key, required this.plugin, required this.controller, required this.expansion});

  String get _openId => 'plugin:${plugin.id}:${plugin.dir}';

  /// Switches a bundled plugin and the module it replaces (one or the
  /// other, never both), then reloads the app's module switches.
  Future<void> _useModule(BuildContext context, bool useModule) async {
    final app = context.read<AppState>();
    final ids = {for (final p in pluginHost.state.plugins) if (p.bundled && p.usingModule) p.id};
    useModule ? ids.add(plugin.id) : ids.remove(plugin.id);
    await controller.call((api) => api.putPluginSettings(useModule: [...ids]..sort()));
    await app.loadDisabledModules();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: Listenable.merge([controller, expansion, pluginNotices]), builder: _row);

  Widget _row(BuildContext context, Widget? _) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35);
    final p = plugin;
    final c = controller;
    final busy = c.working;
    final bytes = p.hasIcon ? pluginHost.iconBytes(p.id) : null;
    final entry = p.fromDirectory ? c.dir?.byId(p.id) ?? pluginNotices.updates.where((u) => u.id == p.id).firstOrNull : null;
    final update = entry != null && entry.state == 'update' ? entry : null;
    final source = p.bundled
        ? (p.overridden ? 'built in · overridden' : 'built in')
        : '${p.fromDirectory ? 'directory' : 'unpacked'}${p.overrides ? ' · overrides built in' : ''}';
    final status = p.revoked != null
        ? null
        : p.status == 'error'
            ? ModuleStatus(ModuleState.error, p.loaded ? 'the last reload failed' : 'didn’t load')
            : p.disabled
                ? null
                : p.status == 'warning'
                    ? const ModuleStatus(ModuleState.warning, 'loaded with warnings')
                    : pluginStatus(p, context.read<AppState>().currentContext);
    final footer = <Widget>[
      if (p.revoked != null) InlineMessage('Off: ${p.revoked}', icon: Icons.block),
      if (p.loaded && p.status == 'error') Text('The previous version keeps running until this loads.', style: hint),
      for (final d in p.diags) _DiagView(d),
      if (p.fromDirectory)
        Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (update != null)
            FilledButton.tonal(
              key: ValueKey('plugin-update-${p.id}'),
              onPressed: busy ? null : () => c.update(context, update),
              child: Text(c.installing == p.id ? 'Updating…' : 'Update to ${update.version}${update.permissionsChanged ? '…' : ''}'),
            ),
          TextButton(key: ValueKey('plugin-uninstall-${p.id}'), onPressed: busy ? null : () => c.uninstall(p), child: const Text('Uninstall')),
        ]),
    ];
    return IntegrationRow(
      id: 'plugin-${p.id}',
      name: p.name,
      description: p.description,
      icon: pluginIcon(p),
      image: bytes == null ? null : Image.memory(bytes, width: 18, height: 18),
      on: !p.disabled,
      switchable: p.loaded,
      tag: [if (p.version.isNotEmpty) p.version, source].join(' · '),
      status: status,
      footer: footer,
      onChanged: busy ? null : (v) => c.call((api) => api.setPluginEnabled(p.id, v)),
      formName: 'details',
      settings: (context) => _details(context, p, busy),
      open: expansion.isOpen(_openId),
      onToggleOpen: () => expansion.toggle(_openId),
    );
  }

  Widget _details(BuildContext context, PluginInfo p, bool busy) {
    final colors = AppColors.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (p.dir.isNotEmpty) Text(p.dir, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11, color: colors.faint)),
      if (p.loaded) ...[
        const SizedBox(height: 8),
        _kinds(context, p),
        const SizedBox(height: 8),
        _permissions(context, p, busy),
      ],
      if (p.bundled && p.replacesModule != null)
        SettingRow(
          label: 'Use the built-in module instead',
          description: 'Compare: turns this plugin off and the ${p.replacesModule} module it replaces on (never both).',
          trailing: SettingSwitch(
            key: ValueKey('plugin-use-module-${p.id}'),
            value: p.usingModule,
            onChanged: busy ? null : (v) => _useModule(context, v),
          ),
        ),
    ]);
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
            Flexible(flex: 3, child: Text(k.key, maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5))),
            const SizedBox(width: 8),
            Flexible(flex: 2, child: Text(parts(k), maxLines: 1, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor), overflow: TextOverflow.ellipsis)),
          ]),
        ),
    ]);
  }

  Widget _permissions(BuildContext context, PluginInfo p, bool busy) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    final perms = p.permissions;
    final c = controller;
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
            ? TextButton(onPressed: busy ? null : () => c.call((api) => api.deletePluginConsent(p.id)), child: const Text('Revoke'))
            : TextButton(
                onPressed: busy
                    ? null
                    : () async {
                        final ok = await showPluginConsent(context, p);
                        if (ok == true) await c.call((api) => api.putPluginConsent(p.id, p.permissionsHash));
                      },
                child: const Text('Allow…'),
              ),
      ],
    ]);
  }
}

/// Developer mode, and while it's on the plugin folders, Load plugin
/// folder and Reload.
class _DeveloperMode extends StatelessWidget {
  final PluginsController c;
  const _DeveloperMode(this.c);

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: Listenable.merge([c, pluginHost]), builder: _build);

  Widget _build(BuildContext context, Widget? _) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35);
    final s = pluginHost.state;
    final busy = c.busy;
    final notes = [
      if (s.flagFolders.isNotEmpty) 'On: the backend was started with --plugin-dev ${s.flagFolders.join(', ')}',
      if (s.devMode && s.installedDir.isNotEmpty) 'Plugins in ${s.installedDir} load too.',
      if (s.devMode && !s.plugins.any((p) => !p.bundled)) 'No plugins loaded. Load a folder with a plugin.yaml (see examples/plugins).',
    ];
    return SettingRow(
      label: 'Developer mode',
      description: 'Load unpacked plugins from folders on this computer and reload them as you edit. Plugins from the Marketplace load without it.',
      trailing: SettingSwitch(
        key: const ValueKey('plugins-dev-mode'),
        value: s.devModeSaved || s.flagFolders.isNotEmpty,
        onChanged: busy || s.flagFolders.isNotEmpty ? null : (v) => c.call((api) => api.putPluginSettings(devMode: v)),
      ),
      child: !s.devMode && notes.isEmpty
          ? null
          : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (s.devMode) ...[
                for (final d in s.devFolders)
                  Row(children: [
                    Icon(Icons.folder_outlined, size: 15, color: theme.hintColor),
                    const SizedBox(width: 8),
                    Expanded(child: Text(d, maxLines: 1, style: monoStyle(context, size: 11.5), overflow: TextOverflow.ellipsis)),
                    IconButton(
                      tooltip: 'Remove this folder',
                      iconSize: 15,
                      visualDensity: VisualDensity.compact,
                      icon: const Icon(Icons.close),
                      onPressed: busy ? null : () => c.call((api) => api.putPluginSettings(devFolders: [...s.devFolders.where((x) => x != d)])),
                    ),
                  ]),
                Wrap(spacing: 8, runSpacing: 6, children: [
                  OutlinedButton.icon(
                    key: const ValueKey('plugins-load-folder'),
                    icon: const Icon(Icons.create_new_folder_outlined, size: 16),
                    label: const Text('Load plugin folder…'),
                    onPressed: busy ? null : () => c.addFolder(context, s),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('Reload'),
                    onPressed: busy ? null : () => c.call((api) => api.reloadPlugins()),
                  ),
                ]),
                if (s.readOnly)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: InlineMessage('This context is read-only: plugin shell actions are hidden.', icon: Icons.lock_outline),
                  ),
              ],
              for (final n in notes) Padding(padding: const EdgeInsets.only(top: 6), child: Text(n, style: hint)),
            ]),
    );
  }
}

/// Each plugin's load and compile times and evaluation percentiles.
class _Timings extends StatelessWidget {
  final List<PluginInfo> plugins;
  const _Timings(this.plugins);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontFeatures: const [FontFeature.tabularFigures()]);
    String us(double v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)} ms' : '${v.toStringAsFixed(v < 10 ? 1 : 0)} µs';
    const labels = {'column': 'Columns', 'panel': 'Panels', 'action': 'Actions', 'alert': 'Alerts'};
    return SettingRow(
      label: 'Timings',
      description: 'How long each plugin took to load, and its evaluations on this cluster.',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final (i, p) in plugins.indexed) ...[
          if (i > 0) const SizedBox(height: 8),
          Text(p.name, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
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
        ],
      ]),
    );
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
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Text('${d.where}: ${d.warning ? 'warning: ' : ''}${d.message}', style: mono.copyWith(color: c)),
        if (d.snippet.isNotEmpty) Text('  ${d.snippet}\n  ${' ' * (d.col - 1).clamp(0, 400)}^', style: mono.copyWith(color: Theme.of(context).hintColor)),
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

// ---------------------------------------------------------------------------
// Marketplace
// ---------------------------------------------------------------------------

/// Settings ▸ Integrations ▸ Marketplace: the plugin directory, searchable,
/// with "Suggested for this cluster" first. Its problems (not set up in
/// this build, offline, an expired list) show as one quiet line.
class PluginMarketplace extends StatelessWidget {
  final PluginsController controller;
  const PluginMarketplace({super.key, required this.controller});

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: Listenable.merge([controller, controller.search]), builder: _build);

  Widget _build(BuildContext context, Widget? _) {
    final c = controller;
    final d = c.dir;
    final quiet = switch (d?.status) {
      null => 'Loading the plugin directory…',
      'not-configured' => 'The plugin directory isn’t set up in this build.',
      'offline' => d!.plugins.isEmpty ? 'Can’t reach the plugin directory right now.' : 'Can’t reach the plugin directory: showing the last list.',
      'expired' => 'The plugin directory’s list has expired. Try again later.',
      'invalid' => 'The plugin directory’s list couldn’t be verified, so it isn’t shown.',
      _ => d!.plugins.isEmpty ? 'The plugin directory is empty.' : null,
    };
    final q = c.search.text.trim().toLowerCase();
    // Suggested: on top while not searching, and then not again below.
    final suggested = q.isEmpty ? d?.suggested ?? const <DirectoryPlugin>[] : const <DirectoryPlugin>[];
    final ids = {for (final p in suggested) p.id};
    final all = [
      for (final p in d?.plugins ?? const <DirectoryPlugin>[])
        if (!ids.contains(p.id) && (q.isEmpty || [p.id, p.name, p.description, ...p.kinds, ...p.authors].any((s) => s.toLowerCase().contains(q)))) p,
    ];
    Widget row(DirectoryPlugin p, {required String key, String? why}) => _DirectoryRow(
          key: ValueKey(key),
          plugin: p,
          why: why,
          installing: c.installing == p.id,
          busy: c.working,
          onInstall: () => c.install(context, p.id, hash: p.state == 'update' && !p.permissionsChanged ? p.permissionsHash : null),
        );
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (d != null && d.plugins.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 22),
          child: TextField(
            key: const ValueKey('plugins-browse-search'),
            controller: c.search,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 15), hintText: 'Search plugins', isDense: true),
          ),
        ),
      if (suggested.isNotEmpty) ...[
        const SettingsGroupTitle('Suggested for this cluster', key: ValueKey('plugins-suggested')),
        SettingsCard(children: [for (final p in suggested) row(p, key: 'plugin-suggested-${p.id}', why: p.matchReason)]),
        const SizedBox(height: 26),
      ],
      SettingsGroupTitle(
        suggested.isEmpty ? 'Plugins' : 'All plugins',
        trailing: SizedBox(
          height: 22,
          child: IconButton(
            tooltip: 'Check the plugin directory again',
            iconSize: 14,
            padding: EdgeInsets.zero,
            visualDensity: VisualDensity.compact,
            icon: const Icon(Icons.refresh),
            onPressed: () => c.loadDirectory(refresh: true),
          ),
        ),
      ),
      if (quiet != null) Tooltip(message: d?.error ?? '', child: SettingsEmpty(quiet)),
      if (all.isNotEmpty) SettingsCard(children: [for (final p in all) row(p, key: 'plugin-dir-${p.id}')]),
      if (all.isEmpty && q.isNotEmpty) SettingsEmpty('No plugins match “${c.search.text.trim()}”.'),
      const SizedBox(height: 18),
      Wrap(spacing: 4, runSpacing: 4, children: [
        TextButton.icon(
          key: const ValueKey('plugins-directory-site'),
          icon: const Icon(Icons.open_in_new, size: 14),
          label: const Text('k8sman.dev/plugins'),
          onPressed: () => openUrl(pluginDirectorySite),
        ),
        TextButton.icon(
          key: const ValueKey('plugins-request'),
          icon: const Icon(Icons.add_comment_outlined, size: 14),
          label: const Text('Request a plugin'),
          onPressed: () => openUrl(pluginRequestUrl),
        ),
      ]),
    ]);
  }
}

/// One plugin in Marketplace: icon, name and version, why it's suggested,
/// description, kinds and authors, and its state (Built in, Installed,
/// Update, Install).
class _DirectoryRow extends StatelessWidget {
  final DirectoryPlugin plugin;
  final bool installing;
  final bool busy;
  final VoidCallback onInstall;

  /// Why it's suggested ("This cluster has …"), or null.
  final String? why;
  const _DirectoryRow({super.key, required this.plugin, required this.installing, required this.busy, required this.onInstall, this.why});

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
            'incompatible' => ConstrainedBox(constraints: const BoxConstraints(maxWidth: 160), child: Text(p.reason, maxLines: 2, overflow: TextOverflow.ellipsis, style: hint)),
            _ => FilledButton(key: ValueKey('plugin-install-${p.id}'), onPressed: busy ? null : onInstall, child: const Text('Install')),
          };
    final about = [
      if (p.kinds.isNotEmpty) p.kinds.map((k) => k.split('/').last).join(', '),
      if (p.authors.isNotEmpty) 'by ${p.authors.join(', ')}',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 12, 2, 12),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: p.icon.isEmpty ? fallback : Image.network(p.icon, width: 18, height: 18, errorBuilder: (_, _, _) => fallback),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Flexible(child: Text(p.name, maxLines: 1, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis)),
              const SizedBox(width: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 160),
                child: Text(p.state == 'update' ? '${p.installedVersion} → ${p.version}' : p.version,
                    maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: colors.faint)),
              ),
            ]),
            if (why case final w? when w.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 2), child: Text(w, maxLines: 1, overflow: TextOverflow.ellipsis, style: hint?.copyWith(color: theme.colorScheme.primary))),
            if (p.description.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 2), child: Text(p.description, style: hint)),
            if (about.isNotEmpty)
              Padding(padding: const EdgeInsets.only(top: 3), child: Text(about, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: colors.faint, fontSize: 11.5))),
            if (p.state == 'update' && p.permissionsChanged)
              Padding(padding: const EdgeInsets.only(top: 2), child: Text('This version asks for new permissions.', style: hint)),
          ]),
        ),
        const SizedBox(width: 16),
        state,
      ]),
    );
  }
}
