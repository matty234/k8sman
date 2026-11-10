/// Plugin sections in the inspector's Overview tab, and plugin shell
/// actions in its header. Both come from `GET /api/plugins/panel`, which
/// the backend renders from the object (the UI runs no plugin code).
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../actions/actions.dart';
import '../api/client.dart';
import '../panels/panel.dart';
import '../state/log_dock.dart';
import '../ui/terminal/exec_protocol.dart';
import '../ui/terminal/open_terminal.dart' show localShellSupported;
import '../ui/terminal/terminal_tab.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'blocks.dart';
import 'plugin_api.dart';
import 'plugin_host.dart';
import 'plugin_icons.dart';

/// [base] with the plugins' sections after its own, and their shell
/// actions after its actions.
class PluginComposedPanel extends ResourcePanel {
  final ResourcePanel base;
  const PluginComposedPanel(this.base);

  @override
  Set<String> get kinds => base.kinds;

  @override
  bool get showsOwned => base.showsOwned;

  @override
  bool get ownerInHeader => base.ownerInHeader;

  @override
  List<PanelTab> tabs(PanelContext ctx) => base.tabs(ctx);

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) => [
        ...base.buildSections(context, ctx),
        PluginSections(key: ValueKey('plugin-sections-${ctx.uid}'), ctx: ctx),
      ];

  @override
  List<ResourceAction> actions(PanelContext ctx) => [...base.actions(ctx), ...pluginActions(ctx)];
}

/// The plugin shell actions last offered for [ctx]'s object (none on
/// read-only contexts: the backend doesn't offer them there).
List<ResourceAction> pluginActions(PanelContext ctx) {
  if (ctx.app.readOnly || !localShellSupported) return const [];
  return [
    for (final a in pluginHost.actionsFor(ctx.uid))
      ResourceAction(
        id: 'plugin.${a.plugin}.${a.id}',
        label: a.label,
        icon: pluginIcon(a.icon) ?? Icons.terminal,
        tooltip: '${a.argv.join(' ')}  (${a.plugin} plugin; runs on this computer)',
        run: (context) => runPluginAction(context, ctx, a),
      ),
  ];
}

/// The plugins' sections for one object. Refetched when the object
/// changes (its resourceVersion) or a plugin is reloaded.
class PluginSections extends StatefulWidget {
  final PanelContext ctx;
  const PluginSections({super.key, required this.ctx});

  @override
  State<PluginSections> createState() => _PluginSectionsState();
}

class _PluginSectionsState extends State<PluginSections> {
  PluginPanelData? _data;
  Object? _error;
  String? _fetchedFor;
  int _seq = 0;

  @override
  void initState() {
    super.initState();
    pluginHost.addListener(_onHost);
  }

  @override
  void dispose() {
    pluginHost.removeListener(_onHost);
    super.dispose();
  }

  void _onHost() {
    if (mounted) setState(() {});
  }

  String get _key => '${dig(widget.ctx.object, ['metadata', 'resourceVersion'])}@${pluginHost.generation}@${widget.ctx.app.readOnly}';

  void _fetchIfNeeded() {
    final key = _key;
    if (key == _fetchedFor) return;
    _fetchedFor = key;
    final seq = ++_seq;
    final ctx = widget.ctx;
    ctx.api.pluginPanel(ctx.type.ref, namespace: ctx.namespace, name: ctx.name).then((j) {
      if (!mounted || seq != _seq) return;
      final d = PluginPanelData.fromJson(j);
      pluginHost.setActions(ctx.uid, d.actions);
      setState(() {
        _data = d;
        _error = null;
      });
    }, onError: (Object e) {
      if (!mounted || seq != _seq) return;
      setState(() => _error = e);
    });
  }

  @override
  Widget build(BuildContext context) {
    _fetchIfNeeded();
    final d = _data;
    if (d == null) {
      if (_error == null) return const SizedBox.shrink();
      return DetailSection(title: 'Plugins', icon: Icons.extension_outlined, child: PluginErrorText('$_error'));
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final p in d.panels) ...[
        if (p.errors.isNotEmpty)
          DetailSection(
            title: p.name,
            icon: Icons.extension_outlined,
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final e in p.errors) PluginErrorText('$e'),
            ]),
          ),
        for (final s in p.sections) PluginSectionView(s),
      ],
    ]);
  }
}

/// Runs plugin action [a] on [ctx]'s object: first-use consent to the
/// plugin's permissions, a confirmation with the full command on every
/// run, then the command in a new dock tab.
Future<void> runPluginAction(BuildContext context, PanelContext ctx, PluginAction a) async {
  final api = ctx.api;
  if (ctx.app.readOnly) return;
  if (!a.consented) {
    final info = pluginHost.state.plugins.where((p) => p.id == a.plugin).firstOrNull;
    if (info == null) return;
    final ok = await showPluginConsent(context, info);
    if (ok != true || !context.mounted) return;
    try {
      pluginHost.applyJson(await api.putPluginConsent(info.id, info.permissionsHash));
    } on ApiException catch (e) {
      if (context.mounted) showActionError(context, e.message);
      return;
    }
    if (!context.mounted) return;
  }
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
        Text('The ${a.plugin} plugin runs this on your computer, with your credentials:', style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(height: 6),
        CodeBlock(a.argv.map(_quote).join(' ')),
      ]),
    ),
  );
  if (ok != true || !context.mounted) return;
  final tab = TerminalTab(
    transport: execTransportFor(api),
    request: ExecRequest.pluginAction({
      ...ctx.type.ref.toQuery(),
      if (ctx.namespace != null) 'namespace': ctx.namespace!,
      'name': ctx.name,
      'plugin': a.plugin,
      'action': a.id,
    }, title: '${a.label} · ${ctx.name}'),
  );
  context.read<LogDock>().add(tab);
}

String _quote(String s) => s.isEmpty || RegExp(r'''[\s'"$`\\|&;<>()*?#~]''').hasMatch(s) ? "'${s.replaceAll("'", r"'\''")}'" : s;

/// Asks to agree to [p]'s permissions, browser-extension style. Asked on a
/// plugin's first shell action, and again when its permissions change.
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
  return showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Allow ${p.name}?'),
      content: SizedBox(
        width: 460,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${p.name} ${p.version} is an unpacked plugin from ${p.dir}. It asks to:', style: theme.textTheme.bodySmall),
          const SizedBox(height: 10),
          line(Icons.visibility_outlined, 'Read', perms.read.isEmpty ? 'nothing' : perms.read.map(_kindName).join(', ')),
          line(Icons.terminal, 'Run on this computer', perms.commands.isEmpty ? 'nothing' : perms.commands.join(', ')),
          line(Icons.edit_outlined, 'Change', 'nothing (patch actions come in a later version)'),
          const SizedBox(height: 8),
          Row(children: [
            Icon(Icons.info_outline, size: 14, color: severityColor(context, Severity.warn)),
            const SizedBox(width: 6),
            Expanded(
              child: Text('Commands run with your own credentials. Each run still asks first and shows the full command.',
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
