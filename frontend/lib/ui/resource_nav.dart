import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../app/kubeconfig_picker.dart';
import '../app/window_chrome.dart';
import '../modules/modules.dart';
import '../plugins/plugin_host.dart';
import '../state/app_state.dart';
import '../state/poller.dart';
import '../state/startup_gate.dart';
import '../util/k8s.dart' show Severity;
import 'context_badge.dart';
import 'keys.dart' show shortcutLabel;
import 'links_ui.dart';
import 'overview/overview_summary.dart';
import 'palette/command_palette.dart';
import 'settings/settings_page.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/group_icon.dart';
import 'views/saved_views_ui.dart';
import 'widgets/dialogs.dart';
import 'widgets/context_menu.dart';

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
  NavGroup('Admission', [
    'admissionregistration.k8s.io/ValidatingAdmissionPolicy',
    'admissionregistration.k8s.io/ValidatingAdmissionPolicyBinding',
    'admissionregistration.k8s.io/MutatingAdmissionPolicy',
    'admissionregistration.k8s.io/MutatingAdmissionPolicyBinding',
    'admissionregistration.k8s.io/ValidatingWebhookConfiguration',
    'admissionregistration.k8s.io/MutatingWebhookConfiguration',
  ]),
];

/// The core sections, then the enabled modules' and the active plugins'
/// sorted by title (the default order, before the user's own).
List<NavGroup> _defaultSections(AppState app) => [
      ..._coreSections,
      ...[for (final m in enabledModules(app)) ...m.navGroups, ...pluginHost.navGroups]
        ..sort((a, b) => a.title.toLowerCase().compareTo(b.title.toLowerCase())),
    ];

/// The kinds list's sections in the user's order (Custom Resources and
/// Other always follow).
List<String> sectionTitles(AppState app) => app.sidebar.orderSections([for (final g in _defaultSections(app)) g.title]);

/// Section title → kinds, in display order.
Map<String, List<String>> _curatedFor(AppState app) {
  final by = {for (final g in _defaultSections(app)) g.title: g.kinds};
  return {for (final t in sectionTitles(app)) t: by[t]!};
}

/// Source-list glyphs for well-known kinds (others get a generic one).
/// The nav's icon for a kind (also used by the collapsed inspector tab).
IconData kindIcon(ResourceType type) => _iconOf(type) ?? (type.custom ? Icons.extension_outlined : Icons.article_outlined);

IconData? _iconOf(ResourceType type) => _kindIcons[type.gk] ?? pluginHost.kindIcons[type.gk] ?? moduleKindIcons[type.gk];

/// [kindIcon], except custom resources without a built-in glyph get their
/// API group's app icon (or a plugin's icon.png).
Widget kindIconWidget(ResourceType type, {double size = 15, Color? color}) {
  if (type.custom && _iconOf(type) == null) {
    final p = pluginHost.pngIconFor(type.gk);
    final png = p == null ? null : pluginHost.iconBytes(p.id);
    if (png != null) return Image.memory(png, width: size, height: size);
    return GroupIcon(group: type.group, size: size);
  }
  return Icon(kindIcon(type), size: size, color: color);
}

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
  'admissionregistration.k8s.io/ValidatingAdmissionPolicy': Icons.policy_outlined,
  'admissionregistration.k8s.io/ValidatingAdmissionPolicyBinding': Icons.link,
  'admissionregistration.k8s.io/MutatingAdmissionPolicy': Icons.auto_fix_high,
  'admissionregistration.k8s.io/MutatingAdmissionPolicyBinding': Icons.link,
  'admissionregistration.k8s.io/ValidatingWebhookConfiguration': Icons.webhook,
  'admissionregistration.k8s.io/MutatingWebhookConfiguration': Icons.change_circle_outlined,
  // Built-ins that land in "Other".
  'scheduling.k8s.io/PriorityClass': Icons.low_priority,
  'node.k8s.io/RuntimeClass': Icons.terminal,
  'coordination.k8s.io/Lease': Icons.lock_clock_outlined,
  'storage.k8s.io/CSIDriver': Icons.settings_input_component_outlined,
  'storage.k8s.io/CSINode': Icons.developer_board_outlined,
  'storage.k8s.io/VolumeAttachment': Icons.attach_file,
  'storage.k8s.io/VolumeAttributesClass': Icons.tune,
  'certificates.k8s.io/CertificateSigningRequest': Icons.verified_outlined,
  'flowcontrol.apiserver.k8s.io/FlowSchema': Icons.filter_alt_outlined,
  'flowcontrol.apiserver.k8s.io/PriorityLevelConfiguration': Icons.speed,
  'apps/ControllerRevision': Icons.history,
  '/PodTemplate': Icons.content_paste_outlined,
  '/ReplicationController': Icons.control_point_duplicate_outlined,
  'storage.k8s.io/CSIStorageCapacity': Icons.data_usage,
  '/ComponentStatus': Icons.fact_check_outlined,
};

/// Monochrome glyphs for the kind rows of curated CRD sections. Elsewhere
/// (palette, inspector) these kinds keep their project's logo.
const _navRowIcons = <String, IconData>{
  'argoproj.io/Application': Icons.apps_outlined,
  'argoproj.io/ApplicationSet': Icons.dashboard_customize_outlined,
  'argoproj.io/AppProject': Icons.folder_special_outlined,
  'gateway.networking.k8s.io/GatewayClass': Icons.category_outlined,
  'gateway.networking.k8s.io/Gateway': Icons.door_front_door_outlined,
  'gateway.networking.k8s.io/HTTPRoute': Icons.alt_route,
  'gateway.networking.k8s.io/GRPCRoute': Icons.route_outlined,
  'gateway.networking.k8s.io/TLSRoute': Icons.lock_outline,
  'gateway.networking.k8s.io/TCPRoute': Icons.cable_outlined,
  'gateway.networking.k8s.io/UDPRoute': Icons.podcasts_outlined,
  'gateway.networking.k8s.io/ReferenceGrant': Icons.handshake_outlined,
  'monitoring.coreos.com/PrometheusRule': Icons.rule,
  'monitoring.coreos.com/ServiceMonitor': Icons.monitor_heart_outlined,
  'monitoring.coreos.com/PodMonitor': Icons.troubleshoot,
  'monitoring.coreos.com/Prometheus': Icons.local_fire_department_outlined,
  'monitoring.coreos.com/Alertmanager': Icons.notifications_none,
  'monitoring.coreos.com/AlertmanagerConfig': Icons.alt_route,
  'monitoring.coreos.com/Probe': Icons.radar,
  'monitoring.coreos.com/ScrapeConfig': Icons.manage_search,
};

/// The sidebar row's glyph: always monochrome (custom resources without a
/// glyph get a generic one; their section header shows the group's logo).
IconData navKindIcon(ResourceType type) => _navRowIcons[type.gk] ?? kindIcon(type);

/// Sidebar labels for built-in kinds: plural and human, short where the
/// kind is long. The tooltip keeps the kind and apiVersion.
const _kindLabels = <String, String>{
  '/Pod': 'Pods',
  'apps/Deployment': 'Deployments',
  'apps/StatefulSet': 'StatefulSets',
  'apps/DaemonSet': 'DaemonSets',
  'apps/ReplicaSet': 'ReplicaSets',
  'batch/Job': 'Jobs',
  'batch/CronJob': 'CronJobs',
  '/Service': 'Services',
  'networking.k8s.io/Ingress': 'Ingresses',
  'networking.k8s.io/IngressClass': 'Ingress Classes',
  'discovery.k8s.io/EndpointSlice': 'Endpoint Slices',
  '/Endpoints': 'Endpoints',
  'networking.k8s.io/NetworkPolicy': 'Network Policies',
  '/ConfigMap': 'ConfigMaps',
  '/Secret': 'Secrets',
  '/ServiceAccount': 'Service Accounts',
  'autoscaling/HorizontalPodAutoscaler': 'Autoscalers',
  '/ResourceQuota': 'Resource Quotas',
  '/LimitRange': 'Limit Ranges',
  'policy/PodDisruptionBudget': 'Disruption Budgets',
  '/PersistentVolumeClaim': 'Volume Claims',
  '/PersistentVolume': 'Persistent Volumes',
  'storage.k8s.io/StorageClass': 'Storage Classes',
  '/Node': 'Nodes',
  '/Namespace': 'Namespaces',
  '/Event': 'Events',
  'apiextensions.k8s.io/CustomResourceDefinition': 'Resource Definitions',
  'apiregistration.k8s.io/APIService': 'API Services',
  'rbac.authorization.k8s.io/Role': 'Roles',
  'rbac.authorization.k8s.io/ClusterRole': 'Cluster Roles',
  'rbac.authorization.k8s.io/RoleBinding': 'Role Bindings',
  'rbac.authorization.k8s.io/ClusterRoleBinding': 'Cluster Role Bindings',
  'admissionregistration.k8s.io/ValidatingAdmissionPolicy': 'Validating Policies',
  'admissionregistration.k8s.io/ValidatingAdmissionPolicyBinding': 'Validating Bindings',
  'admissionregistration.k8s.io/MutatingAdmissionPolicy': 'Mutating Policies',
  'admissionregistration.k8s.io/MutatingAdmissionPolicyBinding': 'Mutating Bindings',
  'admissionregistration.k8s.io/ValidatingWebhookConfiguration': 'Validating Webhooks',
  'admissionregistration.k8s.io/MutatingWebhookConfiguration': 'Mutating Webhooks',
  'scheduling.k8s.io/PriorityClass': 'Priority Classes',
  'node.k8s.io/RuntimeClass': 'Runtime Classes',
  'coordination.k8s.io/Lease': 'Leases',
  'storage.k8s.io/CSIDriver': 'CSI Drivers',
  'storage.k8s.io/CSINode': 'CSI Nodes',
  'storage.k8s.io/VolumeAttachment': 'Volume Attachments',
  'storage.k8s.io/VolumeAttributesClass': 'Volume Attributes',
  'certificates.k8s.io/CertificateSigningRequest': 'Signing Requests',
  'flowcontrol.apiserver.k8s.io/FlowSchema': 'Flow Schemas',
  'flowcontrol.apiserver.k8s.io/PriorityLevelConfiguration': 'Priority Levels',
  'apps/ControllerRevision': 'Controller Revisions',
  '/PodTemplate': 'Pod Templates',
  '/ReplicationController': 'Replication Controllers',
  'storage.k8s.io/CSIStorageCapacity': 'Storage Capacities',
  '/ComponentStatus': 'Component Statuses',
};

/// The sidebar's label for [type]: a hand-written one for built-ins, else
/// the kind made plural when discovery's plural agrees ("HTTPRoute" →
/// "HTTPRoutes"), else discovery's plural title-cased ("applications" →
/// "Applications").
String kindLabel(ResourceType type) {
  final known = _kindLabels[type.gk];
  if (known != null) return known;
  final k = type.kind;
  final lower = k.toLowerCase();
  final plural = lower.endsWith('y') && !RegExp(r'[aeiou]y$').hasMatch(lower)
      ? '${k.substring(0, k.length - 1)}ies'
      : RegExp(r'(s|x|z|ch|sh)$').hasMatch(lower)
          ? '${k}es'
          : '${k}s';
  final r = type.resource;
  if (r.isEmpty || plural.toLowerCase() == r) return plural;
  return r[0].toUpperCase() + r.substring(1);
}

/// What finds page [p] in the palette besides its label and commands: the
/// names of the kinds it is the home of (`Node`, `nodes`, `no`).
List<String> pageKindNames(AppState app, AppPage p) => [
      for (final gk in p.homeFor)
        for (final t in app.types)
          if (t.gk == gk) ...[t.kind, t.resource, ...t.shortNames],
    ];

class ResourceNav extends StatefulWidget {
  const ResourceNav({super.key});

  @override
  State<ResourceNav> createState() => _ResourceNavState();
}

/// Groups shown expanded by default; everything else starts collapsed to
/// keep the sidebar calm. User toggles are remembered for the session.
const _expandedByDefault = {'Views', 'Workloads', 'Network', 'Config'};

/// Below this height the sidebar scrolls as a whole (plus a row's height
/// per top-section row beyond the default seven, e.g. pins).
const _navMinHeight = 520.0;
const _defaultTopRows = 6;
const _topRowHeight = 27.0;

/// A native-style context menu of (label, action) items; null = divider.
Future<void> showSidebarMenu(BuildContext context, Offset globalPosition, List<(String, VoidCallback)?> items) async {
  final chosen = await showContextMenuAt<VoidCallback>(
    context,
    globalPosition,
    [
      for (final i in items)
        if (i == null) const PopupMenuDivider(height: 9) else PopupMenuItem(value: i.$2, height: 28, child: Text(i.$1)),
    ],
    constraints: const BoxConstraints(minWidth: 200, maxWidth: 320),
  );
  chosen?.call();
}

/// Right-click menu for a resource kind (in the kinds list or the table
/// header): pin or unpin it, and with a namespace chosen, pin it scoped to
/// that namespace too.
Future<void> showKindMenu(BuildContext context, Offset globalPosition, ResourceType type) {
  final app = context.read<AppState>();
  final pin = SidebarPin(group: type.group, kind: type.kind);
  final scope = type.namespaced ? app.namespaceScope : NamespaceScope.all;
  final ns = scope.namespaces.join(', ');
  final nsPin = scope.isAll ? null : SidebarPin(group: type.group, kind: type.kind, namespaces: scope.namespaces);
  void toggle(SidebarPin p) => app.setSidebar(app.sidebar.isPinned(p) ? app.sidebar.unpin(p) : app.sidebar.pin(p));
  return showSidebarMenu(context, globalPosition, [
    (app.sidebar.isPinned(pin) ? 'Unpin from Sidebar' : 'Pin to Sidebar', () => toggle(pin)),
    if (nsPin != null) (app.sidebar.isPinned(nsPin) ? 'Unpin “${type.kind} in $ns”' : 'Pin to Sidebar in “$ns”', () => toggle(nsPin)),
    null,
    ('Copy Link to Table', () => copyLink(context, app, tableLink(app, type))),
    null,
    ('Customise Sidebar…', () => openSettings(context, section: SettingsSection.sidebar)),
  ]);
}

/// Session-wide nav UI state (survives the nav being rebuilt/remounted):
/// sections the user explicitly opened (true) or closed (false).
final Map<String, bool> _navExplicit = {};
bool _navMoreOpen = false;

class _ResourceNavState extends State<ResourceNav> with PollingState {
  /// Problem badges: the all-namespaces overview, shared with the Overview
  /// page (see [OverviewSummary] for what this costs).
  late final OverviewSummary _summary = OverviewSummary.of(context.read<AppState>().api);
  String? _summaryContext;

  @override
  void initState() {
    super.initState();
    // Plugins add sidebar sections and kind icons (and hot reload).
    pluginHost.addListener(_onPlugins);
    pluginHost.attach(context.read<AppState>().api);
    poll(OverviewSummary.interval, _pollSummary);
    // First fetch once the first table has painted (see StartupGate).
    StartupGate.ready.then((_) => _pollSummary());
  }

  void _onPlugins() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    pluginHost.removeListener(_onPlugins);
    super.dispose();
  }

  /// Fetches unless the Overview page did recently. Not while connecting.
  Future<bool> _pollSummary() async {
    if (!mounted) return true;
    final app = context.read<AppState>();
    if (app.loading || app.error != null || app.types.isEmpty) return true;
    return _summary.refreshIfStale();
  }

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
    final groups = _group(app.types, curated, homes: kindHomes(app).keys.toSet());
    // A new context (once connected): its badges right away.
    final connected = !app.loading && app.error == null && app.types.isNotEmpty;
    if (connected && app.currentContext != _summaryContext) {
      _summaryContext = app.currentContext;
      scheduleMicrotask(_pollSummary);
    }

    // Top section: the user's layout (pages and pins); hidden pages fold
    // under "More", which opens by itself while one of them is active.
    // Pages of integrations that are turned off don't show at all.
    final layout = app.sidebar;
    final entries = [for (final e in layout.entries) if (e.view == null || pageEnabled(app, e.view!)) e];
    final shown = [for (final e in entries) if (!e.hidden && (e.pin == null || app.typeForPin(e.pin!) != null)) e];
    final folded = [for (final e in entries) if (e.hidden) e];
    // Collapsed, a folded page that's open still shows (alone); the
    // More/Less toggle stays either way.
    final foldedShown = _navMoreOpen ? folded : [for (final e in folded) if (e.view == app.view) e];
    final selectedPin = app.selectedPin;
    final topRows = shown.length + foldedShown.length + (folded.isNotEmpty ? 1 : 0);
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
            // Only macOS windowed has traffic lights here; in fullscreen (and
            // with a native title bar elsewhere) just a little breathing room.
            if (!nativeMacChrome || WindowChromeScope.isFullScreen(context)) return const SizedBox(height: 10);
            final band = toolbarRowHeight(context);
            const button = 32.0;
            final top = (band - button) / 2;
            return SizedBox(
              height: math.max(band - 10, top + button),
              child: Container(
                alignment: Alignment.topCenter,
                padding: EdgeInsets.only(top: top, right: 8),
                // A [button]-tall slot centred on the band's midline.
                // Room for the window buttons only; the sidebar's controls
                // live in its footer.
                child: const SizedBox(height: button),
              ),
            );
          }),
        ),
        const ContextPicker(),
        const SizedBox(height: 6),
        // Right-click on the section's empty space offers Customise too.
        GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTapUp: (d) => showSidebarMenu(context, d.globalPosition, [('Customise Sidebar…', () => openSettings(context, section: SettingsSection.sidebar))]),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final e in shown) _TopEntry(entry: e, selectedPin: selectedPin),
            for (final e in foldedShown) _TopEntry(entry: e, selectedPin: selectedPin),
            if (folded.isNotEmpty)
              _MoreToggle(open: _navMoreOpen, onTap: () => setState(() => _navMoreOpen = !_navMoreOpen)),
          ]),
        ),
        // Finding a kind (or anything else) is the command palette's job.
        const Padding(padding: EdgeInsets.fromLTRB(10, 10, 10, 2), child: PaletteLauncher()),
        Expanded(
          child: ListenableBuilder(listenable: _summary, builder: (context, _) {
            final problems = _summary.forContext(app.api.context);
            KindProblems? worstIn(List<ResourceType> types) {
              KindProblems? w;
              for (final t in types) {
                final p = problems[t.gk];
                if (p != null && (w == null || p.severity.index < w.severity.index)) w = p;
              }
              return w;
            }
            return ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              // Saved views: those for any context and this context's.
              if (app.viewsHere.isNotEmpty || app.viewNotice != null) ...() {
                final collapsed = _isCollapsed('Views', holdsSelection: app.activeView != null);
                return [
                  GestureDetector(
                    behavior: HitTestBehavior.translucent,
                    onSecondaryTapUp: (d) => showSidebarMenu(context, d.globalPosition, _viewsSectionMenu(context)),
                    child: _GroupHeader(title: 'Views', collapsed: collapsed, onTap: () => _toggle('Views', currentlyCollapsed: collapsed)),
                  ),
                  if (app.viewNotice != null) _ViewNotice(text: app.viewNotice!, onDismiss: app.dismissViewNotice),
                  if (!collapsed)
                    for (final v in app.viewsHere) _ViewItem(view: v),
                ];
              }(),
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
                    _GroupHeader(
                      title: g.key,
                      group: custom ? g.key : null,
                      nested: custom,
                      collapsed: collapsed,
                      problems: collapsed ? worstIn(g.value) : null,
                      onTap: () => _toggle(g.key, currentlyCollapsed: collapsed),
                    ),
                    if (!collapsed)
                      for (final t in g.value)
                        _NavItem(type: t, nested: custom, problems: problems[t.gk], selected: app.view == MainView.resources && app.selectedType == t),
                  ],
                ];
              }(),
            ],
          );
          }),
        ),
        const _NavFooter(),
      ]),
    )));
    });
  }

  /// Kinds in [homes] have a page of their own (Node: the Nodes page), so
  /// they aren't listed.
  Map<String, List<ResourceType>> _group(List<ResourceType> types, Map<String, List<String>> curated, {Set<String> homes = const {}}) {
    final byGk = {for (final t in types) if (!homes.contains(t.gk)) t.gk: t};
    final out = <String, List<ResourceType>>{};
    final used = <String>{};
    for (final e in curated.entries) {
      final list = [for (final gk in e.value) if (byGk[gk] != null) byGk[gk]!];
      used.addAll(e.value);
      if (list.isNotEmpty) out[e.key] = list;
    }
    // events.k8s.io/Event duplicates core Event; hide it.
    used
      ..add('events.k8s.io/Event')
      ..addAll(homes);
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

  /// Collapsed sections: the worst problem among their kinds (a dot).
  final KindProblems? problems;
  const _GroupHeader({required this.title, this.group, required this.collapsed, required this.onTap, this.nested = false, this.problems});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = AppColors.of(context).faint;
    return Hoverable(
      onTap: onTap,
      cursor: SystemMouseCursors.basic,
      builder: (h) => Padding(
        padding: EdgeInsets.fromLTRB(nested ? 26 : 18, nested ? 6 : 16, 14, 4),
        child: Row(children: [
          if (group != null) ...[GroupIcon(group: group!, size: 14), const SizedBox(width: 6)],
          Expanded(
            child: Text(title,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: theme.textTheme.labelSmall?.copyWith(
                  color: nested ? faint : theme.hintColor,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.2,
                )),
          ),
          if (problems != null)
            Tooltip(
              waitDuration: const Duration(milliseconds: 600),
              message: 'Problems inside (all namespaces)',
              child: Container(
                key: ValueKey('nav-group-problem-$title'),
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 4),
                decoration: BoxDecoration(color: severityColor(context, problems!.severity.badge), shape: BoxShape.circle),
              ),
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
          if ((leading != null || icon != null) && indent > 10) SizedBox(width: indent - 10),
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

  /// Objects of this kind with problems (all namespaces), if any.
  final KindProblems? problems;

  /// Items of CRD groups nested under "Custom Resources" indent one level.
  final bool nested;
  const _NavItem({required this.type, required this.selected, this.nested = false, this.problems});

  @override
  Widget build(BuildContext context) {
    final p = problems;
    final item = _SourceListItem(
      key: ValueKey('nav-kind-${type.gk}'),
      leading: (color) => Icon(navKindIcon(type), size: 15, color: color),
      label: kindLabel(type),
      indent: nested ? 18 : 10,
      selected: selected,
      trailing: p == null ? null : _ProblemBadge(problems: p),
      onTap: () => context.read<AppState>().selectType(type),
      onSecondaryTap: (pos) => showKindMenu(context, pos, type),
    );
    return Tooltip(
      waitDuration: const Duration(milliseconds: 900),
      message: [
        '${type.kind} · ${type.apiVersion}${type.namespaced ? '' : ' · cluster-scoped'}',
        if (p != null) '${p.count} with problems in all namespaces${p.labels.isEmpty ? '' : ': ${p.labels.join(', ')}'}',
      ].join('\n'),
      child: item,
    );
  }
}

/// A kind row's problem count: a dot and a number in the severity colour.
class _ProblemBadge extends StatelessWidget {
  final KindProblems problems;
  const _ProblemBadge({required this.problems});

  @override
  Widget build(BuildContext context) {
    final c = severityColor(context, problems.severity.badge);
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(
          problems.count > 999 ? '999+' : '${problems.count}',
          style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: c, fontFeatures: const [FontFeature.tabularFigures()]),
        ),
      ]),
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
        // A kind's home page is selected in its Table mode too (not while
        // a saved view of the kind is open: the view's row is).
        selected: context.select<AppState, bool>((a) => a.view == view || (a.viewSession == null && a.activeHomePage == view)),
        onTap: () => app.showView(view),
        onSecondaryTap: (pos) => showSidebarMenu(context, pos, [
          entry.hidden
              ? ('Show $label in Sidebar', () => app.setSidebar(app.sidebar.setHidden(view, false)))
              : ('Hide $label', () => app.setSidebar(app.sidebar.setHidden(view, true))),
          ('Copy Link', () => copyLink(context, app, pageLink(app, view))),
          null,
          ('Customise Sidebar…', () => openSettings(context, section: SettingsSection.sidebar)),
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
      message: '${type.kind} · ${type.apiVersion}${pin.scope.isAll ? '' : ' · in ${pin.namespaces.join(', ')}'}',
      child: _SourceListItem(
        key: ValueKey('nav-pin-${pin.gk}${pin.scope.isAll ? '' : '@${pin.scope.asString}'}'),
        leading: (color) => kindIconWidget(type, color: color),
        label: kindLabel(type),
        selected: selectedPin == pin,
        trailing: pin.scope.isAll
            ? null
            : Flexible(
                child: Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: Text(pin.scope.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.bodySmall?.copyWith(color: AppColors.of(context).faint)),
                ),
              ),
        onTap: () => app.openPin(pin),
        onSecondaryTap: (pos) => showSidebarMenu(context, pos, [
          ('Unpin from Sidebar', () => app.setSidebar(app.sidebar.unpin(pin))),
          null,
          ('Customise Sidebar…', () => openSettings(context, section: SettingsSection.sidebar)),
        ]),
      ),
    );
  }
}

/// The bottom of the sidebar: the Settings gear.
class _NavFooter extends StatelessWidget {
  const _NavFooter();

  @override
  Widget build(BuildContext context) {
    final on = context.select<AppState, bool>((a) => a.view == MainView.settings);
    final theme = Theme.of(context);
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(border: Border(top: BorderSide(color: AppColors.of(context).separator))),
      child: Row(children: [
        IconButton(
          key: const ValueKey('nav-settings'),
          tooltip: 'Settings (${shortcutLabel(',')})',
          iconSize: 17,
          isSelected: on,
          color: theme.hintColor,
          selectedIcon: Icon(Icons.settings, color: theme.colorScheme.primary),
          icon: const Icon(Icons.settings_outlined),
          onPressed: () => openSettings(context),
        ),
        const Spacer(),
        IconButton(
          key: const ValueKey('nav-rediscover'),
          tooltip: 'Rediscover API resources',
          iconSize: 16,
          color: theme.hintColor,
          icon: const Icon(Icons.refresh),
          onPressed: () => context.read<AppState>().refreshTypes(),
        ),
      ]),
    );
  }
}

/// The Views section's menu (right-click on its header).
List<(String, VoidCallback)?> _viewsSectionMenu(BuildContext context) => [
      ('Import Views…', () => showImportViewsDialog(context)),
      ('Import from File…', () => importViewsFromFile(context)),
      if (context.read<AppState>().savedViews.isNotEmpty) ('Export All Views to File…', () => exportAllViewsToFile(context)),
      if (context.read<AppState>().savedViews.isNotEmpty) ('Copy All Views as YAML', () => exportAllViews(context)),
      if (context.read<AppState>().savedViews.length > 1) ('Reorder Views…', () => openSettings(context, section: SettingsSection.views)),
    ];

/// A saved view in the sidebar. The open one is highlighted, with a dot
/// when it has unsaved changes.
class _ViewItem extends StatelessWidget {
  final SavedView view;
  const _ViewItem({required this.view});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final open = app.activeView?.id == view.id && app.view == MainView.resources;
    final modified = open && app.viewSession!.modified;
    return Tooltip(
      waitDuration: const Duration(milliseconds: 900),
      message: [
        view.kind,
        if (view.namespaces.isNotEmpty) view.namespaces.join(', '),
        if (view.filter.isNotEmpty) view.filter,
        view.context == null ? 'any context' : 'only ${view.context!.name}',
        if (app.launchViewId == view.id) 'opens at launch',
      ].join(' · '),
      child: _SourceListItem(
        key: ValueKey('nav-view-item-${view.id}'),
        // Nudged half a pixel so the glyph centres on the label's capitals
        // (checked at 3x against the real font).
        leading: (color) => Transform.translate(
          offset: const Offset(0, 0.5),
          child: Icon(open ? Icons.bookmark : Icons.bookmark_outline, size: 14, color: color),
        ),
        label: view.name,
        selected: open,
        trailing: modified
            ? Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(left: 6),
                decoration: BoxDecoration(color: theme.colorScheme.primary, shape: BoxShape.circle),
              )
            : (view.context != null ? Icon(Icons.link, size: 12, color: AppColors.of(context).faint) : null),
        onTap: () => openSavedView(context, view),
        onSecondaryTap: (pos) => showSidebarMenu(context, pos, [...viewMenuItems(context, view), null, ..._viewsSectionMenu(context)]),
      ),
    );
  }
}

/// A one-off problem with a view (e.g. the launch view couldn't open).
class _ViewNotice extends StatelessWidget {
  final String text;
  final VoidCallback onDismiss;
  const _ViewNotice({required this.text, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 2, 8, 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(padding: const EdgeInsets.only(top: 2), child: Icon(Icons.info_outline, size: 13, color: severityColor(context, Severity.warn))),
        const SizedBox(width: 6),
        Expanded(child: Text(text, style: theme.textTheme.bodySmall)),
        InkWell(onTap: onDismiss, child: Icon(Icons.close, size: 13, color: theme.hintColor)),
      ]),
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

  Future<void> _toggle(BuildContext context, AppState app) => lockContext(context, app.currentContext, !app.readOnly);
}

/// Locks kube context [ctx] (read-only), or after asking, allows changes
/// to it again.
Future<void> lockContext(BuildContext context, String ctx, bool lock) async {
  final app = context.read<AppState>();
  if (lock) return app.setContextReadOnly(ctx, true);
  final auto = (ctx == app.currentContext ? app.readOnlyReason : app.readOnlyContexts[ctx]) == 'auto';
  final ok = await showConfirm(
    context,
    title: 'Allow changes to $ctx?',
    message: auto
        ? 'This context looks like production, so k8sman made it read-only. Allowing changes enables edits, deletes, scaling, Helm changes and exec here. You can lock it again at any time.'
        : 'This enables edits, deletes, scaling, Helm changes and exec on this context. You can lock it again at any time.',
    confirmLabel: 'Allow Changes',
    width: 420,
  );
  if (ok) await app.setContextReadOnly(ctx, false);
}

class ContextPicker extends StatelessWidget {
  const ContextPicker({super.key});

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
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onSecondaryTapUp: (d) {
                  Navigator.pop(context);
                  showSidebarMenu(context, d.globalPosition, [('Change icon & colour…', () => showContextAppearanceDialog(context, c.name))]);
                },
                child: Row(children: [
                  SizedBox(width: 18, child: c.name == app.currentContext ? Icon(Icons.check, size: 14, color: theme.colorScheme.primary) : null),
                  NamedContextBadge(c.name, size: 16),
                  const SizedBox(width: 8),
                  Flexible(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                  if (app.readOnlyContexts.containsKey(c.name)) ...[
                    const SizedBox(width: 6),
                    Tooltip(message: 'Read-only', child: Icon(Icons.lock, size: 12, color: colors.faint)),
                  ],
                ]),
              ),
            ),
        ],
        builder: (h) => GestureDetector(
          behavior: HitTestBehavior.translucent,
          onSecondaryTapUp: current == null
              ? null
              : (d) => showSidebarMenu(context, d.globalPosition, [('Change icon & colour…', () => showContextAppearanceDialog(context, current))]),
          child: Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: BoxDecoration(color: h ? colors.hover : null, borderRadius: BorderRadius.circular(6)),
            child: Row(children: [
              NamedContextBadge(current ?? '', size: 20),
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
              // Translucent, so the keycap sits on the field in light and dark
              // (the opaque separator colour is tuned for the page, not the field).
              decoration: BoxDecoration(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.05),
                border: Border.all(color: theme.colorScheme.onSurface.withValues(alpha: 0.12), width: 0.5),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(shortcutLabel('K'), style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
            ),
          ]),
        ),
      ),
    );
  }
}
