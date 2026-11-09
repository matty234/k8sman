import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../modules/modules.dart';
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

/// Settings ▸ Integrations: a row per module.
List<SettingItem> integrationSettings(ModuleExpansion expansion) => [
      for (final m in builtInModules)
        SettingItem(
          key: ValueKey('settings-module-${m.id}'),
          group: 'Integrations',
          label: m.name,
          description: m.description,
          keywords: [m.id, 'module', 'plugin', 'integration', for (final p in m.pages) p.label],
          builder: (_) => ModuleTile(module: m, expansion: expansion),
        ),
    ];

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
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final m = module;
    final disabled = app.disabledModules;
    final on = moduleEnabled(m.id, disabled);
    // Off while a module it needs is off (Add-ons needs Helm).
    final available = m.requires.every((r) => moduleEnabled(r, disabled));
    final settings = m.settingsBuilder;
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, height: 1.35);
    final icon = m.pages.isNotEmpty ? m.pages.first.icon : (m.kindIcons.values.firstOrNull ?? Icons.extension_outlined);
    return ListenableBuilder(
      key: expansion.keyFor(m.id),
      listenable: Listenable.merge([moduleStatuses, expansion]),
      builder: (context, _) {
        final status = on ? _statusOf(context, m, app) : null;
        final canOpen = settings != null && on;
        final open = canOpen && expansion.isOpen(m.id);
        final text = Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Flexible(child: HighlightedText(m.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500, color: on ? null : theme.hintColor))),
            if (m.requires.isNotEmpty) ...[
              const SizedBox(width: 8),
              Flexible(
                flex: 0,
                child: Text('needs ${m.requires.map(_nameOf).join(', ')}', maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: colors.faint)),
              ),
            ],
          ]),
          if (m.description.isNotEmpty) ...[const SizedBox(height: 2), HighlightedText(m.description, style: hint)],
          if (status != null) Padding(padding: const EdgeInsets.only(top: 5), child: _StatusLine(status)),
        ]);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Hoverable(
            cursor: canOpen ? SystemMouseCursors.click : MouseCursor.defer,
            onTap: canOpen ? () => expansion.toggle(m.id) : null,
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
                          key: ValueKey('integration-expand-${m.id}'),
                          tooltip: open ? 'Hide ${m.name} settings' : '${m.name} settings',
                          iconSize: 18,
                          visualDensity: VisualDensity.compact,
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 26, minHeight: 24),
                          color: hovered || open ? theme.colorScheme.onSurface : theme.hintColor,
                          onPressed: on ? () => expansion.toggle(m.id) : null,
                          icon: AnimatedRotation(
                            turns: open ? 0.25 : 0,
                            duration: (MediaQuery.maybeDisableAnimationsOf(context) ?? false) ? Duration.zero : const Duration(milliseconds: 160),
                            child: const Icon(Icons.chevron_right),
                          ),
                        ),
                ),
                const SizedBox(width: 8),
                SettingSwitch(
                  key: ValueKey('integration-${m.id}'),
                  value: on,
                  onChanged: available
                      ? (v) {
                          final next = {...disabled};
                          v ? next.remove(m.id) : next.add(m.id);
                          app.setDisabledModules(next);
                        }
                      : null,
                ),
              ]),
            ),
          ),
          if (settings != null)
            SettingsReveal(
              open: open,
              child: Container(
                key: open ? ValueKey('integration-form-${m.id}') : null,
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
      },
    );
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
            style: theme.textTheme.bodySmall?.copyWith(color: sev == Severity.error ? c : theme.hintColor, fontSize: 11.5),
          ),
        ),
      ]),
    );
  }
}
