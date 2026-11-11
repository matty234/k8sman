import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../modules/modules.dart';
import '../../plugins/plugin_api.dart';
import '../../plugins/plugin_host.dart';
import '../../plugins/plugin_icons.dart';
import '../../plugins/plugin_notices.dart';
import '../../plugins/plugins_settings.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart' show Severity;
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart' show SectionHeader;
import 'settings_widgets.dart';

/// Which modules' settings forms are open in Settings ▸ Integrations (kept
/// by the page, so a deep link can open one), and where their rows are.
class ModuleExpansion extends ChangeNotifier {
  final Set<String> _open = {};
  final Map<String, GlobalKey> _keys = {};

  bool isOpen(String id) => _open.contains(id);

  void toggle(String id) {
    if (!_open.remove(id)) _open.add(id);
    notifyListeners();
  }

  void open(String id, {bool notify = true}) {
    if (_open.add(id) && notify) notifyListeners();
  }

  /// The row of module [id], for scrolling it into view.
  GlobalKey keyFor(String id) => _keys.putIfAbsent(id, () => GlobalKey(debugLabel: 'module-$id'));
}

/// Integrations' two sub-pages.
enum IntegrationsPage {
  installed('Installed'),
  marketplace('Marketplace');

  final String title;
  const IntegrationsPage(this.title);

  /// The line under the section's title.
  String get intro => switch (this) {
        installed => 'Turn off what you don\'t use: its pages, panels and checks go away on every cluster. Status is for the current cluster.',
        marketplace => 'Plugins from the k8sman plugin directory add columns, inspector sections and actions for more kinds. Each asks before it installs.',
      };
}

/// The sub-page Integrations shows: the last one, for the session.
final integrationsPage = ValueNotifier<IntegrationsPage>(IntegrationsPage.installed);

/// Settings ▸ Integrations ▸ Installed, as searchable items: Built in (a
/// row per module, and one per bundled plugin in the place of the module
/// it replaces, else at the end; a module a bundled plugin replaces has no
/// row of its own), Plugins (the Plugins switch, the user's own plugins
/// and automatic updates) and Developer.
List<SettingItem> integrationSettings(ModuleExpansion expansion, AppState app, PluginsController plugins) {
  final bundled = [for (final p in pluginHost.bundled) if (p.loaded && !p.usingModule) p];
  SettingItem pluginRow(PluginInfo p) => SettingItem(
        key: ValueKey('settings-plugin-${p.id}'),
        group: 'Built in',
        label: p.name,
        description: p.description,
        keywords: [p.id, 'plugin', 'bundled', 'integration', 'installed'],
        builder: (_) => BundledPluginTile(plugin: p),
      );
  SettingItem moduleRow(AppModule m, String group, [List<String> keywords = const []]) => SettingItem(
        key: ValueKey('settings-module-${m.id}'),
        group: group,
        label: m.name,
        description: m.description,
        keywords: [m.id, 'module', 'plugin', 'integration', 'installed', for (final p in m.pages) p.label, ...keywords],
        builder: (_) => ModuleTile(module: m, expansion: expansion),
      );
  final pluginsModule = builtInModules.where((m) => m.id == pluginsModuleId).firstOrNull;
  return [
    for (final m in builtInModules)
      if (m.id != pluginsModuleId)
        if (app.supersededModules.contains(m.id))
          for (final p in bundled.where((p) => p.replacesModule == m.id)) pluginRow(p)
        else
          moduleRow(m, 'Built in'),
    for (final p in bundled)
      if (p.replacesModule == null || !app.supersededModules.contains(p.replacesModule)) pluginRow(p),
    if (pluginsModule != null) moduleRow(pluginsModule, 'Plugins', const ['marketplace', 'browse', 'directory', 'install']),
    ...installedPluginItems(plugins, expansion),
    ...developerItems(plugins, expansion),
  ];
}

/// Installed | Marketplace, with the updates waiting and the plugins
/// suggested for this cluster counted on them.
class IntegrationsPageSwitch extends StatelessWidget {
  const IntegrationsPageSwitch({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = context.select<AppState, String>((a) => a.currentContext);
    return ListenableBuilder(
      listenable: Listenable.merge([integrationsPage, pluginNotices]),
      builder: (context, _) {
        final updates = pluginNotices.updates.length;
        final suggested = pluginNotices.context == current ? pluginNotices.suggested.length : 0;
        Widget label(IntegrationsPage p, int n, String tip) => Row(mainAxisSize: MainAxisSize.min, children: [
              Text(p.title, key: ValueKey('integrations-page-${p.name}')),
              if (n > 0) ...[const SizedBox(width: 6), CountBadge(n, key: ValueKey('integrations-badge-${p.name}'), tooltip: tip)],
            ]);
        return SizedBox(
          height: 24,
          child: SegmentedButton<IntegrationsPage>(
            key: const ValueKey('integrations-page'),
            style: ButtonStyle(
              visualDensity: const VisualDensity(horizontal: -3, vertical: -4),
              padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 10)),
              minimumSize: const WidgetStatePropertyAll(Size(0, 24)),
              textStyle: WidgetStatePropertyAll(theme.textTheme.labelMedium),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: IntegrationsPage.installed,
                label: label(IntegrationsPage.installed, updates, updates == 1 ? 'Update for 1 plugin' : 'Updates for $updates plugins'),
              ),
              ButtonSegment(
                value: IntegrationsPage.marketplace,
                label: label(IntegrationsPage.marketplace, suggested, suggested == 1 ? '1 plugin suggested for this cluster' : '$suggested plugins suggested for this cluster'),
              ),
            ],
            selected: {integrationsPage.value},
            onSelectionChanged: (s) => integrationsPage.value = s.first,
          ),
        );
      },
    );
  }
}

/// The body of Settings ▸ Integrations: Installed's [items] in their
/// groups (Developer last, folded away until opened), or Marketplace.
/// Showing it checks the plugin directory, and takes a plugin link's
/// install request (Marketplace, asking for consent).
class IntegrationsBody extends StatefulWidget {
  final List<SettingItem> items;
  final PluginsController plugins;
  const IntegrationsBody({super.key, required this.items, required this.plugins});

  @override
  State<IntegrationsBody> createState() => _IntegrationsBodyState();
}

class _IntegrationsBodyState extends State<IntegrationsBody> {
  /// Whether Developer is open, for the session.
  static bool _developerOpen = false;

  @override
  void initState() {
    super.initState();
    widget.plugins.loadDirectory(refresh: true);
    pluginInstallRequest.addListener(_takeInstallRequest);
    WidgetsBinding.instance.addPostFrameCallback((_) => _takeInstallRequest());
  }

  @override
  void dispose() {
    pluginInstallRequest.removeListener(_takeInstallRequest);
    super.dispose();
  }

  void _takeInstallRequest() {
    final id = pluginInstallRequest.value;
    if (id == null || !mounted) return;
    pluginInstallRequest.value = null;
    integrationsPage.value = IntegrationsPage.marketplace;
    widget.plugins.install(context, id);
  }

  @override
  Widget build(BuildContext context) {
    final plugins = widget.plugins;
    final pluginsOn = context.select<AppState, bool>((a) => moduleEnabled(pluginsModuleId, a.disabledModules));
    return ListenableBuilder(
      listenable: Listenable.merge([integrationsPage, plugins]),
      builder: (context, _) {
        final page = integrationsPage.value;
        return Column(key: ValueKey('integrations-${page.name}'), crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (plugins.error != null) Padding(padding: const EdgeInsets.only(bottom: 16), child: InlineMessage(plugins.error!, isError: true)),
          if (page == IntegrationsPage.marketplace) ...[
            if (!pluginsOn)
              const Padding(
                padding: EdgeInsets.only(bottom: 16),
                child: InlineMessage('Plugins are off: what you install here stays off until you turn Plugins on under Installed.', icon: Icons.power_settings_new),
              ),
            PluginMarketplace(controller: plugins),
          ] else
            _installed(),
        ]);
      },
    );
  }

  Widget _installed() {
    final developer = [for (final i in widget.items) if (i.group == 'Developer') i];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SettingCards([for (final i in widget.items) if (i.group != 'Developer') i]),
      if (developer.isNotEmpty) ...[
        const SizedBox(height: 26),
        Hoverable(
          key: const ValueKey('integrations-developer'),
          onTap: () => setState(() => _developerOpen = !_developerOpen),
          builder: (h) => Padding(padding: const EdgeInsets.only(bottom: 2), child: SectionHeader(title: 'Developer', expanded: _developerOpen, hovered: h)),
        ),
        SettingsReveal(open: _developerOpen, child: SettingsCard(children: [for (final i in developer) KeyedSubtree(key: i.key, child: Builder(builder: i.builder))])),
      ],
    ]);
  }
}

/// A bundled or installed plugin's icon (its first kind's).
IconData pluginIcon(PluginInfo p) => pluginIcons[p.kindIcons.values.firstOrNull] ?? Icons.extension_outlined;

/// A plugin's status on the current cluster, as a module's: whether the
/// cluster serves its kinds, its errors, or its own status line. Null
/// while it's off.
ModuleStatus? pluginStatus(PluginInfo p, String contextName) {
  if (p.disabled) return null;
  // The plugin's own kinds: its sidebar section's, when it has one (an
  // entry for a core kind, such as /Pod, adds to that kind's panel and
  // doesn't say the integration is installed), else its kind entries.
  final navKinds = p.nav?.kinds.toSet() ?? const <String>{};
  final kinds = [for (final k in p.kinds) if (k.key != '*' && (navKinds.isEmpty || navKinds.contains(k.key))) k];
  final served = kinds.where((k) => k.served).length;
  // The plugin's own status line (its kinds' `status`), when it has one.
  final line = served == 0 || !kinds.any((k) => k.status) ? null : pluginHost.statusOf(p.id, contextName);
  return served == 0
      ? const ModuleStatus(ModuleState.notInstalled)
      : kinds.any((k) => k.errors > 0)
          ? ModuleStatus(ModuleState.error, '${kinds.where((k) => k.errors > 0).length} kinds have plugin errors')
          : line != null && line.text.isNotEmpty
              ? ModuleStatus(switch (line.severity) {
                  'critical' => ModuleState.error,
                  'warning' => ModuleState.warning,
                  _ => line.errors.isNotEmpty ? ModuleState.error : ModuleState.connected,
                }, line.text)
              : line != null && line.errors.isNotEmpty
                  ? ModuleStatus(ModuleState.error, line.errors.first)
                  : ModuleStatus(ModuleState.connected, served == kinds.length ? 'all ${kinds.length} kinds served' : '$served of ${kinds.length} kinds served');
}

/// A module's row: its icon, name and one line on what it adds, its status
/// on the current cluster (a dot and a few words), and the on/off switch
/// on the right. Modules with settings open their form inline under the
/// row (the chevron, or a click on the row). Turning a module on or off
/// applies and saves at once, for every cluster.
class ModuleTile extends StatelessWidget {
  final AppModule module;
  final ModuleExpansion expansion;
  const ModuleTile({super.key, required this.module, required this.expansion});

  static String _nameOf(String id) => builtInModules.where((m) => m.id == id).firstOrNull?.name ?? id;

  /// The module's detected status on the current cluster (null when it
  /// detects nothing, or there's no backend in this tree).
  static ModuleStatus? _statusOf(BuildContext context, AppModule m, AppState app) {
    if (m.detect == null) return null;
    final api = context.read<ApiClient?>();
    return api == null ? null : moduleStatuses.of(m, api, app.currentContext);
  }

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final m = module;
    final disabled = app.disabledModules;
    final on = moduleEnabled(m.id, disabled);
    // Off while a module it needs is off (Add-ons needs Helm).
    final available = m.requires.every((r) => moduleEnabled(r, disabled));
    final settings = m.settingsBuilder;
    final icon = m.pages.isNotEmpty ? m.pages.first.icon : (m.kindIcons.values.firstOrNull ?? Icons.extension_outlined);
    return ListenableBuilder(
      key: expansion.keyFor(m.id),
      listenable: Listenable.merge([moduleStatuses, expansion]),
      builder: (context, _) {
        final canOpen = settings != null && on;
        return IntegrationRow(
          id: m.id,
          name: m.name,
          description: m.description,
          icon: icon,
          on: on,
          tag: m.requires.isEmpty ? null : 'needs ${m.requires.map(_nameOf).join(', ')}',
          status: on ? _statusOf(context, m, app) : null,
          onChanged: available
              ? (v) {
                  final next = {...disabled};
                  v ? next.remove(m.id) : next.add(m.id);
                  app.setDisabledModules(next);
                }
              : null,
          settings: settings,
          open: canOpen && expansion.isOpen(m.id),
          onToggleOpen: canOpen ? () => expansion.toggle(m.id) : null,
        );
      },
    );
  }
}

/// A bundled plugin's row (docs/PLUGINS.md, "Bundled plugins"): like a
/// module's, marked "plugin". Its status is whether the cluster serves its
/// kinds; its switch is the plugin's own (settings.json's plugins.disabled).
class BundledPluginTile extends StatefulWidget {
  final PluginInfo plugin;
  const BundledPluginTile({super.key, required this.plugin});

  @override
  State<BundledPluginTile> createState() => _BundledPluginTileState();
}

class _BundledPluginTileState extends State<BundledPluginTile> {
  bool _busy = false;

  Future<void> _set(bool on) async {
    final api = context.read<ApiClient?>();
    if (api == null) return;
    setState(() => _busy = true);
    try {
      pluginHost.applyJson(await api.setPluginEnabled(widget.plugin.id, on));
    } catch (e) {
      debugPrint('bundled plugin ${widget.plugin.id}: $e');
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(listenable: pluginHost, builder: (context, _) => _row(context));

  Widget _row(BuildContext context) {
    final p = widget.plugin;
    final status = pluginStatus(p, context.read<AppState>().currentContext);
    return IntegrationRow(
      id: p.id,
      name: p.name,
      description: p.description,
      icon: pluginIcon(p),
      on: !p.disabled,
      tag: p.overridden
          ? 'plugin · overridden by a loaded folder'
          : p.moving
              ? 'Built in · moving to Marketplace'
              : 'plugin',
      tagTooltip: p.moving
          ? 'This plugin now ships through the plugin Marketplace. k8sman installs it from there for you, with the same permissions; until then the built-in copy keeps running.'
          : 'Built in as a plugin (plugin.yaml): its columns, sections and actions come from the same format your own plugins use.',
      status: status,
      onChanged: _busy ? null : _set,
    );
  }
}

/// One row of Settings ▸ Integrations: icon, name (with a quiet [tag]),
/// description, [status], an optional settings chevron and the switch.
class IntegrationRow extends StatelessWidget {
  final String id;
  final String name;
  final String description;
  final IconData icon;

  /// Drawn in place of [icon] (a plugin's own icon).
  final Widget? image;
  final bool on;

  /// Whether it has a switch (a plugin that didn't load has none).
  final bool switchable;
  final String? tag;
  final String? tagTooltip;
  final ModuleStatus? status;

  /// Under the status line, always shown (actions, errors).
  final List<Widget> footer;
  final ValueChanged<bool>? onChanged;

  /// The form under the row, opened from the chevron, and what the
  /// chevron's tooltip calls it.
  final WidgetBuilder? settings;
  final String formName;
  final bool open;
  final VoidCallback? onToggleOpen;
  const IntegrationRow({
    super.key,
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    this.image,
    required this.on,
    this.switchable = true,
    this.tag,
    this.tagTooltip,
    this.status,
    this.footer = const [],
    this.onChanged,
    this.settings,
    this.formName = 'settings',
    this.open = false,
    this.onToggleOpen,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35);
    final settings = this.settings;
    final tagText = tag == null ? null : Text(tag!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: colors.faint));
    final text = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Flexible(child: HighlightedText(name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: on ? null : theme.hintColor))),
        if (tagText != null) ...[
          const SizedBox(width: 8),
          ConstrainedBox(constraints: const BoxConstraints(maxWidth: 220), child: tagTooltip == null ? tagText : Tooltip(message: tagTooltip!, child: tagText)),
        ],
      ]),
      if (description.isNotEmpty) ...[const SizedBox(height: 2), HighlightedText(description, style: hint)],
      if (status != null) Padding(padding: const EdgeInsets.only(top: 5), child: _StatusLine(status!)),
      for (final f in footer) Padding(padding: const EdgeInsets.only(top: 6), child: f),
    ]);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Hoverable(
        cursor: onToggleOpen != null ? SystemMouseCursors.click : MouseCursor.defer,
        onTap: onToggleOpen,
        builder: (hovered) => Padding(
          padding: const EdgeInsets.fromLTRB(2, 12, 2, 12),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: image ?? Icon(icon, size: 18, color: on ? theme.hintColor : colors.faint),
            ),
            const SizedBox(width: 12),
            Expanded(child: text),
            const SizedBox(width: 16),
            SizedBox(
              width: 28,
              height: 24,
              child: settings == null
                  ? null
                  : IconButton(
                      key: ValueKey('integration-expand-$id'),
                      tooltip: open ? 'Hide $name $formName' : '$name $formName',
                      iconSize: 18,
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
                      color: hovered || open ? theme.colorScheme.onSurface : theme.hintColor,
                      onPressed: onToggleOpen,
                      icon: AnimatedRotation(
                        turns: open ? 0.25 : 0,
                        duration: (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ? Duration.zero : const Duration(milliseconds: 160),
                        child: const Icon(Icons.chevron_right),
                      ),
                    ),
            ),
            const SizedBox(width: 8),
            SizedBox(width: 40, child: switchable ? SettingSwitch(key: ValueKey('integration-$id'), value: on, onChanged: onChanged) : null),
          ]),
        ),
      ),
      if (settings != null)
        SettingsReveal(
          open: open,
          child: Container(
            key: open ? ValueKey('integration-form-$id') : null,
            margin: const EdgeInsets.fromLTRB(32, 0, 0, 18),
            padding: const EdgeInsets.only(left: 16, top: 2, bottom: 2),
            decoration: BoxDecoration(border: Border(left: BorderSide(color: colors.separator, width: 2))),
            alignment: Alignment.topLeft,
            // Fields keep one comfortable width rather than stretching
            // across a wide window.
            child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: Builder(builder: settings)),
          ),
        ),
    ]);
  }
}

/// "● connected · relay v1.18 · 13 nodes", "○ not on this cluster", …
class _StatusLine extends StatelessWidget {
  final ModuleStatus status;
  const _StatusLine(this.status);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final s = status;
    final (sev, label) = switch (s.state) {
      ModuleState.checking => (Severity.info, 'checking…'),
      ModuleState.notInstalled => (Severity.neutral, 'not on this cluster'),
      ModuleState.connected => (Severity.ok, 'connected'),
      ModuleState.warning => (Severity.warn, 'connected'),
      ModuleState.error => (Severity.error, 'error'),
    };
    final text = [label, if (s.message != null && s.message!.isNotEmpty && s.state != ModuleState.notInstalled) s.message!].join(' · ');
    final quiet = sev == Severity.neutral || sev == Severity.info;
    final c = quiet ? colors.faint : severityColor(context, sev);
    return Tooltip(
      message: s.message ?? '',
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(
          width: 6,
          height: 6,
          decoration: BoxDecoration(shape: BoxShape.circle, color: quiet ? null : c, border: quiet ? Border.all(color: c, width: 1.2) : null),
        ),
        const SizedBox(width: 7),
        Flexible(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.bodySmall?.copyWith(color: sev == Severity.error || sev == Severity.warn ? c : theme.hintColor, fontSize: 11.5),
          ),
        ),
      ]),
    );
  }
}
