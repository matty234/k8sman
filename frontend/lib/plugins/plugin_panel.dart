/// Plugin sections in the inspector's Overview tab, and plugin actions in
/// its header. Both come from `GET /api/plugins/panel`, which the backend
/// renders from the object, its related objects and metrics (the UI runs
/// no plugin code).
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../actions/actions.dart';
import '../panels/panel.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../util/k8s.dart';
import 'blocks.dart';
import 'plugin_actions.dart';
import 'plugin_api.dart';
import 'plugin_host.dart';

export 'plugin_actions.dart' show pluginActions, runPluginAction, showPluginConsent;

/// [base] with the plugins' sections after its own (before them with
/// [pluginFirst]: for kinds whose base is the generic panel, as
/// docs/PLUGINS.md §4 places them), and their actions after its actions.
/// With [replaceBase] (a plugin's `panel.generic: replace`) the base's
/// sections are left out: the plugin's are the panel. Its tabs and
/// actions stay, and so do the shell's own sections (Owns, Metadata).
class PluginComposedPanel extends ResourcePanel {
  final ResourcePanel base;
  final bool pluginFirst;
  final bool replaceBase;
  const PluginComposedPanel(this.base, {this.pluginFirst = false, this.replaceBase = false});

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
        if (pluginFirst) PluginSections(key: ValueKey('plugin-sections-${ctx.uid}'), ctx: ctx),
        if (!replaceBase) ...base.buildSections(context, ctx),
        if (!pluginFirst) PluginSections(key: ValueKey('plugin-sections-${ctx.uid}'), ctx: ctx),
      ];

  @override
  List<ResourceAction> actions(PanelContext ctx) => [...base.actions(ctx), ...pluginActions(ctx)];
}

/// The plugins' sections for one object. Refetched when the object
/// changes (its resourceVersion) or a plugin is reloaded, and while open
/// every few seconds when they read related objects, metrics or `now`
/// (the backend answers from the warm watch cache).
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
  int _tick = 0;
  Timer? _refresh;

  @override
  void initState() {
    super.initState();
    pluginHost.addListener(_onHost);
  }

  @override
  void dispose() {
    _refresh?.cancel();
    pluginHost.removeListener(_onHost);
    super.dispose();
  }

  void _onHost() {
    if (mounted) setState(() {});
  }

  String get _key => '${dig(widget.ctx.object, ['metadata', 'resourceVersion'])}@${pluginHost.generation}@${widget.ctx.app.readOnly}@$_tick';

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
      pluginHost.bindActions(pluginTargetKey(ctx.type.gk, ctx.namespace, ctx.name), () => pluginActions(widget.ctx));
      _schedule(d.refresh);
      setState(() {
        _data = d;
        _error = null;
      });
    }, onError: (Object e) {
      if (!mounted || seq != _seq) return;
      setState(() => _error = e);
    });
  }

  void _schedule(Duration? every) {
    _refresh?.cancel();
    if (every == null) return;
    _refresh = Timer(every, () {
      if (mounted) setState(() => _tick++);
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
        if (p.notes.isNotEmpty) PluginNotes(p.notes),
        for (final s in p.sections) PluginSectionView(s),
      ],
    ]);
  }
}

/// What a plugin's related objects or metrics couldn't read ("Secrets
/// aren't served", "not allowed to list secrets in demo"): a quiet line
/// above its sections, which render with what there is.
class PluginNotes extends StatelessWidget {
  final List<String> notes;
  const PluginNotes(this.notes, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (final n in notes)
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: Icon(Icons.info_outline, size: 13, color: severityColor(context, Severity.info))),
            const SizedBox(width: 6),
            Expanded(child: Text(n, style: style)),
          ]),
      ]),
    );
  }
}
