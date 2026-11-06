import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../app/kubeconfig_picker.dart';
import '../app/window_chrome.dart';
import '../modules/modules.dart';
import '../state/app_state.dart';
import '../util/k8s.dart' show Severity;
import 'keys.dart' show shortcutLabel;
import 'palette/command_palette.dart';
import 'sidebar_editor.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/group_icon.dart';

/// Curated sections for built-in kinds, in display order. Modules add
/// theirs (Gateway API, Monitoring, Argo CD, …). Anything not listed lands
/// in "Custom Resources" (CRDs, grouped by API group) or "Other".
const _coreSections = [
  NavGroup('Workloads', ['/Pod', 'apps/Deployment', 'apps/StatefulSet', 'apps/DaemonSet', 'apps/ReplicaSet', 'batch/Job', 'batch/CronJob']),
  NavGroup('Network', ['/Service', 'networking.k8s.io/Ingress', 'networking.k8s.io/IngressClass', 'discovery.k8s.io/EndpointSlice', '/Endpoints', 'networking.k8s.io/NetworkPolicy']),
  NavGroup('Config', ['/ConfigMap', '/Secret', '/ServiceAccount', 'autoscaling/HorizontalPodAutoscaler', '/ResourceQuota', '/LimitRange', 'policy/PodDisruptionBudget']),
  NavGroup('Storage', ['/PersistentVolumeClaim', '/PersistentVolume', 'storage.k8s.io/StorageClass']),
  NavGroup('Cluster', ['/Node', '/Namespace', '/Event', 'apiextensions.k8s.io/CustomResourceDefinition', 'apiregistration.k8s.io/APIService']),
  NavGroup('Access Control', [
    'rbac.authorization.k8s.io/Role',
    'rbac.authorization.k8s.io/ClusterRole',
    'rbac.authorization.k8s.io/RoleBinding',
    'rbac.authorization.k8s.io/ClusterRoleBinding',
  ]),
];

/// Section title → kinds: the core sections plus the enabled modules'.
Map<String, List<String>> _curatedFor(AppState app) => {
      for (final g in placeAfter(_coreSections, [for (final m in enabledModules(app)) ...m.navGroups], (g) => g.title, (g) => g.after)) g.title: g.kinds,
    };

/// Source-list glyphs for well-known kinds (others get a generic one).
/// The nav's icon for a kind (also used by the collapsed inspector tab).
IconData kindIcon(ResourceType type) => _iconOf(type) ?? (type.custom ? Icons.extension_outlined : Icons.article_outlined);

IconData? _iconOf(ResourceType type) => _kindIcons[type.gk] ?? moduleKindIcons[type.gk];

/// [kindIcon], except custom resources without a built-in glyph get their
/// API group's app icon.
Widget kindIconWidget(ResourceType type, {double size = 15, Color? color}) =>
    type.custom && _iconOf(type) == null ? GroupIcon(group: type.group, size: size) : Icon(kindIcon(type), size: size, color: color);

const _kindIcons = <String, IconData>{
  '/Pod': Icons.view_in_ar_outlined,
  'apps/Deployment': Icons.layers_outlined,
  'apps/StatefulSet': Icons.storage_outlined,
  'apps/DaemonSet': Icons.grid_view,
  'apps/ReplicaSet': Icons.copy_all_outlined,
  'batch/Job': Icons.play_circle_outline,
  'batch/CronJob': Icons.schedule,
  '/Service': Icons.lan_outlined,
  'networking.k8s.io/Ingress': Icons.login,
  'networking.k8s.io/IngressClass': Icons.category_outlined,
  'discovery.k8s.io/EndpointSlice': Icons.hub_outlined,
  '/Endpoints': Icons.scatter_plot_outlined,
  'networking.k8s.io/NetworkPolicy': Icons.shield_outlined,
  '/ConfigMap': Icons.description_outlined,
  '/Secret': Icons.key_outlined,
  '/ServiceAccount': Icons.badge_outlined,
  'autoscaling/HorizontalPodAutoscaler': Icons.open_in_full,
  '/ResourceQuota': Icons.pie_chart_outline,
  '/LimitRange': Icons.straighten,
  'policy/PodDisruptionBudget': Icons.health_and_safety_outlined,
  '/PersistentVolumeClaim': Icons.sd_storage_outlined,
  '/PersistentVolume': Icons.album_outlined,
  'storage.k8s.io/StorageClass': Icons.inventory_2_outlined,
  '/Node': Icons.dns_outlined,
  '/Namespace': Icons.folder_outlined,
  '/Event': Icons.bolt_outlined,
  'apiextensions.k8s.io/CustomResourceDefinition': Icons.extension_outlined,
  'apiregistration.k8s.io/APIService': Icons.api,
  'rbac.authorization.k8s.io/Role': Icons.person_outline,
  'rbac.authorization.k8s.io/ClusterRole': Icons.admin_panel_settings_outlined,
  'rbac.authorization.k8s.io/RoleBinding': Icons.link,
  'rbac.authorization.k8s.io/ClusterRoleBinding': Icons.add_link,
};

class ResourceNav extends StatefulWidget {
  const ResourceNav({super.key});

  @override
  State<ResourceNav> createState() => _ResourceNavState();
}

/// Groups shown expanded by default; everything else starts collapsed to
/// keep the sidebar calm. User toggles are remembered for the session.
const _expandedByDefault = {'Workloads', 'Network', 'Config'};

/// Below this height the sidebar scrolls as a whole (plus a row's height
/// per top-section row beyond the default seven, e.g. pins).
const _navMinHeight = 520.0;
const _defaultTopRows = 6;
const _topRowHeight = 27.0;

/// A native-style context menu of (label, action) items; null = divider.
Future<void> showSidebarMenu(BuildContext context, Offset globalPosition, List<(String, VoidCallback)?> items) async {
  final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
  final local = overlay.globalToLocal(globalPosition);
  final chosen = await showMenu<VoidCallback>(
    context: context,
    popUpAnimationStyle: AnimationStyle.noAnimation,
    position: RelativeRect.fromRect(Rect.fromPoints(local, local), Offset.zero & overlay.size),
    constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
    items: [
      for (final i in items)
        if (i == null) const PopupMenuDivider(height: 9) else PopupMenuItem(value: i.$2, height: 28, child: Text(i.$1)),
    ],
  );
  chosen?.call();
}

/// Right-click menu for a resource kind (in the kinds list or the table
/// header): pin or unpin it, and with a namespace chosen, pin it scoped to
/// that namespace too.
Future<void> showKindMenu(BuildContext context, Offset globalPosition, ResourceType type) {
  final app = context.read<AppState>();
  final pin = SidebarPin(group: type.group, kind: type.kind);
  final ns = type.namespaced ? app.namespace : null;
  final nsPin = ns == null ? null : SidebarPin(group: type.group, kind: type.kind, namespace: ns);
  void toggle(SidebarPin p) => app.setSidebar(app.sidebar.isPinned(p) ? app.sidebar.unpin(p) : app.sidebar.pin(p));
  return showSidebarMenu(context, globalPosition, [
    (app.sidebar.isPinned(pin) ? 'Unpin from Sidebar' : 'Pin to Sidebar', () => toggle(pin)),
    if (nsPin != null) (app.sidebar.isPinned(nsPin) ? 'Unpin “${type.kind} in $ns”' : 'Pin to Sidebar in “$ns”', () => toggle(nsPin)),
    null,
    ('Customise Sidebar…', () => showSidebarEditor(context)),
  ]);
}

/// Session-wide nav UI state (survives the nav being rebuilt/remounted):
/// sections the user explicitly opened (true) or closed (false).
final Map<String, bool> _navExplicit = {};
bool _navMoreOpen = false;

class _ResourceNavState extends State<ResourceNav> {
  /// An explicit open/close always wins. Otherwise the default applies,
  /// except that a section holding the current selection auto-opens.
  bool _isCollapsed(String group, {bool holdsSelection = false}) {
    final explicit = _navExplicit[group];
    if (explicit != null) return !explicit;
    return !_expandedByDefault.contains(group) && !holdsSelection;
  }

  void _toggle(String group, {required bool currentlyCollapsed}) => setState(() => _navExplicit[group] = currentlyCollapsed);

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final curated = _curatedFor(app);
    final groups = _group(app.types, curated);

    // Top section: the user's layout (pages and pins); hidden pages fold
    // under "More", which opens by itself while one of them is active.
    // Pages of integrations that are turned off don't show at all.
    final layout = app.sidebar;
    final entries = [for (final e in layout.entries) if (e.view == null || pageEnabled(app, e.view!)) e];
    final shown = [for (final e in entries) if (!e.hidden && (e.pin == null || app.typeForPin(e.pin!) != null)) e];
    final folded = [for (final e in entries) if (e.hidden) e];
    final foldedActive = folded.any((e) => e.view == app.view);
    final moreOpen = _navMoreOpen || foldedActive;
    final selectedPin = app.selectedPin;
    final topRows = shown.length + (moreOpen ? folded.length : 0) + (folded.isNotEmpty && !foldedActive ? 1 : 0);
    final minHeight = _navMinHeight + (topRows - _defaultTopRows).clamp(0, 99) * _topRowHeight;

    // In very short windows the page items alone would overflow: the whole
    // sidebar then scrolls (the kinds list keeps its own scroll otherwise).
    return LayoutBuilder(builder: (context, box) {
      final tall = box.maxHeight >= minHeight;
      return SingleChildScrollView(
        physics: tall ? const NeverScrollableScrollPhysics() : null,
        child: SizedBox(height: tall ? box.maxHeight : minHeight, child: Container(
      // Over the window's vibrancy on macOS; opaque elsewhere.
      color: nativeMacChrome ? Colors.transparent : AppColors.of(context).sidebar,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Unified titlebar row: traffic lights live here on macOS.
        // The buttons stay centred on the traffic lights, but the row
        // ends just below them so the context picker isn't left floating.
        WindowDragArea(
          child: Builder(builder: (context) {
            final band = toolbarRowHeight(context);
            const button = 32.0;
            final top = (band - button) / 2;
            return SizedBox(
              height: math.max(band - 10, top + button),
              child: Container(
                alignment: Alignment.topCenter,
                padding: EdgeInsets.only(top: top, right: 8),
                // A [button]-tall slot centred on the band's midline.
                child: SizedBox(height: button, child: Row(children: [
                  const Spacer(),
                  IconButton(
                    key: const ValueKey('customise-sidebar'),
                    tooltip: 'Customise Sidebar…',
                    icon: const Icon(Icons.tune),
                    onPressed: () => showSidebarEditor(context),
                  ),
                  IconButton(
                    tooltip: 'Rediscover API resources',
                    icon: const Icon(Icons.refresh),
                    onPressed: () => app.refreshTypes(),
                  ),
                ])),
              ),
            );
          }),
        ),
        const _ContextPicker(),
        const SizedBox(height: 6),
        // Right-click on the section's empty space offers Customise too.
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTapUp: (d) => showSidebarMenu(context, d.globalPosition, [('Customise Sidebar…', () => showSidebarEditor(context))]),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final e in shown) _TopEntry(entry: e, selectedPin: selectedPin),
            if (moreOpen)
              for (final e in folded) _TopEntry(entry: e, selectedPin: selectedPin),
            if (folded.isNotEmpty && !foldedActive)
              _MoreToggle(open: _navMoreOpen, onTap: () => setState(() => _navMoreOpen = !_navMoreOpen)),
          ]),
        ),
        // Finding a kind (or anything else) is the command palette's job.
        const Padding(padding: EdgeInsets.fromLTRB(10, 10, 10, 2), child: PaletteLauncher()),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              for (final (i, g) in groups.entries.indexed) ...() {
                // Curated sections (incl. CRD-based ones like Argo CD) stand on
                // their own; only uncurated API groups nest under "Custom Resources".
                bool isCustomSection(String key) => !curated.containsKey(key) && key != 'Other';
                final custom = isCustomSection(g.key);
                final firstCustom = custom && (i == 0 || !isCustomSection(groups.keys.elementAt(i - 1)));
                // Highlighted here even when a pin shows it too, so the list
                // always marks (and expands to) where you are.
                final selectedHere = app.view == MainView.resources && g.value.contains(app.selectedType);
                final customSelected = app.view == MainView.resources && app.selectedType != null && isCustomSection(groups.entries.firstWhere((e) => e.value.contains(app.selectedType), orElse: () => const MapEntry('', [])).key);
                final customCollapsed = _isCollapsed('Custom Resources', holdsSelection: customSelected);
                final collapsed = _isCollapsed(g.key, holdsSelection: selectedHere);
                return [
                  // One umbrella header for all CRD groups, collapsed by default.
                  if (firstCustom)
                    _GroupHeader(title: 'Custom Resources', collapsed: customCollapsed, onTap: () => _toggle('Custom Resources', currentlyCollapsed: customCollapsed)),
                  if (!custom || !customCollapsed) ...[
                    _GroupHeader(title: g.key, group: custom ? g.key : null, nested: custom, collapsed: collapsed, onTap: () => _toggle(g.key, currentlyCollapsed: collapsed)),
                    if (!collapsed)
                      for (final t in g.value)
                        _NavItem(type: t, nested: custom, selected: app.view == MainView.resources && app.selectedType == t),
                  ],
                ];
              }(),
            ],
          ),
        ),
      ]),
    )));
    });
  }

  Map<String, List<ResourceType>> _group(List<ResourceType> types, Map<String, List<String>> curated) {
    final byGk = {for (final t in types) t.gk: t};
    final out = <String, List<ResourceType>>{};
    final used = <String>{};
    for (final e in curated.entries) {
      final list = [for (final gk in e.value) if (byGk[gk] != null) byGk[gk]!];
      used.addAll(e.value);
      if (list.isNotEmpty) out[e.key] = list;
    }
    // events.k8s.io/Event duplicates core Event; hide it.
    used.add('events.k8s.io/Event');
    final custom = <String, List<ResourceType>>{};
    final other = <ResourceType>[];
    for (final t in types) {
      if (used.contains(t.gk)) continue;
      if (t.custom) {
        custom.putIfAbsent(t.group, () => []).add(t);
      } else {
        other.add(t);
      }
    }
    for (final g in (custom.keys.toList()..sort())) {
      out[g] = custom[g]!..sort((a, b) => a.kind.compareTo(b.kind));
    }
    if (other.isNotEmpty) out['Other'] = other..sort((a, b) => a.kind.compareTo(b.kind));
    return out;
  }
}

class _GroupHeader extends StatelessWidget {
  final String title;

  /// API group of a custom-resource section (shows its icon).
  final String? group;
  final bool collapsed;
  final VoidCallback onTap;

  /// CRD groups nest (indent) under the "Custom Resources" header.
  final bool nested;
  const _GroupHeader({required this.title, this.group, required this.collapsed, required this.onTap, this.nested = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = AppColors.of(context).faint;
    return Hoverable(
      onTap: onTap,
      cursor: SystemMouseCursors.basic,
      builder: (h) => Padding(
        padding: EdgeInsets.fromLTRB(nested ? 26 : 18, nested ? 6 : 14, 14, 4),
        child: Row(children: [
          if (group != null) ...[GroupIcon(group: group!, size: 14), const SizedBox(width: 6)],
          Expanded(
            child: Text(title,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: faint, fontWeight: FontWeight.w600, letterSpacing: 0.1)),
          ),
          // Like Finder: the disclosure shows on hover (and when collapsed).
          if (h || collapsed) Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 14, color: h ? theme.hintColor : faint),
        ]),
      ),
    );
  }
}

/// A source-list row: inset, rounded, hover + accent-tinted selection.
class _SourceListItem extends StatelessWidget {
  /// Null for text-only rows (resource kinds).
  final IconData? icon;

  /// A custom glyph in place of [icon] (e.g. a pinned kind's icon), given
  /// the icon colour for the selection state.
  final Widget Function(Color color)? leading;

  /// Left padding inside the row when there's no icon.
  final double indent;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  /// Right-click (context menu) at a global position.
  final void Function(Offset globalPosition)? onSecondaryTap;

  const _SourceListItem(
      {super.key,
      this.icon, this.leading, required this.label, required this.selected, required this.onTap, this.trailing, this.indent = 10, this.onSecondaryTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final iconColor = selected ? theme.colorScheme.primary : theme.hintColor;
    final row = Hoverable(
      onTap: onTap,
      cursor: SystemMouseCursors.basic,
      builder: (h) => Container(
        height: 26,
        margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 0.5),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: selected ? colors.selection : (h ? colors.hover : null),
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(children: [
          if (leading != null) ...[
            SizedBox(width: 15, child: Center(child: leading!(iconColor))),
            const SizedBox(width: 8),
          ] else if (icon != null) ...[
            Icon(icon, size: 15, color: iconColor),
            const SizedBox(width: 8),
          ] else
            SizedBox(width: indent),
          Expanded(
            child: Text(
              label,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: theme.textTheme.bodyMedium?.copyWith(fontWeight: selected ? FontWeight.w500 : FontWeight.w400),
            ),
          ),
          ?trailing,
        ]),
      ),
    );
    if (onSecondaryTap == null) return row;
    return GestureDetector(onSecondaryTapUp: (d) => onSecondaryTap!(d.globalPosition), child: row);
  }
}

class _NavItem extends StatelessWidget {
  final ResourceType type;
  final bool selected;

  /// Items of CRD groups nested under "Custom Resources" indent one level.
  final bool nested;
  const _NavItem({required this.type, required this.selected, this.nested = false});

  @override
  Widget build(BuildContext context) {
    // Text-only rows keep the sidebar calm; scope is in the tooltip.
    final item = _SourceListItem(
      label: type.kind,
      indent: nested ? 18 : 10,
      selected: selected,
      onTap: () => context.read<AppState>().selectType(type),
      onSecondaryTap: (pos) => showKindMenu(context, pos, type),
    );
    return Tooltip(
      waitDuration: const Duration(milliseconds: 900),
      message: '${type.kind} · ${type.apiVersion}${type.namespaced ? '' : ' · cluster-scoped'}',
      child: item,
    );
  }
}

/// A row of the sidebar's top section: a page or a pinned kind. Pins whose
/// kind the current cluster doesn't serve are left out by the caller.
class _TopEntry extends StatelessWidget {
  final SidebarEntry entry;

  /// The pin that holds the current selection, if any.
  final SidebarPin? selectedPin;
  const _TopEntry({required this.entry, required this.selectedPin});

  @override
  Widget build(BuildContext context) {
    final app = context.read<AppState>();
    final view = entry.view;
    if (view != null) {
      final page = pageFor(view)!;
      final (icon, label) = (page.icon, page.label);
      final item = _SourceListItem(
        key: ValueKey('nav-view-${view.name}'),
        icon: icon,
        label: label,
        selected: context.select<AppState, bool>((a) => a.view == view),
        onTap: () => app.showView(view),
        onSecondaryTap: (pos) => showSidebarMenu(context, pos, [
          entry.hidden
              ? ('Show $label in Sidebar', () => app.setSidebar(app.sidebar.setHidden(view, false)))
              : ('Hide $label', () => app.setSidebar(app.sidebar.setHidden(view, true))),
          null,
          ('Customise Sidebar…', () => showSidebarEditor(context)),
        ]),
      );
      // Per-cluster gating applies whatever the layout says.
      return page.navGate?.call(item) ?? item;
    }
    final pin = entry.pin!;
    final type = app.typeForPin(pin);
    if (type == null) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Tooltip(
      waitDuration: const Duration(milliseconds: 900),
      message: '${type.kind} · ${type.apiVersion}${pin.namespace != null ? ' · in ${pin.namespace}' : ''}',
      child: _SourceListItem(
        key: ValueKey('nav-pin-${pin.gk}${pin.namespace != null ? '@${pin.namespace}' : ''}'),
        leading: (color) => kindIconWidget(type, color: color),
        label: type.kind,
        selected: selectedPin == pin,
        trailing: pin.namespace == null
            ? null
            : Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(pin.namespace!,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).faint)),
                ),
              ),
        onTap: () => app.openPin(pin),
        onSecondaryTap: (pos) => showSidebarMenu(context, pos, [
          ('Unpin from Sidebar', () => app.setSidebar(app.sidebar.unpin(pin))),
          null,
          ('Customise Sidebar…', () => showSidebarEditor(context)),
        ]),
      ),
    );
  }
}

/// Cluster context switcher, styled like a workspace switcher.
/// "More" disclosure for the less-used pages.
class _MoreToggle extends StatelessWidget {
  final bool open;
  final VoidCallback onTap;
  const _MoreToggle({required this.open, required this.onTap});

  @override
  Widget build(BuildContext context) => _SourceListItem(
        icon: open ? Icons.expand_less : Icons.more_horiz,
        label: open ? 'Less' : 'More',
        selected: false,
        onTap: onTap,
      );
}

/// "Read-only" / "Changes allowed" for the current context: a lock that
/// blocks edits, deletes, scaling, Helm changes and exec (enforced by the
/// backend). Production-looking contexts start locked.
class ReadOnlyToggle extends StatelessWidget {
  const ReadOnlyToggle({super.key});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final colors = AppColors.of(context);
    final locked = app.readOnly;
    final fixed = app.readOnlyReason == 'flag';
    final label = locked ? 'Read-only' : 'Changes allowed';
    final tip = switch (app.readOnlyReason) {
      'flag' => 'The backend was started with --read-only',
      'auto' => 'Read-only: the name looks like production. Click to allow changes.',
      'context' => 'Read-only (you locked this context). Click to allow changes.',
      _ => 'Click to make this context read-only (blocks edits, deletes, scaling, Helm changes and exec)',
    };
    final color = locked ? severityColor(context, Severity.warn) : colors.faint;
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: Hoverable(
        key: const ValueKey('read-only-toggle'),
        cursor: fixed ? SystemMouseCursors.basic : SystemMouseCursors.click,
        onTap: fixed ? null : () => _toggle(context, app),
        builder: (h) => Container(
          width: 22,
          height: 22,
          decoration: BoxDecoration(color: h && !fixed ? colors.hover : null, borderRadius: BorderRadius.circular(5)),
          child: Semantics(label: label, child: Icon(locked ? Icons.lock : Icons.lock_open, size: 13, color: color)),
        ),
      ),
    );
  }

  Future<void> _toggle(BuildContext context, AppState app) async {
    final ctx = app.currentContext;
    if (!app.readOnly) return app.setContextReadOnly(ctx, true);
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Allow changes to $ctx?'),
        content: SizedBox(
          width: 420,
          child: Text(
            app.readOnlyReason == 'auto'
                ? 'This context looks like production, so k8sman made it read-only. Allowing changes enables edits, deletes, scaling, Helm changes and exec here. You can lock it again at any time.'
                : 'This enables edits, deletes, scaling, Helm changes and exec on this context. You can lock it again at any time.',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Allow Changes')),
        ],
      ),
    );
    if (ok == true) await app.setContextReadOnly(ctx, false);
  }
}

class _ContextPicker extends StatelessWidget {
  const _ContextPicker();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final current = app.contexts.any((c) => c.name == app.currentContext) ? app.currentContext : null;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        MenuButton<String>(
        tooltip: 'Switch cluster context',
        onSelected: (v) => v != app.currentContext ? app.switchContext(v) : null,
        items: () => [
          for (final c in app.contexts)
            PopupMenuItem(
              value: c.name,
              height: 28,
              child: Row(children: [
                SizedBox(width: 18, child: c.name == app.currentContext ? Icon(Icons.check, size: 14, color: theme.colorScheme.primary) : null),
                Flexible(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                if (app.readOnlyContexts.containsKey(c.name)) ...[
                  const SizedBox(width: 6),
                  Tooltip(message: 'Read-only', child: Icon(Icons.lock, size: 12, color: colors.faint)),
                ],
              ]),
            ),
        ],
        builder: (h) => Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(color: h ? colors.hover : null, borderRadius: BorderRadius.circular(6)),
            child: Row(children: [
              Container(
                width: 20,
                height: 20,
                decoration: BoxDecoration(color: theme.colorScheme.primary, borderRadius: BorderRadius.circular(5)),
                child: const Icon(Icons.hub, size: 13, color: Colors.white),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  current ?? 'Select context',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                  style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              if (current != null) ...[const ReadOnlyToggle(), const SizedBox(width: 2)],
              Icon(Icons.unfold_more, size: 14, color: theme.hintColor),
            ]),
          ),
        ),
        // Which kubeconfig file the contexts above come from.
        const KubeconfigPicker(),
      ]),
    );
  }
}

/// Looks like a search field; opens the command palette and shows its
/// shortcut, so the palette is discoverable from every page.
class PaletteLauncher extends StatelessWidget {
  const PaletteLauncher({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final hint = theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor);
    return Tooltip(
      message: 'Search pages, kinds, objects, namespaces and contexts',
      waitDuration: const Duration(milliseconds: 600),
      child: Hoverable(
        key: const ValueKey('palette-launcher'),
        cursor: SystemMouseCursors.text,
        onTap: () => showCommandPalette(context),
        builder: (h) => Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: h ? colors.hover : theme.inputDecorationTheme.fillColor ?? colors.hover,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(children: [
            Icon(Icons.search, size: 15, color: theme.hintColor),
            const SizedBox(width: 6),
            Expanded(child: Text('Search or jump to…', style: hint, overflow: TextOverflow.ellipsis, maxLines: 1)),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(border: Border.all(color: colors.separator), borderRadius: BorderRadius.circular(4)),
              child: Text(shortcutLabel('K'), style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
            ),
          ]),
        ),
      ),
    );
  }
}
