import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../app/kubeconfig_picker.dart';
import '../app/window_chrome.dart';
import '../gpu/gpu_view.dart';
import '../state/app_state.dart';
import 'alerts/alerts_nav_badge.dart';
import 'theme.dart';
import 'widgets/common.dart';
import 'widgets/group_icon.dart';

/// Curated groups for built-in kinds, in display order. Anything not listed
/// lands in "Custom Resources" (CRDs, grouped by API group) or "Other".
const _curated = <String, List<String>>{
  'Workloads': ['/Pod', 'apps/Deployment', 'apps/StatefulSet', 'apps/DaemonSet', 'apps/ReplicaSet', 'batch/Job', 'batch/CronJob'],
  'Network': ['/Service', 'networking.k8s.io/Ingress', 'networking.k8s.io/IngressClass', 'discovery.k8s.io/EndpointSlice', '/Endpoints', 'networking.k8s.io/NetworkPolicy'],
  'Gateway API': [
    'gateway.networking.k8s.io/GatewayClass',
    'gateway.networking.k8s.io/Gateway',
    'gateway.networking.k8s.io/HTTPRoute',
    'gateway.networking.k8s.io/GRPCRoute',
    'gateway.networking.k8s.io/TLSRoute',
    'gateway.networking.k8s.io/TCPRoute',
    'gateway.networking.k8s.io/UDPRoute',
    'gateway.networking.k8s.io/ReferenceGrant',
  ],
  'Config': ['/ConfigMap', '/Secret', '/ServiceAccount', 'autoscaling/HorizontalPodAutoscaler', '/ResourceQuota', '/LimitRange', 'policy/PodDisruptionBudget'],
  'Monitoring': [
    'monitoring.coreos.com/PrometheusRule',
    'monitoring.coreos.com/ServiceMonitor',
    'monitoring.coreos.com/PodMonitor',
    'monitoring.coreos.com/Prometheus',
    'monitoring.coreos.com/Alertmanager',
  ],
  'Storage': ['/PersistentVolumeClaim', '/PersistentVolume', 'storage.k8s.io/StorageClass'],
  'Cluster': ['/Node', '/Namespace', '/Event', 'apiextensions.k8s.io/CustomResourceDefinition', 'apiregistration.k8s.io/APIService'],
  'Access Control': [
    'rbac.authorization.k8s.io/Role',
    'rbac.authorization.k8s.io/ClusterRole',
    'rbac.authorization.k8s.io/RoleBinding',
    'rbac.authorization.k8s.io/ClusterRoleBinding',
  ],
  'Argo CD': ['argoproj.io/Application', 'argoproj.io/ApplicationSet', 'argoproj.io/AppProject'],
  'Argo Workflows': [
    'argoproj.io/Workflow',
    'argoproj.io/CronWorkflow',
    'argoproj.io/WorkflowTemplate',
    'argoproj.io/ClusterWorkflowTemplate',
    'argoproj.io/WorkflowEventBinding',
    'argoproj.io/WorkflowTaskSet',
    'argoproj.io/WorkflowTaskResult',
    'argoproj.io/WorkflowArtifactGCTask',
  ],
};

/// Source-list glyphs for well-known kinds (others get a generic one).
/// The nav's icon for a kind (also used by the collapsed inspector tab).
IconData kindIcon(ResourceType type) => _kindIcons[type.gk] ?? (type.custom ? Icons.extension_outlined : Icons.article_outlined);

/// [kindIcon], except custom resources without a built-in glyph get their
/// API group's app icon.
Widget kindIconWidget(ResourceType type, {double size = 15, Color? color}) =>
    type.custom && !_kindIcons.containsKey(type.gk) ? GroupIcon(group: type.group, size: size) : Icon(kindIcon(type), size: size, color: color);

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
  'argoproj.io/Workflow': Icons.account_tree_outlined,
  'argoproj.io/CronWorkflow': Icons.update,
  'argoproj.io/WorkflowTemplate': Icons.description_outlined,
  'argoproj.io/ClusterWorkflowTemplate': Icons.library_books_outlined,
};

class ResourceNav extends StatefulWidget {
  const ResourceNav({super.key});

  @override
  State<ResourceNav> createState() => _ResourceNavState();
}

/// Groups shown expanded by default; everything else starts collapsed to
/// keep the sidebar calm. User toggles are remembered for the session.
const _expandedByDefault = {'Workloads', 'Network', 'Config'};

/// Below this height the sidebar scrolls as a whole.
const _navMinHeight = 520.0;

/// Pages shown under "More" (the rest are always visible).
const _morePages = {MainView.metrics, MainView.helm, MainView.portForwards, MainView.addons};

/// Session-wide nav UI state (survives the nav being rebuilt/remounted):
/// sections the user explicitly opened (true) or closed (false).
final Map<String, bool> _navExplicit = {};
bool _navMoreOpen = false;

class _ResourceNavState extends State<ResourceNav> {
  String _query = '';

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
    final theme = Theme.of(context);
    final groups = _group(app.types);
    final q = _query.toLowerCase();
    bool matches(ResourceType t) =>
        q.isEmpty ||
        t.kind.toLowerCase().contains(q) ||
        t.resource.contains(q) ||
        t.group.contains(q) ||
        t.shortNames.any((s) => s == q);

    // In very short windows the page items alone would overflow: the whole
    // sidebar then scrolls (the kinds list keeps its own scroll otherwise).
    return LayoutBuilder(builder: (context, box) {
      final tall = box.maxHeight >= _navMinHeight;
      return SingleChildScrollView(
        physics: tall ? const NeverScrollableScrollPhysics() : null,
        child: SizedBox(height: tall ? box.maxHeight : _navMinHeight, child: Container(
      // Over the window's vibrancy on macOS; opaque elsewhere.
      color: nativeMacChrome ? Colors.transparent : AppColors.of(context).sidebar,
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        // Unified titlebar row: traffic lights live here on macOS.
        WindowDragArea(
          child: SizedBox(
            height: toolbarRowHeight(context),
            child: Row(children: [
              const Spacer(),
              IconButton(
                tooltip: 'Rediscover API resources',
                icon: const Icon(Icons.refresh),
                onPressed: () => app.refreshTypes(),
              ),
              const SizedBox(width: 8),
            ]),
          ),
        ),
        const _ContextPicker(),
        const SizedBox(height: 6),
        _ViewItem(icon: Icons.space_dashboard_outlined, label: 'Overview', view: MainView.overview, selected: app.view == MainView.overview),
        _ViewItem(icon: Icons.notifications_none, label: 'Alerts', view: MainView.alerts, selected: app.view == MainView.alerts, trailing: const AlertsNavBadge()),
        _ViewItem(icon: Icons.dns_outlined, label: 'Nodes', view: MainView.nodes, selected: app.view == MainView.nodes),
        GpuNavGate(child: _ViewItem(icon: Icons.memory, label: 'GPUs', view: MainView.gpus, selected: app.view == MainView.gpus)),
        _ViewItem(icon: Icons.shield_outlined, label: 'Security', view: MainView.security, selected: app.view == MainView.security),
        _ViewItem(icon: Icons.manage_accounts_outlined, label: 'Access', view: MainView.access, selected: app.view == MainView.access),
        // Less-used pages fold under "More" (auto-open when one is active).
        if (_navMoreOpen || _morePages.contains(app.view)) ...[
          _ViewItem(icon: Icons.query_stats, label: 'Metrics', view: MainView.metrics, selected: app.view == MainView.metrics),
          _ViewItem(icon: Icons.sailing_outlined, label: 'Helm', view: MainView.helm, selected: app.view == MainView.helm),
          _ViewItem(icon: Icons.swap_horiz, label: 'Port Forwards', view: MainView.portForwards, selected: app.view == MainView.portForwards),
          _ViewItem(icon: Icons.extension_outlined, label: 'Add-ons', view: MainView.addons, selected: app.view == MainView.addons),
        ],
        if (!_morePages.contains(app.view))
          _MoreToggle(open: _navMoreOpen, onTap: () => setState(() => _navMoreOpen = !_navMoreOpen)),
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 2),
          child: SizedBox(
            height: 26,
            child: TextField(
              decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 15), hintText: 'Find kind'),
              style: theme.textTheme.bodyMedium,
              onChanged: (v) => setState(() => _query = v.trim()),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.only(bottom: 12),
            children: [
              for (final (i, g) in groups.entries.indexed) ...() {
                // Curated sections (incl. CRD-based ones like Argo CD) stand on
                // their own; only uncurated API groups nest under "Custom Resources".
                bool isCustomSection(String key) => !_curated.containsKey(key) && key != 'Other';
                final custom = isCustomSection(g.key);
                final firstCustom = custom && (i == 0 || !isCustomSection(groups.keys.elementAt(i - 1)));
                final selectedHere = app.view == MainView.resources && g.value.contains(app.selectedType);
                final customSelected = app.view == MainView.resources && app.selectedType != null && isCustomSection(groups.entries.firstWhere((e) => e.value.contains(app.selectedType), orElse: () => const MapEntry('', [])).key);
                final customCollapsed = q.isEmpty && _isCollapsed('Custom Resources', holdsSelection: customSelected);
                final collapsed = q.isEmpty && _isCollapsed(g.key, holdsSelection: selectedHere);
                if (!g.value.any(matches)) return const <Widget>[];
                return [
                  // One umbrella header for all CRD groups, collapsed by default.
                  if (firstCustom && q.isEmpty)
                    _GroupHeader(title: 'Custom Resources', collapsed: customCollapsed, onTap: () => _toggle('Custom Resources', currentlyCollapsed: customCollapsed)),
                  if (!custom || !customCollapsed || q.isNotEmpty) ...[
                    _GroupHeader(title: g.key, group: custom ? g.key : null, nested: custom, collapsed: collapsed, onTap: () => _toggle(g.key, currentlyCollapsed: collapsed)),
                    if (!collapsed)
                      for (final t in g.value.where(matches)) _NavItem(type: t, nested: custom, selected: app.view == MainView.resources && app.selectedType == t),
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

  Map<String, List<ResourceType>> _group(List<ResourceType> types) {
    final byGk = {for (final t in types) t.gk: t};
    final out = <String, List<ResourceType>>{};
    final used = <String>{};
    for (final e in _curated.entries) {
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

  /// Left padding inside the row when there's no icon.
  final double indent;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;

  const _SourceListItem({this.icon, required this.label, required this.selected, required this.onTap, this.trailing, this.indent = 10});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    return Hoverable(
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
          if (icon != null) ...[
            Icon(icon, size: 15, color: selected ? theme.colorScheme.primary : theme.hintColor),
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
    );
    return Tooltip(
      waitDuration: const Duration(milliseconds: 900),
      message: '${type.kind} · ${type.apiVersion}${type.namespaced ? '' : ' · cluster-scoped'}',
      child: item,
    );
  }
}

class _ViewItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final MainView view;
  final bool selected;
  final Widget? trailing;
  const _ViewItem({required this.icon, required this.label, required this.view, required this.selected, this.trailing});

  @override
  Widget build(BuildContext context) =>
      _SourceListItem(icon: icon, label: label, selected: selected, trailing: trailing, onTap: () => context.read<AppState>().showView(view));
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
