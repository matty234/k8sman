import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../panels/registry.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import '../logs/open_logs.dart';
import '../terminal/open_terminal.dart';
import '../theme.dart';
import '../widgets/common.dart';
import '../portforward/portforward_dialog.dart';
import 'metadata_section.dart';
import 'yaml_editor.dart';

/// Right-hand sidebar for the current [AppState.detail] target. Keeps the
/// object live via a single-object watch.
class DetailSidebar extends StatelessWidget {
  const DetailSidebar({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final target = app.detail;
    if (target == null) return const SizedBox.shrink();
    return _LiveObject(key: ValueKey(target), target: target);
  }
}

class _LiveObject extends StatefulWidget {
  final DetailTarget target;
  const _LiveObject({super.key, required this.target});

  @override
  State<_LiveObject> createState() => _LiveObjectState();
}

class _LiveObjectState extends State<_LiveObject> {
  Json? _object;
  bool _deleted = false;
  String? _error;
  StreamSubscription<WatchMessage>? _sub;
  Timer? _retry;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  void _subscribe() {
    final t = widget.target;
    _sub?.cancel();
    _sub = context
        .read<ApiClient>()
        .watch(t.type.ref, namespace: t.namespace, fieldSelector: 'metadata.name=${t.name}', includeObject: true)
        .listen((m) {
      setState(() {
        switch (m.type) {
          case 'SNAPSHOT':
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
      });
    }, onError: (Object e) => _reconnect(), onDone: _reconnect);
  }

  void _reconnect() {
    if (!mounted) return;
    _retry?.cancel();
    _retry = Timer(const Duration(seconds: 2), () => mounted ? _subscribe() : null);
  }

  @override
  void dispose() {
    _retry?.cancel();
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final t = widget.target;
    final obj = _object;
    final panel = panelFor(t.type);
    final ctx = obj == null ? null : PanelContext(object: obj, type: t.type, api: context.read<ApiClient>(), app: app);
    final extraTabs = ctx == null ? const <PanelTab>[] : panel.tabs(ctx);

    final actions = ctx == null || _deleted ? const <ResourceAction>[] : _actionsFor(app, t, panel, ctx);
    final primary = actions.where((a) => !a.destructive).take(3).toList();
    final rest = actions.where((a) => !primary.contains(a)).toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      // With no primary actions there is no action row: the destructive
      // ones become header icons instead of a lone ⋯ menu.
      _Header(target: t, deleted: _deleted, actions: primary.isEmpty ? rest : const []),
      if (primary.isNotEmpty) _ActionBar(primary: primary, rest: rest),
      const Divider(),
      Expanded(
        child: obj == null
            ? Center(child: _error != null ? Padding(padding: const EdgeInsets.all(16), child: InlineMessage(_error!, isError: true)) : const CircularProgressIndicator())
            : DefaultTabController(
                // Tab count can change between kinds; key forces a fresh controller.
                key: ValueKey('${t.type.gk}-${extraTabs.length}'),
                length: 3 + extraTabs.length,
                // Native-style: tabs switch instantly (no slide, no gliding indicator).
                animationDuration: Duration.zero,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  TabBar(
                    isScrollable: true,
                    tabAlignment: TabAlignment.start,
                    tabs: [
                      const Tab(text: 'Overview', height: 34),
                      for (final x in extraTabs) Tab(height: 34, child: Row(children: [if (x.icon != null) ...[Icon(x.icon, size: 14), const SizedBox(width: 4)], Text(x.label)])),
                      const Tab(text: 'YAML', height: 34),
                      const Tab(text: 'Events', height: 34),
                    ],
                  ),
                  Expanded(
                    child: InstantTabView(children: [
                      ListView(
                        key: PageStorageKey('overview-${ctx!.uid}'),
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                        children: [
                          MetadataSection(ctx: ctx),
                          ..._safeSections(context, panel, ctx),
                        ],
                      ),
                      for (final x in extraTabs) Builder(builder: (c) => x.builder(c, ctx)),
                      YamlEditorTab(key: ValueKey('yaml-${ctx.uid}'), target: t, resourceVersion: dig<String>(obj, ['metadata', 'resourceVersion']) ?? ''),
                      _EventsTab(namespace: t.namespace, uid: ctx.uid),
                    ]),
                  ),
                ]),
              ),
      ),
    ]);
  }

  /// Header actions: "Logs" first (and the only kind kept in read-only
  /// mode, since it changes nothing), then port-forward, standard and panel
  /// extras.
  static List<ResourceAction> _actionsFor(AppState app, DetailTarget t, ResourcePanel panel, PanelContext ctx) {
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
            tooltip: 'More actions',
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
      child: Row(children: [
        if (app.canGoBack) IconButton(tooltip: 'Back', icon: const Icon(Icons.chevron_left, size: 20), onPressed: app.back),
        const SizedBox(width: 6),
        Expanded(
          child: WindowDragArea(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Text(target.type.kind, style: meta?.copyWith(color: theme.colorScheme.primary, fontWeight: FontWeight.w600)),
                if (target.namespace != null) ...[Text('  ·  ', style: meta), Flexible(child: Text(target.namespace!, overflow: TextOverflow.ellipsis, style: meta))],
                if (deleted) ...[const SizedBox(width: 8), const StatusBadge('Deleted', severity: Severity.error, dense: true)],
              ]),
              const SizedBox(height: 2),
              SelectableText(target.name, maxLines: 1, style: theme.textTheme.titleMedium?.copyWith(fontSize: 15)),
            ]),
          ),
        ),
        for (final a in actions) ActionIconButton(a),
        if (actions.isNotEmpty) Container(width: 1, height: 16, margin: const EdgeInsets.symmetric(horizontal: 6), color: colors.separator),
        IconButton(tooltip: 'Copy name', icon: const Icon(Icons.copy_rounded, size: 14), onPressed: () => copyToClipboard(context, target.name)),
        IconButton(
          key: const ValueKey('inspector-collapse'),
          tooltip: 'Collapse inspector (⌘I)',
          icon: const Icon(Icons.last_page_rounded, size: 17),
          onPressed: app.collapseInspector,
        ),
        IconButton(tooltip: 'Close (Esc)', icon: const Icon(Icons.close, size: 16), onPressed: app.closeDetail),
      ]),
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
      child: ListView(padding: const EdgeInsets.all(12), children: [
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
                  Text('${e['reason'] ?? ''}', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                  if ((e['count'] ?? 1) > 1) Text('  ×${e['count']}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                  const Spacer(),
                  AgeText(e['lastTimestamp'] ?? e['eventTime'] ?? dig(e, ['metadata', 'creationTimestamp']), suffix: ' ago'),
                ]),
                SelectableText('${e['message'] ?? ''}', style: theme.textTheme.bodySmall),
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
