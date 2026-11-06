import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../modules/modules.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// Turns integration modules (Argo CD, Helm, GPUs, …) on or off. Off hides
/// the module's pages, panels, palette entries and sidebar sections, and
/// the backend stops serving its endpoints and overview checks. Applies on
/// Done; saved in settings.json for every cluster.
Future<void> showIntegrationsDialog(BuildContext context) {
  final app = context.read<AppState>();
  return showDialog<void>(
    context: context,
    builder: (_) => ChangeNotifierProvider<AppState>.value(value: app, child: const IntegrationsDialog()),
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
        width: 380,
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
            CheckboxListTile(
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
                if (!m.isAvailable(app)) TextSpan(text: '   not on this cluster', style: muted),
                if (m.requires.isNotEmpty) TextSpan(text: '   needs ${m.requires.map(_nameOf).join(', ')}', style: muted),
              ])),
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
}
