import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../modules/modules.dart' show moduleInspectorTabs, moduleStatuses;
import '../../panels/registry.dart';
import '../../plugins/plugin_host.dart';
import '../../plugins/plugin_panel.dart' show pluginPanels;
import '../../state/app_state.dart';
import '../../state/reconnecting_watch.dart';
import '../../util/k8s.dart';
import '../kubectl_menu.dart';
import '../links_ui.dart';
import '../logs/open_logs.dart';
import '../terminal/open_terminal.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../widgets/editorial.dart';
import '../widgets/group_icon.dart';
import '../portforward/portforward_dialog.dart';
import '../resource_nav.dart' show kindIconWidget;
import 'metadata_section.dart';
import '../inspector/identity_strip.dart';
import '../inspector/inspector.dart';
import 'owned_section.dart';
import 'yaml_editor.dart';
import '../keys.dart';

/// Right-hand sidebar for the current [AppState.detail] target. Keeps the
/// object live via a single-object watch.
class DetailSidebar extends StatelessWidget {
  const DetailSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final target = app.detail;
    if (target == null) return const SizedBox.shrink();
    return _LiveObject(target: target);
  }
}

class _LiveObject extends StatefulWidget {
  final DetailTarget target;
  const _LiveObject({required this.target});

  @override
  State<_LiveObject> createState() => _LiveObjectState();
}

class _LiveObjectState extends State<_LiveObject> {
  Json? _object;

  /// Set while [_object] is the previous target's (the new one has not
  /// arrived): shown dimmed in place of a spinner. Holds that target.
  DetailTarget? _staleTarget;
  bool _spin = false;
  Timer? _settle, _spinTimer;
  /// Recently seen objects, so going back to one renders at once.
  static final _recent = <DetailTarget, Json>{};
  bool _deleted = false;
  String? _error;
  late final _watch = ReconnectingWatch(
    open: () {
      final t = widget.target;
      return context.read<ApiClient>().watch(t.type.ref, namespace: t.namespace, fieldSelector: 'metadata.name=${t.name}', includeObject: true);
    },
    // A BATCH frame: apply its events in order, rebuild once.
    onFrame: (m) => setState(() => m.frames.forEach(_apply)),
  );
  /// The tab last open, by kind and label (see build).
  ({String gk, String id})? _openTab;

  /// Bumped for each "edit YAML" request, so the YAML tab starts editing.
  int _editRequest = 0;

  @override
  void initState() {
    super.initState();
    _object = widget.target.seed;
    _watch.restart();
    // Module tabs can depend on a module's detection (e.g. Hubble's Flows
    // tab only where Hubble is installed).
    moduleStatuses.addListener(_onModuleStatus);
    // Plugin sections and actions arrive (and hot reload) on their own.
    pluginHost.addListener(_onModuleStatus);
    // Plugin tabs appear once the object's plugin panel is fetched.
    pluginPanels.addListener(_onModuleStatus);
  }

  @override
  void didUpdateWidget(_LiveObject old) {
    super.didUpdateWidget(old);
    final t = widget.target;
    if (t == old.target) return;
    // The state outlives the target: no blank frame, tab and sections kept.
    _watch.stop();
    _spinTimer?.cancel();
    _deleted = false;
    _error = null;
    _spin = false;
    final seed = t.seed ?? _recent[t];
    if (seed != null) {
      _object = seed;
      _staleTarget = null;
    } else if (_object != null) {
      _staleTarget ??= old.target;
      _spinTimer = Timer(const Duration(milliseconds: 300), () => mounted ? setState(() => _spin = true) : null);
    }
    // Holding an arrow key moves faster than it is worth watching.
    _settle?.cancel();
    _settle = Timer(const Duration(milliseconds: 120), () => mounted ? _watch.restart() : null);
  }

  void _onModuleStatus() {
    if (mounted) setState(() {});
  }

  void _apply(WatchMessage m) {
    if (_staleTarget != null && m.type != 'DELETED') {
      _staleTarget = null;
      _object = null;
    }
    _spinTimer?.cancel();
    _spin = false;
    _apply1(m);
    final o = _object;
    if (o != null && !_deleted) {
      final t = widget.target;
      _recent..remove(t)..[t] = o;
      if (_recent.length > 20) _recent.remove(_recent.keys.first);
    }
  }

  void _apply1(WatchMessage m) {
    switch (m.type) {
      case 'SNAPSHOT':
        _watch.resetBackoff();
        final rows = m.table?.rows ?? const [];
        if (rows.isEmpty) {
          _deleted = _object != null;
          _error ??= _object == null ? 'Not found' : null;
        } else {
          _object = rows.first.object;
          _deleted = false;
          _error = null;
        }
      case 'ADDED' || 'MODIFIED':
        _object = m.row?.object ?? _object;
        _deleted = false;
      case 'DELETED':
        _deleted = true;
      case 'ERROR':
        _error = m.error;
    }
  }

  @override
  void dispose() {
    moduleStatuses.removeListener(_onModuleStatus);
    pluginHost.removeListener(_onModuleStatus);
    pluginPanels.removeListener(_onModuleStatus);
    _settle?.cancel();
    _spinTimer?.cancel();
    _watch.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    // While stale the body and actions are the previous object's.
    final stale = _staleTarget != null;
    final t = _staleTarget ?? widget.target;
    final obj = _object;
    // Rebuilt when an integration is turned on or off.
    context.select<AppState, Set<String>>((a) => a.disabledModules);
    final panel = panelFor(t.type, app);
    final ctx = obj == null ? null : PanelContext(object: obj, type: t.type, api: context.read<ApiClient>(), app: app);
    final extraTabs = ctx == null ? const <PanelTab>[] : [...panel.tabs(ctx), ...moduleInspectorTabs(ctx)];
    final tabIds = ['Overview', for (final x in extraTabs) x.key, 'YAML', 'Events'];
    // A tab appearing later (a module's detection finishing) recreates the
    // controller; stay on the tab that was open rather than jump to Overview.
    final keptTab = _openTab?.gk == t.type.gk ? tabIds.indexOf(_openTab!.id) : -1;

    final actions = ctx == null || _deleted ? const <ResourceAction>[] : _actionsFor(app, t, panel, ctx);
    final primary = actions.where((a) => !a.destructive && !a.advanced).take(3).toList();
    final others = actions.where((a) => !primary.contains(a)).toList();
    // "Copy kubectl command…" sits after the other safe actions.
    final link = ResourceAction(
      id: 'copy-link',
      label: 'Copy link',
      icon: Icons.link,
      tooltip: 'Copy a link to this object (⌥: the k8sman:// form)',
      run: (context) async => copyLink(context, app, objectLink(app, t)),
    );
    final rest = obj == null || _deleted
        ? others
        : [
            ...others.where((a) => !a.destructive),
            link,
            ResourceAction(
              id: 'kubectl',
              label: 'Copy kubectl…',
              icon: Icons.terminal,
              run: (context) async {
                final box = context.findRenderObject() as RenderBox?;
                final at = box == null ? Offset.zero : box.localToGlobal(Offset(box.size.width, box.size.height));
                await showKubectlMenu(context, at, app: app, type: t.type, refs: [(namespace: t.namespace, name: t.name)], pod: obj);
              },
            ),
            ...others.where((a) => a.destructive),
          ];

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // With no primary actions there is no action row: the destructive
      // ones become header icons instead of a lone ⋯ menu.
      _Header(target: widget.target, deleted: _deleted, actions: primary.isEmpty && !stale ? rest : const []),
      // Namespace, age and labels under the name, on every tab and kind.
      _dim(stale, IdentityStrip(key: ValueKey('identity-${ctx?.uid}'), type: t.type, namespace: t.namespace, object: obj)),
      if (primary.isNotEmpty) _dim(stale, _ActionBar(primary: primary, rest: rest)),
      const Divider(),
      Expanded(
        child: _dim(stale, spin: stale && _spin, obj == null
            ? Center(child: _error != null ? Padding(padding: const EdgeInsets.all(16), child: InlineMessage(_error!, isError: true)) : const CircularProgressIndicator())
            : DefaultTabController(
                // Tab count can change between kinds; key forces a fresh controller.
                key: ValueKey('${t.type.gk}-${extraTabs.length}'),
                length: 3 + extraTabs.length,
                initialIndex: keptTab < 0 ? 0 : keptTab,
                // Native-style: tabs switch instantly (no slide, no gliding indicator).
                animationDuration: Duration.zero,
                child: Builder(builder: (context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  _applyTabRequest(context, app, extraTabs.length),
                  _TabWatch(onIndex: (i) => _openTab = (gk: t.type.gk, id: tabIds[i])),
                  TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      const Tab(text: 'Overview', height: 34),
                      for (final x in extraTabs) Tab(height: 34, child: Row(children: [if (x.icon != null) ...[Icon(x.icon, size: 14), const SizedBox(width: 4)], Text(x.label), ?x.badge?.call(context, ctx!)])),
                      const Tab(text: 'YAML', height: 34),
                      const Tab(text: 'Events', height: 34),
                    ],
                  ),
                  Expanded(
                    // Inspector text is plain Text inside a SelectionArea
                    // (selectable across lines and sections). SelectableText
                    // each carry their own scroll view, which could draw a
                    // frame or two scrolled and then slide into place.
                    child: InstantTabView(children: [
                      // Laid out in full (not a lazy ListView): a handful of
                      // sections, and the scrollbar keeps one size instead of
                      // re-estimating the height as sections scroll in.
                      SelectionArea(child: SingleChildScrollView(
                        key: PageStorageKey('overview-${ctx!.uid}'),
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          // The owner up top (unless the panel's status
                          // header has it); the rest of the metadata last.
                          OverviewTopLine(ctx.object, showOwner: !panel.ownerInHeader),
                          ..._safeSections(context, panel, ctx),
                          if (!panel.showsOwned && ctx.uid.isNotEmpty) OwnedSection(key: ValueKey('owned-${ctx.uid}'), uid: ctx.uid, namespace: ctx.namespace),
                          MetadataSection(key: ValueKey('metadata-${ctx.uid}'), ctx: ctx),
                        ]),
                      )),
                      for (final x in extraTabs) Builder(builder: (c) => x.builder(c, ctx)),
                      YamlEditorTab(key: ValueKey('yaml-${ctx.uid}'), target: t, resourceVersion: dig<String>(obj, ['metadata', 'resourceVersion']) ?? '', editRequest: _editRequest),
                      SelectionArea(child: _EventsTab(namespace: t.namespace, uid: ctx.uid)),
                    ]),
                  ),
                ])),
              ),
        ),
      ),
    ]);
  }

  /// [child] dimmed, inert and optionally with a spinner over it, while it
  /// still shows the previous object.
  static Widget _dim(bool stale, Widget child, {bool spin = false}) => !stale
      ? child
      : Stack(alignment: Alignment.center, children: [
          IgnorePointer(child: Opacity(opacity: 0.55, child: child)),
          if (spin) const CircularProgressIndicator(),
        ]);

  /// Switches to the tab the table asked for (once). Returns an empty
  /// widget so it can sit in the column's children.
  Widget _applyTabRequest(BuildContext context, AppState app, int extraTabs) {
    final req = app.takeDetailTab();
    if (req == null) return const SizedBox.shrink();
    if (req == DetailTab.edit) _editRequest++;
    final index = req == DetailTab.overview ? 0 : 1 + extraTabs;
    final controller = DefaultTabController.of(context);
    if (controller.index != index) {
      WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? controller.index = index : null);
    }
    return const SizedBox.shrink();
  }

  /// Header actions: "Logs" first (and the only kind kept in read-only
  /// mode, since it changes nothing), then port-forward, standard and panel
  /// extras.
  static List<ResourceAction> _actionsFor(AppState app, DetailTarget t, ResourcePanel panel, PanelContext ctx) => resourceActionsFor(app, t, panel, ctx);

  /// A buggy panel shouldn't take down the whole sidebar.
  List<Widget> _safeSections(BuildContext context, ResourcePanel panel, PanelContext ctx) {
    try {
      return panel.buildSections(context, ctx);
    } catch (e, st) {
      debugPrint('panel ${panel.runtimeType} failed: $e\n$st');
      return [
        DetailSection(title: 'Panel error', icon: Icons.bug_report_outlined, child: InlineMessage('${panel.runtimeType}: $e', isError: true)),
        ...const BasicFallbackPanel().buildSections(context, ctx),
      ];
    }
  }
}

/// The primary (non-destructive) actions as buttons. The rest go in a ⋯
/// menu when there are two or more, or a single icon button otherwise.
class _ActionBar extends StatelessWidget {
  final List<ResourceAction> primary;
  final List<ResourceAction> rest;
  const _ActionBar({required this.primary, required this.rest});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 0, 8, 8),
      child: Row(children: [
        Expanded(
          child: Wrap(spacing: 6, runSpacing: 6, children: [
            for (final a in primary)
              Tooltip(
                message: a.tooltip ?? '',
                child: OutlinedButton.icon(
                  key: ValueKey('action-${a.id}'),
                  style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
                  icon: Icon(a.icon, size: 15),
                  label: Text(a.label),
                  onPressed: () => a.run(context),
                ),
              ),
          ]),
        ),
        if (rest.length == 1)
          ActionIconButton(rest.single)
        else if (rest.length > 1)
          PopupMenuButton<ResourceAction>(
            popUpAnimationStyle: AnimationStyle.noAnimation,
            tooltip: 'More actions',
            padding: EdgeInsets.zero,
            iconSize: 18,
            icon: const Icon(Icons.more_horiz, size: 18),
            onSelected: (a) => a.run(context),
            itemBuilder: (_) => [
              for (final a in rest)
                PopupMenuItem(
                  value: a,
                  height: 30,
                  child: Row(children: [
                    Icon(a.icon, size: 16, color: a.destructive ? theme.colorScheme.error : null),
                    const SizedBox(width: 10),
                    Text(a.label, style: TextStyle(color: a.destructive ? theme.colorScheme.error : null)),
                  ]),
                ),
            ],
          ),
      ]),
    );
  }
}

/// An action as a compact icon button (red-tinted when destructive).
class ActionIconButton extends StatelessWidget {
  final ResourceAction action;
  const ActionIconButton(this.action, {super.key});

  @override
  Widget build(BuildContext context) {
    final error = Theme.of(context).colorScheme.error;
    return IconButton(
      key: ValueKey('action-${action.id}'),
      tooltip: action.tooltip ?? action.label,
      icon: Icon(action.icon, size: 16, color: action.destructive ? error.withValues(alpha: 0.85) : null),
      onPressed: () => action.run(context),
    );
  }
}

class _Header extends StatelessWidget {
  final DetailTarget target;
  final bool deleted;

  /// Actions shown as header icons (used when there is no action row).
  final List<ResourceAction> actions;
  const _Header({required this.target, required this.deleted, this.actions = const []});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final meta = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w400);
    // Only the title is a window-drag area; the controls sit at the right
    // end (away from the traffic lights) and never depend on the drag area.
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 10, 8, 8),
      // Narrow: the object's actions fold into a ⋯ menu so the name keeps room.
      child: LayoutBuilder(builder: (context, box) {
        final fold = actions.length > 1 && box.maxWidth < 440;
        return Row(children: [
        if (app.canGoBack) IconButton(tooltip: 'Back', icon: const Icon(Icons.chevron_left, size: 20), onPressed: app.back),
        const SizedBox(width: 6),
        Expanded(
          child: WindowDragArea(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                if (target.type.custom) ...[GroupIcon(group: target.type.group, size: 14), const SizedBox(width: 5)],
                // The kind opens its table (inspector tucked away); the
                // namespace is in the identity strip below.
                Flexible(
                  child: _Crumb(
                    key: const ValueKey('crumb-kind'),
                    text: target.type.kind,
                    tooltip: 'Show all ${target.type.kind}s${target.namespace != null && !app.namespaceScope.contains(target.namespace) ? ' in ${target.namespace}' : ''}',
                    style: meta?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600),
                    onTap: () => app.showInList(target),
                  ),
                ),
                if (deleted) ...[const SizedBox(width: 8), const StatusBadge('Deleted', severity: Severity.error, dense: true)],
              ]),
              const SizedBox(height: 2),
              SelectionArea(child: Text(target.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.titleMedium?.copyWith(fontSize: 15))),
            ]),
          ),
        ),
        if (fold)
          PopupMenuButton<ResourceAction>(
            key: const ValueKey('header-actions-more'),
            tooltip: 'Actions',
            icon: const Icon(Icons.more_horiz, size: 18),
            popUpAnimationStyle: AnimationStyle.noAnimation,
            onSelected: (a) => a.run(context),
            itemBuilder: (_) => [
              for (final a in actions)
                PopupMenuItem(
                  value: a,
                  height: 32,
                  child: Row(children: [
                    Icon(a.icon, size: 16, color: a.destructive ? theme.colorScheme.error : null),
                    const SizedBox(width: 10),
                    Text(a.label, style: a.destructive ? TextStyle(color: theme.colorScheme.error) : null),
                  ]),
                ),
            ],
          )
        else
          for (final a in actions) ActionIconButton(a),
        if (actions.isNotEmpty) Container(width: 1, height: 16, margin: const EdgeInsets.symmetric(horizontal: 6), color: colors.separator),
        _HistoryButton(current: target),
        IconButton(tooltip: 'Copy name', icon: const Icon(Icons.copy_rounded, size: 14), onPressed: () => copyToClipboard(context, target.name)),
        IconButton(
          key: const ValueKey('inspector-collapse'),
          tooltip: 'Collapse inspector (${shortcutLabel('I')})',
          icon: const Icon(Icons.last_page_rounded, size: 17),
          onPressed: app.collapseInspector,
        ),
        IconButton(tooltip: 'Close (Esc)', icon: const Icon(Icons.close, size: 16), onPressed: app.closeDetail),
      ]);
      }),
    );
  }
}

/// A breadcrumb in the inspector header: plain text that underlines on hover.
class _Crumb extends StatelessWidget {
  final String text;
  final String tooltip;
  final TextStyle? style;
  final VoidCallback onTap;
  const _Crumb({super.key, required this.text, required this.tooltip, required this.style, required this.onTap});

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: Hoverable(
          onTap: onTap,
          builder: (h) => Text(
            text,
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
            style: style?.copyWith(decoration: h ? TextDecoration.underline : null, decorationColor: style?.color),
          ),
        ),
      );
}

/// Recently inspected objects on this context, newest first.
class _HistoryButton extends StatelessWidget {
  final DetailTarget current;
  const _HistoryButton({required this.current});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final theme = Theme.of(context);
    final recent = [for (final t in app.recentDetails) if (t != current) t];
    return PopupMenuButton<DetailTarget>(
      key: const ValueKey('inspector-history'),
      popUpAnimationStyle: AnimationStyle.noAnimation,
      tooltip: 'Recently inspected',
      enabled: recent.isNotEmpty,
      // No padding of its own: the icon button theme's 26px square centres it.
      padding: EdgeInsets.zero,
      iconSize: 16,
      icon: const Icon(Icons.history, size: 16),
      onSelected: app.openDetail,
      itemBuilder: (_) => [
        for (final t in recent)
          PopupMenuItem(
            value: t,
            height: 30,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: Row(children: [
                kindIconWidget(t.type, size: 14, color: theme.hintColor),
                const SizedBox(width: 8),
                Flexible(child: Text(t.name, overflow: TextOverflow.ellipsis)),
                const SizedBox(width: 8),
                Text(t.namespace == null ? t.type.kind : '${t.type.kind} · ${t.namespace}',
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
              ]),
            ),
          ),
      ],
    );
  }
}

class _EventsTab extends StatefulWidget {
  final String? namespace;
  final String uid;
  const _EventsTab({required this.namespace, required this.uid});

  @override
  State<_EventsTab> createState() => _EventsTabState();
}

class _EventsTabState extends State<_EventsTab> {
  late Future<List<Json>> _future = _fetch();
  Future<List<Json>> _fetch() => context.read<ApiClient>().events(namespace: widget.namespace, uid: widget.uid);

  @override
  Widget build(BuildContext context) {
    return RefreshIndicator(
      onRefresh: () async => setState(() => _future = _fetch()),
      child: PageScroll(padding: const EdgeInsets.all(12), children: [
        Row(children: [
          const Spacer(),
          IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh, size: 18), onPressed: () => setState(() => _future = _fetch())),
        ]),
        AsyncSection<List<Json>>(future: _future, builder: (context, events) => EventList(events)),
      ]),
    );
  }
}

/// Compact list of core/v1 Events (also usable from panels).
class EventList extends StatelessWidget {
  final List<Json> events;
  const EventList(this.events, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (events.isEmpty) return const InlineMessage('No events (events expire after ~1h by default)');
    return Column(children: [
      for (final e in events)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 72, child: StatusBadge('${e['type'] ?? 'Normal'}', dense: true)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  Flexible(child: Text('${e['reason'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600))),
                  if ((e['count'] ?? 1) > 1) Text('  ×${e['count']}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                  const Spacer(),
                  const SizedBox(width: 8),
                  AgeText(e['lastTimestamp'] ?? e['eventTime'] ?? dig(e, ['metadata', 'creationTimestamp']), suffix: ' ago'),
                ]),
                Text('${e['message'] ?? ''}', style: theme.textTheme.bodySmall),
                if (dig(e, ['source', 'component']) != null || e['reportingComponent'] != null)
                  Text('${dig(e, ['source', 'component']) ?? e['reportingComponent']}${dig(e, ['source', 'host']) != null ? ' on ${dig(e, ['source', 'host'])}' : ''}',
                      style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
              ]),
            ),
          ]),
        ),
    ]);
  }
}


/// Replacement for [TabBarView] that switches instantly instead of sliding.
/// Tabs are built lazily on first visit and then kept alive (offstage), so
/// state such as an in-progress YAML edit or a scroll position survives
/// switching tabs.
class InstantTabView extends StatefulWidget {
  final List<Widget> children;
  const InstantTabView({super.key, required this.children});

  @override
  State<InstantTabView> createState() => _InstantTabViewState();
}

class _InstantTabViewState extends State<InstantTabView> {
  TabController? _controller;
  final Set<int> _visited = {};

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = DefaultTabController.of(context);
    if (c != _controller) {
      _controller?.removeListener(_onTab);
      _controller = c..addListener(_onTab);
      _visited
        ..clear()
        ..add(c.index);
    }
  }

  void _onTab() {
    final i = _controller!.index;
    if (!mounted) return;
    setState(() => _visited.add(i));
  }

  @override
  void dispose() {
    _controller?.removeListener(_onTab);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final index = _controller?.index ?? 0;
    return IndexedStack(
      index: index,
      sizing: StackFit.expand,
      children: [
        for (var i = 0; i < widget.children.length; i++)
          // TickerMode off for hidden tabs so their animations/spinners pause.
          TickerMode(enabled: i == index, child: _visited.contains(i) ? widget.children[i] : const SizedBox.shrink()),
      ],
    );
  }
}

/// The actions offered for an object, in display order. Shared by the
/// inspector header and the table's right-click menu so they always match.
List<ResourceAction> resourceActionsFor(AppState app, DetailTarget t, ResourcePanel panel, PanelContext ctx) {
  final extra = panel.actions(ctx);
  final logs = extra.where((a) => a.id == kLogsActionId).toList();
  if (app.readOnly) return logs;
  final terminal = extra.where((a) => a.id == kTerminalActionId);
  return [
    ...logs,
    ...terminal,
    if (portForwardKinds.containsKey(t.type.gk)) portForwardAction(ctx),
    ...standardActions(ctx),
    ...extra.where((a) => a.id != kLogsActionId && a.id != kTerminalActionId),
  ];
}

/// Reports the enclosing DefaultTabController's index as it changes.
class _TabWatch extends StatefulWidget {
  final ValueChanged<int> onIndex;
  const _TabWatch({required this.onIndex});

  @override
  State<_TabWatch> createState() => _TabWatchState();
}

class _TabWatchState extends State<_TabWatch> {
  TabController? _controller;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final c = DefaultTabController.of(context);
    if (c != _controller) {
      _controller?.removeListener(_changed);
      _controller = c..addListener(_changed);
    }
  }

  void _changed() {
    widget.onIndex(_controller!.index);
  }

  @override
  void dispose() {
    _controller?.removeListener(_changed);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
