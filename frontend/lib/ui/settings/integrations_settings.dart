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

/// A module's row: an on/off switch, what it needs, its status on the
/// current cluster, and (for modules with settings) a disclosure that
/// opens its form below. Turning a module on or off applies and saves at
/// once, for every cluster.
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
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return ListenableBuilder(
      key: expansion.keyFor(m.id),
      listenable: Listenable.merge([moduleStatuses, expansion]),
      builder: (context, _) {
        final status = on ? _statusOf(context, m, app) : null;
        final open = settings != null && on && expansion.isOpen(m.id);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 8, 12, 8),
            child: Row(children: [
              SizedBox(
                width: 28,
                child: settings == null
                    ? null
                    : IconButton(
                        key: ValueKey('integration-expand-${m.id}'),
                        tooltip: open ? 'Hide ${m.name} settings' : '${m.name} settings',
                        iconSize: 18,
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
                        onPressed: on ? () => expansion.toggle(m.id) : null,
                        icon: AnimatedRotation(
                          turns: open ? 0.25 : 0,
                          duration: Duration.zero,
                          child: const Icon(Icons.chevron_right),
                        ),
                      ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(text: m.name, style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w500)),
                      if (m.requires.isNotEmpty)
                        TextSpan(text: '   needs ${m.requires.map(_nameOf).join(', ')}', style: theme.textTheme.bodySmall?.copyWith(color: colors.faint)),
                    ]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (m.description.isNotEmpty) Text(m.description, style: hint),
                  if (status != null) Padding(padding: const EdgeInsets.only(top: 4), child: _StatusLine(status)),
                ]),
              ),
              const SizedBox(width: 12),
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
          if (open)
            Container(
              key: ValueKey('integration-form-${m.id}'),
              padding: const EdgeInsets.fromLTRB(38, 2, 16, 14),
              child: Builder(builder: settings),
            ),
        ]);
      },
    );
  }
}

/// "● connected · relay v1.18 · 13 nodes", "not on this cluster", …
class _StatusLine extends StatelessWidget {
  final ModuleStatus status;
  const _StatusLine(this.status);

  @override
  Widget build(BuildContext context) {
    final s = status;
    final (sev, label) = switch (s.state) {
      ModuleState.checking => (Severity.info, 'checking…'),
      ModuleState.notInstalled => (Severity.neutral, 'not on this cluster'),
      ModuleState.connected => (Severity.ok, 'connected'),
      ModuleState.error => (Severity.error, 'error'),
    };
    final text = [label, if (s.message != null && s.message!.isNotEmpty && s.state != ModuleState.notInstalled) s.message!].join(' · ');
    return Align(
      alignment: Alignment.centerLeft,
      child: Tooltip(message: s.message ?? '', child: StatusBadge(text, severity: sev, dense: true)),
    );
  }
}
