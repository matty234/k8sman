import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../modules/modules.dart';
import '../../plugins/plugin_api.dart';
import '../../plugins/plugin_host.dart';
import '../../plugins/plugin_icons.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart' show Severity;
import '../theme.dart';
import '../widgets/common.dart';
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

/// Settings ▸ Integrations: a row per module, and one per bundled plugin
/// (in the place of the module it replaces, else at the end). A module a
/// bundled plugin replaces has no row of its own.
List<SettingItem> integrationSettings(ModuleExpansion expansion, AppState app) {
  final bundled = [for (final p in pluginHost.bundled) if (p.loaded && !p.usingModule) p];
  SettingItem pluginRow(PluginInfo p) => SettingItem(
        key: ValueKey('settings-plugin-${p.id}'),
        group: 'Integrations',
        label: p.name,
        description: p.description,
        keywords: [p.id, 'plugin', 'bundled', 'integration'],
        builder: (_) => BundledPluginTile(plugin: p),
      );
  return [
    for (final m in builtInModules)
      if (app.supersededModules.contains(m.id))
        for (final p in bundled.where((p) => p.replacesModule == m.id)) pluginRow(p)
      else
        SettingItem(
          key: ValueKey('settings-module-${m.id}'),
          group: 'Integrations',
          label: m.name,
          description: m.description,
          keywords: [m.id, 'module', 'plugin', 'integration', for (final p in m.pages) p.label],
          builder: (_) => ModuleTile(module: m, expansion: expansion),
        ),
    for (final p in bundled)
      if (p.replacesModule == null || !app.supersededModules.contains(p.replacesModule)) pluginRow(p),
  ];
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
    final kinds = [for (final k in p.kinds) if (k.key != '*') k];
    final served = kinds.where((k) => k.served).length;
    // The plugin's own status line (its kinds' `status`), when it has one.
    final line = p.disabled || served == 0 || !kinds.any((k) => k.status) ? null : pluginHost.statusOf(p.id, context.read<AppState>().currentContext);
    final status = p.disabled
        ? null
        : served == 0
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
    return IntegrationRow(
      id: p.id,
      name: p.name,
      description: p.description,
      icon: pluginIcons[p.kindIcons.values.firstOrNull] ?? Icons.extension_outlined,
      on: !p.disabled,
      tag: p.overridden ? 'plugin · overridden by a loaded folder' : 'plugin',
      tagTooltip: 'Built in as a plugin (plugin.yaml): its columns, sections and actions come from the same format your own plugins use.',
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
  final bool on;
  final String? tag;
  final String? tagTooltip;
  final ModuleStatus? status;
  final ValueChanged<bool>? onChanged;
  final WidgetBuilder? settings;
  final bool open;
  final VoidCallback? onToggleOpen;
  const IntegrationRow({
    super.key,
    required this.id,
    required this.name,
    required this.description,
    required this.icon,
    required this.on,
    this.tag,
    this.tagTooltip,
    this.status,
    this.onChanged,
    this.settings,
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
          Flexible(flex: 0, child: tagTooltip == null ? tagText : Tooltip(message: tagTooltip!, child: tagText)),
        ],
      ]),
      if (description.isNotEmpty) ...[const SizedBox(height: 2), HighlightedText(description, style: hint)],
      if (status != null) Padding(padding: const EdgeInsets.only(top: 5), child: _StatusLine(status!)),
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
              child: Icon(icon, size: 18, color: on ? theme.hintColor : colors.faint),
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
                      tooltip: open ? 'Hide $name settings' : '$name settings',
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
            SettingSwitch(key: ValueKey('integration-$id'), value: on, onChanged: onChanged),
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
