/// Plugin actions: shell commands (a dock tab, or in the background) and
/// patches of the object. The backend builds every command and patch from
/// the loaded plugin; the UI asks for consent, inputs and confirmation.
/// Patches go through the app's action path
/// (`POST /api/actions/plugin.<id>.<action>`): a dry run first, its change
/// shown, then the real run. None is offered on read-only contexts.
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../actions/actions.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../panels/panel.dart';
import '../state/log_dock.dart';
import '../ui/detail/yaml_editor.dart' show DiffView;
import '../ui/terminal/exec_protocol.dart';
import '../ui/terminal/open_terminal.dart' show localShellSupported;
import '../ui/terminal/terminal_tab.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/diff.dart';
import '../util/k8s.dart' show Severity;
import 'plugin_api.dart';
import 'plugin_host.dart';
import 'plugin_icons.dart';

/// The plugin actions last offered for [ctx]'s object (none on read-only
/// contexts: the backend doesn't offer them there).
List<ResourceAction> pluginActions(PanelContext ctx) {
  if (ctx.app.readOnly) return const [];
  return [
    for (final a in pluginHost.actionsFor(ctx.uid))
      if (a.isPatch || a.background || localShellSupported)
        ResourceAction(
          id: 'plugin.${a.plugin}.${a.id}',
          label: a.label,
          icon: pluginIcon(a.icon) ?? (a.isPatch ? Icons.edit_outlined : Icons.terminal),
          tooltip: a.isPatch
              ? '${a.message ?? 'Changes this ${ctx.type.kind}'} (${a.plugin} plugin; asks first)${_shortcutHint(a)}'
              : '${a.argv.join(' ')}  (${a.plugin} plugin; runs on this computer)${_shortcutHint(a)}',
          run: (context) => runPluginAction(context, ctx, a),
        ),
  ];
}

String _shortcutHint(PluginAction a) => a.shortcut == null ? '' : ' · ${a.shortcut}';

/// Runs plugin action [a] on [ctx]'s object: first-use consent to the
/// plugin's permissions, then the action's own flow.
Future<void> runPluginAction(BuildContext context, PanelContext ctx, PluginAction a) async {
  if (ctx.app.readOnly) return;
  if (!a.consented) {
    final info = pluginHost.state.plugins.where((p) => p.id == a.plugin).firstOrNull;
    if (info == null) return;
    final ok = await showPluginConsent(context, info);
    if (ok != true || !context.mounted) return;
    try {
      pluginHost.applyJson(await ctx.api.putPluginConsent(info.id, info.permissionsHash));
    } on ApiException catch (e) {
      if (context.mounted) showActionError(context, e.message);
      return;
    }
    if (!context.mounted) return;
  }
  if (a.isPatch) return runPluginPatch(context, ctx, a);
  final ok = await confirmAction(
    context,
    title: '${a.label}?',
    message: a.message,
    kubeContext: ctx.app.currentContext,
    objectName: ctx.name,
    confirmLabel: 'Run',
    destructive: a.dangerous,
    extra: Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('The ${a.plugin} plugin runs this on your computer, with your credentials${a.background ? ', in the background' : ''}:',
            style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 6),
        CodeBlock(a.argv.map(_quote).join(' ')),
      ]),
    ),
  );
  if (ok != true || !context.mounted) return;
  final query = {
    ...ctx.type.ref.toQuery(),
    if (ctx.namespace != null) 'namespace': ctx.namespace!,
    'name': ctx.name,
    'plugin': a.plugin,
    'action': a.id,
  };
  if (a.background) return _runBackground(context, ctx, a);
  final tab = TerminalTab(
    transport: execTransportFor(ctx.api),
    request: ExecRequest.pluginAction(query, title: '${a.label} · ${ctx.name}'),
  );
  context.read<LogDock>().add(tab);
}

/// A background shell action: the backend runs it and answers with the
/// exit status and the last lines of output.
Future<void> _runBackground(BuildContext context, PanelContext ctx, PluginAction a) async {
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.showSnackBar(SnackBar(content: Text('${a.label}: running…'), duration: const Duration(seconds: 2)));
  try {
    final r = await ctx.api.runPluginBackground(ctx.type.ref, namespace: ctx.namespace, name: ctx.name, plugin: a.plugin, action: a.id);
    final code = (r['exitCode'] as num?)?.toInt() ?? 0;
    final output = '${r['output'] ?? ''}'.trim();
    if (!context.mounted) return;
    final failed = code != 0 || r['timedOut'] == true;
    messenger?.showSnackBar(SnackBar(
      content: Text(failed ? '${a.label} failed (exit $code)' : '${a.label} finished'),
      duration: const Duration(seconds: 6),
      action: output.isEmpty
          ? null
          : SnackBarAction(
              label: 'Output',
              onPressed: () => showDialog<void>(
                context: context,
                builder: (context) => AlertDialog(
                  title: Text('${a.label} · exit $code'),
                  content: SizedBox(width: 560, child: SingleChildScrollView(child: CodeBlock(output))),
                  actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
                ),
              ),
            ),
    ));
  } on ApiException catch (e) {
    if (context.mounted) showActionError(context, e.message);
  }
}

/// A patch action: its form (when it has inputs), a dry run whose change is
/// shown in the confirmation, then the change itself.
Future<void> runPluginPatch(BuildContext context, PanelContext ctx, PluginAction a) async {
  Future<ActionResult> call(Map<String, Object?> inputs, {required bool dryRun}) =>
      ctx.api.runAction(ctx.type.ref, namespace: ctx.namespace, name: ctx.name, action: a.actionName, body: {'inputs': inputs, if (dryRun) 'dryRun': true});

  var inputs = <String, Object?>{for (final i in a.inputs) i.name: i.defaultValue};
  ActionResult? preview;
  if (a.inputs.isNotEmpty) {
    final done = await showDialog<({Map<String, Object?> values, ActionResult preview})>(
      context: context,
      builder: (context) => PluginInputsDialog(
        action: a,
        submit: (values) async {
          final r = await call(values, dryRun: true);
          return r;
        },
      ),
    );
    if (done == null || !context.mounted) return;
    inputs = done.values;
    preview = done.preview;
  } else {
    try {
      preview = await call(inputs, dryRun: true);
    } on ApiException catch (e) {
      if (context.mounted) showActionError(context, e.message);
      return;
    }
  }
  if (!context.mounted) return;
  final ok = await confirmAction(
    context,
    title: '${a.label.replaceAll('…', '')}?',
    message: a.message,
    kubeContext: ctx.app.currentContext,
    objectName: ctx.name,
    confirmLabel: 'Apply',
    destructive: a.dangerous,
    width: 600,
    extra: PluginPatchPreview(plugin: a.plugin, preview: preview.preview),
  );
  if (ok != true || !context.mounted) return;
  try {
    final res = await call(inputs, dryRun: false);
    if (context.mounted) ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(res.message), persist: false));
  } on ApiException catch (e) {
    if (context.mounted) showActionError(context, e.message);
  }
}

/// The change a dry run reported: the patch and the object's diff.
class PluginPatchPreview extends StatelessWidget {
  final String plugin;
  final ActionPreview? preview;
  const PluginPatchPreview({super.key, required this.plugin, required this.preview});

  @override
  Widget build(BuildContext context) {
    final p = preview;
    final theme = Theme.of(context);
    if (p == null) return const SizedBox.shrink();
    final lines = diffLines(p.before, p.after);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('The $plugin plugin sends this ${p.patchType == 'json' ? 'JSON patch' : 'merge patch'} (a dry run passed):', style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        CodeBlock(const JsonEncoder.withIndent('  ').convert(p.patch)),
        const SizedBox(height: 10),
        Text('Change to the object:', style: theme.textTheme.bodySmall),
        const SizedBox(height: 6),
        DiffView(lines: lines, shrinkWrap: true, maxRows: 60),
      ]),
    );
  }
}

/// A patch action's form. [submit] runs the dry run with the values: an
/// [ApiException] (e.g. the plugin's `validateMessage`) shows in the form
/// and keeps it open; a result closes it with the values and the result.
class PluginInputsDialog extends StatefulWidget {
  final PluginAction action;
  final Future<ActionResult> Function(Map<String, Object?> values) submit;
  const PluginInputsDialog({super.key, required this.action, required this.submit});

  @override
  State<PluginInputsDialog> createState() => _PluginInputsDialogState();
}

class _PluginInputsDialogState extends State<PluginInputsDialog> {
  final Map<String, TextEditingController> _text = {};
  final Map<String, Object?> _values = {};
  final Map<String, String> _fieldErrors = {};
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    for (final i in widget.action.inputs) {
      switch (i.type) {
        case 'bool':
          _values[i.name] = i.defaultValue == true;
        case 'enum':
          _values[i.name] = i.options.contains('${i.defaultValue}') ? '${i.defaultValue}' : i.options.firstOrNull;
        default:
          _text[i.name] = TextEditingController(text: i.defaultValue == null ? '' : '${i.defaultValue}');
      }
    }
  }

  @override
  void dispose() {
    for (final c in _text.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// The values, or null when a field isn't of its type (checked again by
  /// the backend, with the plugin's own rules).
  Map<String, Object?>? _collect() {
    _fieldErrors.clear();
    final out = <String, Object?>{};
    for (final i in widget.action.inputs) {
      if (i.type == 'int') {
        final n = int.tryParse(_text[i.name]!.text.trim());
        if (n == null) {
          _fieldErrors[i.name] = 'Enter a whole number.';
          continue;
        }
        out[i.name] = n;
      } else if (_text.containsKey(i.name)) {
        out[i.name] = _text[i.name]!.text;
      } else {
        out[i.name] = _values[i.name];
      }
    }
    return _fieldErrors.isEmpty ? out : null;
  }

  Future<void> _continue() async {
    final values = _collect();
    if (values == null) {
      setState(() => _error = null);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final r = await widget.submit(values);
      if (mounted) Navigator.pop(context, (values: values, preview: r));
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget _field(PluginInput i) {
    switch (i.type) {
      case 'bool':
        return CheckboxListTile(
          key: ValueKey('plugin-input-${i.name}'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(i.label),
          value: _values[i.name] == true,
          onChanged: _busy ? null : (v) => setState(() => _values[i.name] = v == true),
        );
      case 'enum':
        return InputDecorator(
          decoration: InputDecoration(labelText: i.label, isDense: true, border: const OutlineInputBorder()),
          child: MenuSelect<String>(
            key: ValueKey('plugin-input-${i.name}'),
            value: _values[i.name] as String?,
            options: [for (final o in i.options) (o, Text(o))],
            onChanged: (v) {
              if (!_busy) setState(() => _values[i.name] = v);
            },
          ),
        );
      default:
        return TextField(
          key: ValueKey('plugin-input-${i.name}'),
          controller: _text[i.name],
          enabled: !_busy,
          keyboardType: i.type == 'int' ? TextInputType.number : null,
          inputFormatters: i.type == 'int' ? [FilteringTextInputFormatter.allow(RegExp(r'[-0-9]'))] : null,
          decoration: InputDecoration(labelText: i.label, isDense: true, border: const OutlineInputBorder(), errorText: _fieldErrors[i.name]),
          onSubmitted: (_) => _continue(),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final a = widget.action;
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(a.label.replaceAll('…', '')),
      content: SizedBox(
        width: 440,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (a.message != null) ...[Text(a.message!, style: theme.textTheme.bodySmall), const SizedBox(height: 12)],
          for (final i in a.inputs) Padding(padding: const EdgeInsets.only(bottom: 12), child: _field(i)),
          if (_error != null)
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Icon(Icons.error_outline, size: 16, color: severityColor(context, Severity.error)),
              const SizedBox(width: 6),
              Expanded(child: Text(_error!, key: const ValueKey('plugin-inputs-error'), style: TextStyle(color: severityColor(context, Severity.error)))),
            ]),
          Text('Next: a dry run, then the change to confirm.', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ]),
      ),
      actions: [
        TextButton(onPressed: _busy ? null : () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: _busy ? null : _continue,
          child: _busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Text('Preview'),
        ),
      ],
    );
  }
}

String _quote(String s) => s.isEmpty || RegExp(r'''[\s'"$`\\|&;<>()*?#~]''').hasMatch(s) ? "'${s.replaceAll("'", r"'\''")}'" : s;

/// Asks to agree to [p]'s permissions, browser-extension style. Asked on a
/// plugin's first action, and again when its permissions change.
Future<bool?> showPluginConsent(BuildContext context, PluginInfo p) {
  final theme = Theme.of(context);
  final perms = p.permissions;
  Widget line(IconData icon, String head, String body) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 16, color: theme.hintColor),
          const SizedBox(width: 10),
          Expanded(
            child: Text.rich(TextSpan(children: [
              TextSpan(text: '$head ', style: const TextStyle(fontWeight: FontWeight.w600)),
              TextSpan(text: body),
            ]), style: theme.textTheme.bodySmall),
          ),
        ]),
      );
  final reads = [for (final k in perms.read) k == '/Secret' ? 'Secrets (names and keys only)' : _kindName(k)];
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Allow ${p.name}?'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${p.name} ${p.version} is an unpacked plugin from ${p.dir}. It asks to:', style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          line(Icons.visibility_outlined, 'Read', reads.isEmpty ? 'nothing' : reads.join(', ')),
          if (perms.prometheus) line(Icons.insights_outlined, 'Query', 'Prometheus (through the Prometheus integration)'),
          line(Icons.terminal, 'Run on this computer', perms.commands.isEmpty ? 'nothing' : perms.commands.join(', ')),
          line(Icons.edit_outlined, 'Change', perms.patch.isEmpty ? 'nothing' : '${perms.patch.map(_kindName).join(', ')} (with your confirmation)'),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.info_outline, size: 14, color: severityColor(context, Severity.warn)),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Commands and changes use your own credentials. Each run still asks first and shows the command or the change.',
                  style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
            ),
          ]),
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
        FilledButton(autofocus: true, onPressed: () => Navigator.pop(context, true), child: const Text('Allow')),
      ],
    ),
  );
}

String _kindName(String key) {
  final kind = key.split('/').last;
  return key.startsWith('/') || !key.contains('/') ? kind : '$kind (${key.split('/').first})';
}
