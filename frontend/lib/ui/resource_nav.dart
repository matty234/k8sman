import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../app/kubeconfig_picker.dart';
import '../app/window_chrome.dart';
import '../state/app_state.dart';
import 'alerts/alerts_nav_badge.dart';
import 'theme.dart';
import 'widgets/common.dart';

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
};

/// Source-list glyphs for well-known kinds (others get a generic one).
/// The nav's icon for a kind (also used by the collapsed inspector tab).
IconData kindIcon(ResourceType type) => _kindIcons[type.gk] ?? (type.custom ? Icons.extension_outlined : Icons.article_outlined);

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

class _ResourceNavState extends State<ResourceNav> {
  String _query = '';
  final Set<String> _collapsed = {'Other'};

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

    return Container(
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
        _ViewItem(icon: Icons.sailing_outlined, label: 'Helm', view: MainView.helm, selected: app.view == MainView.helm),
        _ViewItem(icon: Icons.shield_outlined, label: 'Security', view: MainView.security, selected: app.view == MainView.security),
        _ViewItem(icon: Icons.query_stats, label: 'Metrics', view: MainView.metrics, selected: app.view == MainView.metrics),
        _ViewItem(icon: Icons.swap_horiz, label: 'Port Forwards', view: MainView.portForwards, selected: app.view == MainView.portForwards),
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
              for (final g in groups.entries)
                if (g.value.any(matches)) ...[
                  _GroupHeader(
                    title: g.key,
                    collapsed: q.isEmpty && _collapsed.contains(g.key),
                    onTap: () => setState(() => _collapsed.contains(g.key) ? _collapsed.remove(g.key) : _collapsed.add(g.key)),
                  ),
                  if (q.isNotEmpty || !_collapsed.contains(g.key))
                    for (final t in g.value.where(matches)) _NavItem(type: t, selected: app.view == MainView.resources && app.selectedType == t),
                ],
            ],
          ),
        ),
      ]),
    );
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
  final bool collapsed;
  final VoidCallback onTap;
  const _GroupHeader({required this.title, required this.collapsed, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final faint = AppColors.of(context).faint;
    return Hoverable(
      onTap: onTap,
      cursor: SystemMouseCursors.basic,
      builder: (h) => Padding(
        padding: const EdgeInsets.fromLTRB(18, 14, 14, 4),
        child: Row(children: [
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
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Widget? trailing;
  const _SourceListItem({required this.icon, required this.label, required this.selected, required this.onTap, this.trailing});

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
          Icon(icon, size: 15, color: selected ? theme.colorScheme.primary : theme.hintColor),
          const SizedBox(width: 8),
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
  const _NavItem({required this.type, required this.selected});

  @override
  Widget build(BuildContext context) {
    final faint = AppColors.of(context).faint;
    return _SourceListItem(
      icon: kindIcon(type),
      label: type.kind,
      selected: selected,
      onTap: () => context.read<AppState>().selectType(type),
      trailing: type.namespaced ? null : Tooltip(message: 'Cluster-scoped', child: Icon(Icons.public, size: 11, color: faint)),
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
