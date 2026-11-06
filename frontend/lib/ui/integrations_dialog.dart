import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/client.dart';
import '../modules/modules.dart';
import '../state/app_state.dart';
import 'theme.dart';
import '../util/k8s.dart';
import 'widgets/common.dart';

/// Turns integration modules (Argo CD, Helm, GPUs, …) on or off. Off hides
/// the module's pages, panels, palette entries and sidebar sections, and
/// the backend stops serving its endpoints and overview checks. Applies on
/// Done; saved in settings.json for every cluster. Modules that detect
/// their service show its status here, and modules with settings a button
/// to open them.
Future<void> showIntegrationsDialog(BuildContext context) {
  final app = context.read<AppState>();
  ApiClient? api;
  try {
    api = context.read<ApiClient>();
  } catch (_) {}
  final dialog = ChangeNotifierProvider<AppState>.value(value: app, child: const IntegrationsDialog());
  return showDialog<void>(
    context: context,
    builder: (_) => api == null ? dialog : Provider<ApiClient>.value(value: api, child: dialog),
  );
}

class IntegrationsDialog extends StatefulWidget {
  const IntegrationsDialog({super.key});

  @override
  State<IntegrationsDialog> createState() => _IntegrationsDialogState();
}

class _IntegrationsDialogState extends State<IntegrationsDialog> {
  late final Set<String> _disabled = {...context.read<AppState>().disabledModules};

  void _done() {
    final app = context.read<AppState>();
    if (_disabled.length != app.disabledModules.length || !_disabled.containsAll(app.disabledModules)) {
      app.setDisabledModules(_disabled);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).faint);
    return Dialog(
      key: const ValueKey('integrations-dialog'),
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 4),
            child: Text('Integrations', style: theme.textTheme.titleMedium),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Text('Turn off what you don\'t use: its pages, panels and checks go away on every cluster.',
                style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
          ),
          for (final m in builtInModules)
            ListenableBuilder(
              listenable: moduleStatuses,
              builder: (context, _) {
                final status = _statusOf(context, m, app);
                final settings = m.settingsBuilder;
                return CheckboxListTile(
                  key: ValueKey('integration-${m.id}'),
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: moduleEnabled(m.id, _disabled),
                  // Off while a module it needs is off (Add-ons needs Helm).
                  onChanged: m.requires.every((r) => moduleEnabled(r, _disabled))
                      ? (on) => setState(() => on == true ? _disabled.remove(m.id) : _disabled.add(m.id))
                      : null,
                  title: Text.rich(TextSpan(children: [
                    TextSpan(text: m.name),
                    if (m.requires.isNotEmpty) TextSpan(text: '   needs ${m.requires.map(_nameOf).join(', ')}', style: muted),
                  ])),
                  subtitle: status == null ? null : _StatusLine(status),
                  secondary: settings == null
                      ? null
                      : IconButton(
                          key: ValueKey('integration-settings-${m.id}'),
                          tooltip: '${m.name} settings',
                          iconSize: 16,
                          visualDensity: VisualDensity.compact,
                          icon: const Icon(Icons.tune),
                          onPressed: () => _openSettings(context, settings),
                        ),
                );
              },
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 16, 14),
            child: Row(children: [
              const Spacer(),
              OutlinedButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Cancel')),
              const SizedBox(width: 8),
              FilledButton(onPressed: _done, child: const Text('Done')),
            ]),
          ),
        ]),
      ),
    );
  }

  static String _nameOf(String id) => builtInModules.where((m) => m.id == id).firstOrNull?.name ?? id;

  /// The module's detected status on the current cluster (null when it
  /// detects nothing, or there's no backend in this tree).
  static ModuleStatus? _statusOf(BuildContext context, AppModule m, AppState app) {
    if (m.detect == null) return null;
    try {
      return moduleStatuses.of(m, context.read<ApiClient>(), app.currentContext);
    } catch (_) {
      return null;
    }
  }

  void _openSettings(BuildContext context, WidgetBuilder builder) {
    final app = context.read<AppState>();
    final api = context.read<ApiClient>();
    showDialog<void>(
      context: context,
      builder: (_) => MultiProvider(
        providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
        child: Dialog(insetPadding: const EdgeInsets.all(32), child: SizedBox(width: 440, child: Builder(builder: builder))),
      ),
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
    return Tooltip(
      message: s.message ?? '',
      child: StatusBadge(text, severity: sev, dense: true),
    );
  }
}
