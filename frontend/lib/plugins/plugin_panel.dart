/// Plugin sections in the inspector's Overview tab, plugin tabs (their own,
/// or sections of a host tab such as Security), and plugin actions in its
/// header. All come from `GET /api/plugins/panel`, which the backend
/// renders from the object, its related objects and metrics (the UI runs
/// no plugin code).
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';

import '../actions/actions.dart';
import '../panels/panel.dart';
import '../ui/theme.dart';
import '../ui/widgets/common.dart';
import '../ui/widgets/editorial.dart' show PageScroll;
import '../util/k8s.dart';
import 'blocks.dart';
import 'plugin_actions.dart';
import 'plugin_api.dart';
import 'plugin_host.dart';
import 'plugin_icons.dart';

export 'plugin_actions.dart' show pluginActions, runPluginAction, showPluginConsent;

/// [base] with the plugins' sections after its own (before them with
/// [pluginFirst]: for kinds whose base is the generic panel, as
/// docs/PLUGINS.md §4 places them), their tabs after its tabs, and their
/// actions after its actions. With [replaceBase] (a plugin's
/// `panel.generic: replace`) the base's sections are left out: the
/// plugin's are the panel. Its tabs and actions stay, and so do the
/// shell's own sections (Owns, Metadata).
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

  /// The base's tabs, then the plugin tabs the backend rendered for the
  /// object (they appear once its panel has been fetched). A plugin tab
  /// whose `into` names a tab the base has (its [PanelTab.slot]) is drawn
  /// inside that tab instead ([PluginSlotSections]).
  @override
  List<PanelTab> tabs(PanelContext ctx) {
    final own = base.tabs(ctx);
    final slots = {for (final t in own) ?t.slot};
    final labels = {for (final t in own) t.label};
    final data = pluginPanels.of(ctx);
    return [
      ...own,
      if (data != null)
        for (final p in data.panels)
          for (final t in p.tabs)
            if (!(t.into != null && slots.contains(t.into)) && !labels.contains(t.title))
              PanelTab(
                label: t.title,
                id: 'plugin:${p.plugin}:${t.id}',
                icon: pluginIcon(t.icon) ?? Icons.extension_outlined,
                builder: (context, ctx) => PluginTabView(key: ValueKey('plugin-tab-${p.plugin}-${t.id}-${ctx.uid}'), ctx: ctx, plugin: p.plugin, tabId: t.id),
              ),
    ];
  }

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) => [
        if (pluginFirst) PluginSections(key: ValueKey('plugin-sections-${ctx.uid}'), ctx: ctx),
        if (!replaceBase) ...base.buildSections(context, ctx),
        if (!pluginFirst) PluginSections(key: ValueKey('plugin-sections-${ctx.uid}'), ctx: ctx),
      ];

  @override
  List<ResourceAction> actions(PanelContext ctx) => [...base.actions(ctx), ...pluginActions(ctx)];
}

/// The plugins' panel data per inspected object, shared by the Overview's
/// plugin sections, plugin tabs, host tabs holding plugin sections
/// (Security) and the inspector's tab bar: one fetch per object version
/// (or plugin generation), and while any of them is open, again every few
/// seconds when the plugins read related objects, metrics or `now` (the
/// backend answers from the warm watch cache). Listeners hear only when
/// what was fetched changed.
class PluginPanelCache extends ChangeNotifier {
  static const _keep = 16;
  final Map<String, _PanelEntry> _entries = {};

  static String _id(PanelContext ctx) => '${identityHashCode(ctx.api)}|${ctx.uid}';

  _PanelEntry _entry(PanelContext ctx) {
    final id = _id(ctx);
    final e = _entries.remove(id) ?? _PanelEntry();
    _entries[id] = e; // most recent last
    if (_entries.length > _keep) {
      for (final k in _entries.keys.toList()) {
        if (_entries.length <= _keep) break;
        final old = _entries[k]!;
        if (old.watchers == 0 && k != id) {
          old.timer?.cancel();
          _entries.remove(k);
        }
      }
    }
    e.ctx = ctx;
    return e;
  }

  /// [ctx]'s panel data (null until the first answer), fetching it when the
  /// object, the plugins or the context's read-only state changed.
  PluginPanelData? of(PanelContext ctx) {
    final e = _entry(ctx);
    _fetchIfNeeded(e);
    return e.data;
  }

  /// The last fetch's error for [ctx], if it failed before any answer.
  Object? errorOf(PanelContext ctx) => _entries[_id(ctx)]?.error;

  /// A view of [ctx]'s panel is open: keep it fresh while it is.
  void watch(PanelContext ctx) {
    final e = _entry(ctx);
    e.watchers++;
    if (e.stale) {
      e.stale = false;
      e.tick++;
    }
    _fetchIfNeeded(e);
  }

  void unwatch(PanelContext ctx) {
    final e = _entries[_id(ctx)];
    if (e != null && e.watchers > 0) e.watchers--;
  }

  String _key(_PanelEntry e) {
    final ctx = e.ctx!;
    return '${dig(ctx.object, ['metadata', 'resourceVersion'])}@${pluginHost.generation}@${ctx.app.readOnly}@${e.tick}';
  }

  void _fetchIfNeeded(_PanelEntry e) {
    final key = _key(e);
    if (key == e.fetchedFor) return;
    e.fetchedFor = key;
    final seq = ++e.seq;
    final ctx = e.ctx!;
    ctx.api.pluginPanel(ctx.type.ref, namespace: ctx.namespace, name: ctx.name).then((j) {
      if (seq != e.seq) return;
      final d = PluginPanelData.fromJson(j);
      pluginHost.setActions(ctx.uid, d.actions);
      pluginHost.bindActions(pluginTargetKey(ctx.type.gk, ctx.namespace, ctx.name), () => pluginActions(e.ctx!));
      _schedule(e, d.refresh);
      final sig = jsonEncode(j['panels']);
      final changed = sig != e.signature || e.error != null || e.data == null;
      e
        ..data = d
        ..error = null
        ..signature = sig;
      if (changed) notifyListeners();
    }, onError: (Object err) {
      if (seq != e.seq) return;
      e.error = err;
      notifyListeners();
    });
  }

  void _schedule(_PanelEntry e, Duration? every) {
    e.timer?.cancel();
    if (every == null) return;
    e.timer = Timer(every, () {
      if (e.watchers == 0) {
        e.stale = true;
        return;
      }
      e.tick++;
      _fetchIfNeeded(e);
    });
  }

  /// Forgets every entry (tests).
  @visibleForTesting
  void debugClear() {
    for (final e in _entries.values) {
      e.timer?.cancel();
    }
    _entries.clear();
  }
}

class _PanelEntry {
  PanelContext? ctx;
  PluginPanelData? data;
  Object? error;
  String? fetchedFor;
  String? signature;
  int seq = 0;
  int tick = 0;
  int watchers = 0;
  bool stale = false;
  Timer? timer;
}

/// The app's [PluginPanelCache].
final pluginPanels = PluginPanelCache();

/// Rebuilds [builder] with [ctx]'s plugin panel data, keeping it fresh
/// while mounted.
class _PanelWatch extends StatefulWidget {
  final PanelContext ctx;
  final Widget Function(BuildContext context, PluginPanelData? data, Object? error) builder;
  const _PanelWatch({required this.ctx, required this.builder});

  @override
  State<_PanelWatch> createState() => _PanelWatchState();
}

class _PanelWatchState extends State<_PanelWatch> {
  late PanelContext _watched = widget.ctx;

  @override
  void initState() {
    super.initState();
    pluginPanels.watch(_watched);
    pluginPanels.addListener(_changed);
    pluginHost.addListener(_changed);
  }

  @override
  void didUpdateWidget(covariant _PanelWatch old) {
    super.didUpdateWidget(old);
    if (old.ctx.uid != widget.ctx.uid || !identical(old.ctx.api, widget.ctx.api)) {
      pluginPanels.unwatch(_watched);
      _watched = widget.ctx;
      pluginPanels.watch(_watched);
    }
  }

  @override
  void dispose() {
    pluginPanels.unwatch(_watched);
    pluginPanels.removeListener(_changed);
    pluginHost.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, pluginPanels.of(widget.ctx), pluginPanels.errorOf(widget.ctx));
}

/// The plugins' sections for one object (the Overview tab).
class PluginSections extends StatelessWidget {
  final PanelContext ctx;
  const PluginSections({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) => _PanelWatch(
        ctx: ctx,
        builder: (context, d, error) {
          if (d == null) {
            if (error == null) return const SizedBox.shrink();
            return DetailSection(title: 'Plugins', icon: Icons.extension_outlined, child: PluginErrorText('$error'));
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
              // What couldn't be read, where the plugin shows something
              // (a "*" entry that shows nothing here stays quiet).
              if (p.notes.isNotEmpty && p.sections.isNotEmpty) PluginNotes(p.notes),
              for (final s in p.sections) PluginSectionView(s),
            ],
          ]);
        },
      );
}

/// A plugin tab of its own: its sections, scrolling.
class PluginTabView extends StatelessWidget {
  final PanelContext ctx;
  final String plugin;
  final String tabId;
  const PluginTabView({super.key, required this.ctx, required this.plugin, required this.tabId});

  @override
  Widget build(BuildContext context) => _PanelWatch(
        ctx: ctx,
        builder: (context, d, error) {
          final p = d?.panels.where((p) => p.plugin == plugin).firstOrNull;
          final tab = p?.tabs.where((t) => t.id == tabId).firstOrNull;
          return SelectionArea(
            child: PageScroll(padding: const EdgeInsets.fromLTRB(16, 4, 16, 24), children: [
              if (error != null && d == null) PluginErrorText('$error'),
              if (p != null && p.notes.isNotEmpty) PluginNotes(p.notes),
              if (tab != null)
                for (final s in tab.sections) PluginSectionView(s),
            ]),
          );
        },
      );
}

/// The sections of plugin tabs whose `into` is [slot], drawn inside that
/// host tab (Security) as its own sections are.
class PluginSlotSections extends StatelessWidget {
  final PanelContext ctx;
  final String slot;
  const PluginSlotSections({super.key, required this.ctx, required this.slot});

  @override
  Widget build(BuildContext context) => _PanelWatch(
        ctx: ctx,
        builder: (context, d, _) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (d != null)
            for (final p in d.panels)
              for (final t in p.tabs)
                if (t.into == slot)
                  for (final s in t.sections) PluginSectionView(s, inspectorId: '$slot-plugin-${p.plugin}-${s['title']}'),
        ]),
      );
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
