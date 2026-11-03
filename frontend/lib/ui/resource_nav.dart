import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../api/models.dart';
import '../state/app_state.dart';

/// Curated groups for built-in kinds, in display order. Anything not listed
/// lands in "Custom Resources" (CRDs, grouped by API group) or "Other".
const _curated = <String, List<String>>{
  'Workloads': ['/Pod', 'apps/Deployment', 'apps/StatefulSet', 'apps/DaemonSet', 'apps/ReplicaSet', 'batch/Job', 'batch/CronJob'],
  'Network': ['/Service', 'networking.k8s.io/Ingress', 'networking.k8s.io/IngressClass', 'discovery.k8s.io/EndpointSlice', '/Endpoints', 'networking.k8s.io/NetworkPolicy'],
  'Config': ['/ConfigMap', '/Secret', '/ServiceAccount', 'autoscaling/HorizontalPodAutoscaler', '/ResourceQuota', '/LimitRange', 'policy/PodDisruptionBudget'],
  'Storage': ['/PersistentVolumeClaim', '/PersistentVolume', 'storage.k8s.io/StorageClass'],
  'Cluster': ['/Node', '/Namespace', '/Event', 'apiextensions.k8s.io/CustomResourceDefinition', 'apiregistration.k8s.io/APIService'],
  'Access Control': [
    'rbac.authorization.k8s.io/Role',
    'rbac.authorization.k8s.io/ClusterRole',
    'rbac.authorization.k8s.io/RoleBinding',
    'rbac.authorization.k8s.io/ClusterRoleBinding',
  ],
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
      color: theme.colorScheme.surfaceContainerLowest,
      child: Column(children: [
        const _ContextPicker(),
        _ViewItem(icon: Icons.monitor_heart_outlined, label: 'Overview', view: MainView.overview, selected: app.view == MainView.overview),
        _ViewItem(icon: Icons.swap_horiz, label: 'Port Forwards', view: MainView.portForwards, selected: app.view == MainView.portForwards),
        const SizedBox(height: 4),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 6),
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 16), hintText: 'Find kind…'),
            style: theme.textTheme.bodySmall,
            onChanged: (v) => setState(() => _query = v.trim()),
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
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
        child: Row(children: [
          Expanded(
            child: Text(title.toUpperCase(),
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, letterSpacing: 0.8, fontWeight: FontWeight.w700)),
          ),
          Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 14, color: theme.hintColor),
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
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Material(
        color: selected ? theme.colorScheme.primaryContainer.withValues(alpha: 0.6) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => context.read<AppState>().selectType(type),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(children: [
              Expanded(child: Text(type.kind, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodyMedium)),
              if (!type.namespaced) Tooltip(message: 'Cluster-scoped', child: Icon(Icons.public, size: 12, color: theme.hintColor)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ViewItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final MainView view;
  final bool selected;
  const _ViewItem({required this.icon, required this.label, required this.view, required this.selected});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Material(
        color: selected ? theme.colorScheme.primaryContainer.withValues(alpha: 0.6) : Colors.transparent,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: () => context.read<AppState>().showView(view),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            child: Row(children: [
              Icon(icon, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 8),
              Expanded(child: Text(label, style: theme.textTheme.bodyMedium)),
            ]),
          ),
        ),
      ),
    );
  }
}

class _ContextPicker extends StatelessWidget {
  const _ContextPicker();

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 10, 8, 4),
      child: Row(children: [
        Icon(Icons.hub_outlined, size: 18, color: theme.colorScheme.primary),
        const SizedBox(width: 6),
        Expanded(
          child: DropdownButton<String>(
            isExpanded: true,
            isDense: true,
            underline: const SizedBox.shrink(),
            value: app.contexts.any((c) => c.name == app.currentContext) ? app.currentContext : null,
            hint: const Text('context'),
            style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
            items: [
              for (final c in app.contexts) DropdownMenuItem(value: c.name, child: Text(c.name, overflow: TextOverflow.ellipsis)),
            ],
            onChanged: (v) => v != null && v != app.currentContext ? app.switchContext(v) : null,
          ),
        ),
        IconButton(
          tooltip: 'Rediscover API resources',
          iconSize: 16,
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.refresh),
          onPressed: () => app.refreshTypes(),
        ),
      ]),
    );
  }
}
