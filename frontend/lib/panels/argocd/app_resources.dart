/// "Managed resources" for an Application: `status.resources` grouped by kind
/// with sync and health badges, problems first, a filter, and an optional
/// resource tree (Deployment → ReplicaSet → Pod) built from ownerReferences.
library;

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'argo_common.dart';
import 'live_health.dart';

enum ResourceFilter { all, outOfSync, unhealthy }

/// One `status.resources` entry plus what we learned from the live object.
class ManagedResource {
  final Json entry;
  final Json? live;
  final LiveHealth? health;
  const ManagedResource(this.entry, this.live, this.health);

  String get group => '${entry['group'] ?? ''}';
  String get kind => '${entry['kind'] ?? ''}';
  String get name => '${entry['name'] ?? ''}';
  String? get namespace {
    final ns = entry['namespace'] as String?;
    return ns == null || ns.isEmpty ? null : ns;
  }

  String get sync => '${entry['status'] ?? 'Unknown'}';
  bool get outOfSync => sync != 'Synced';
  bool get unhealthy => health != null && health!.status != 'Healthy';
  bool get requiresPruning => entry['requiresPruning'] == true;

  /// 0 = worst.
  int get rank {
    final h = health?.status;
    if (h == 'Degraded' || h == 'Missing') return 0;
    if (outOfSync) return 1;
    if (unhealthy) return 2;
    return 3;
  }
}

String resourceKey(String group, String kind, String? ns, String name) => '$group/$kind/${ns ?? ''}/$name';

/// Live objects fetched for an app's resources.
class LiveIndex {
  /// resourceKey → object.
  final Map<String, Json> objects;

  /// owner uid → owned objects (ReplicaSets, Pods, Jobs), each with `kind`.
  final Map<String, List<Json>> children;

  /// Whether a (group/kind/ns) list was fetched, so "absent" means missing.
  final Set<String> listed;
  const LiveIndex(this.objects, this.children, this.listed);

  static const empty = LiveIndex({}, {}, {});
}

/// Builds [ManagedResource]s from `status.resources` and the live index.
/// Persisted health (Argo CD < 3, or `controller.resource.health.persist`)
/// wins over derived health.
List<ManagedResource> managedResources(List<Json> entries, LiveIndex live) {
  return [
    for (final e in entries)
      () {
        final group = '${e['group'] ?? ''}', kind = '${e['kind'] ?? ''}', name = '${e['name'] ?? ''}';
        final ns = (e['namespace'] as String?)?.isEmpty == true ? null : e['namespace'] as String?;
        final obj = live.objects[resourceKey(group, kind, ns, name)];
        final persisted = dig<String>(e, ['health', 'status']);
        LiveHealth? health;
        if (persisted != null) {
          health = LiveHealth(persisted, dig<String>(e, ['health', 'message']));
        } else if (obj != null) {
          health = liveHealth(group, kind, obj);
        } else if (live.listed.contains('$group/$kind/${ns ?? ''}')) {
          health = const LiveHealth('Missing', 'Resource does not exist in the cluster');
        }
        return ManagedResource(e, obj, health);
      }(),
  ];
}

List<ManagedResource> applyFilter(List<ManagedResource> all, ResourceFilter f) => switch (f) {
      ResourceFilter.all => all,
      ResourceFilter.outOfSync => [for (final r in all) if (r.outOfSync) r],
      ResourceFilter.unhealthy => [for (final r in all) if (r.unhealthy) r],
    };

/// Groups by kind; groups and rows are ordered worst first, then by name.
List<MapEntry<String, List<ManagedResource>>> groupByKind(List<ManagedResource> rs) {
  final groups = <String, List<ManagedResource>>{};
  for (final r in rs) {
    groups.putIfAbsent(r.kind, () => []).add(r);
  }
  for (final g in groups.values) {
    g.sort((a, b) => a.rank != b.rank ? a.rank.compareTo(b.rank) : a.name.compareTo(b.name));
  }
  final out = groups.entries.toList();
  int worst(List<ManagedResource> l) => l.map((r) => r.rank).fold(9, (a, b) => a < b ? a : b);
  out.sort((a, b) {
    final c = worst(a.value).compareTo(worst(b.value));
    return c != 0 ? c : a.key.compareTo(b.key);
  });
  return out;
}

const _treeParents = {'apps/Deployment', 'apps/StatefulSet', 'apps/DaemonSet', 'apps/ReplicaSet', 'batch/Job', 'batch/CronJob'};

/// Fetches the live objects for [entries] (one list call per kind and
/// namespace), plus ReplicaSets/Jobs/Pods for the tree.
Future<LiveIndex> loadLiveIndex(PanelContext ctx, List<Json> entries) async {
  final app = ctx.app;
  final lists = <String, (ResourceType, String?)>{};
  final childNs = <String>{};
  final needRs = <String>{}, needJobs = <String>{};
  for (final e in entries) {
    final group = '${e['group'] ?? ''}', kind = '${e['kind'] ?? ''}';
    final t = app.typeFor(group, kind);
    if (t == null) continue;
    final ns = t.namespaced ? (e['namespace'] as String?) : null;
    lists['$group/$kind/${ns ?? ''}'] = (t, ns);
    if (ns != null && _treeParents.contains('$group/$kind')) {
      childNs.add(ns);
      if (kind == 'Deployment') needRs.add(ns);
      if (kind == 'CronJob') needJobs.add(ns);
    }
  }
  final objects = <String, Json>{};
  final listed = <String>{};
  final children = <String, List<Json>>{};

  Future<List<Json>> safe(ResourceRef r, String? ns) => ctx.api.items(r, namespace: ns).catchError((_) => <Json>[]);

  await Future.wait([
    for (final e in lists.entries)
      safe(e.value.$1.ref, e.value.$2).then((items) {
        listed.add(e.key);
        final t = e.value.$1;
        for (final o in items) {
          objects[resourceKey(t.group, t.kind, dig<String>(o, ['metadata', 'namespace']), '${dig(o, ['metadata', 'name'])}')] = o;
        }
      }),
    for (final ns in childNs) ...[
      if (needRs.contains(ns)) _childList(ctx, 'apps', 'ReplicaSet', ns, safe, children),
      if (needJobs.contains(ns)) _childList(ctx, 'batch', 'Job', ns, safe, children),
      _childList(ctx, '', 'Pod', ns, safe, children),
    ],
  ]);
  return LiveIndex(objects, children, listed);
}

Future<void> _childList(PanelContext ctx, String group, String kind, String ns, Future<List<Json>> Function(ResourceRef, String?) safe,
    Map<String, List<Json>> children) async {
  final t = ctx.app.typeFor(group, kind);
  if (t == null) return;
  for (final o in await safe(t.ref, ns)) {
    final withKind = {...o, 'kind': kind, 'apiVersion': t.apiVersion};
    for (final ref in asMapList(dig(o, ['metadata', 'ownerReferences']))) {
      final uid = ref['uid'] as String?;
      if (uid != null) children.putIfAbsent(uid, () => []).add(withKind);
    }
  }
}

/// The Managed resources section body.
class ManagedResourcesView extends StatefulWidget {
  final PanelContext ctx;

  /// Changes when the live objects should be refetched.
  final String refreshKey;
  const ManagedResourcesView({super.key, required this.ctx, required this.refreshKey});

  @override
  State<ManagedResourcesView> createState() => _ManagedResourcesViewState();
}

class _ManagedResourcesViewState extends State<ManagedResourcesView> {
  late Future<LiveIndex> _future;
  LiveIndex _last = LiveIndex.empty;
  ResourceFilter? _filter;
  bool _tree = false;

  List<Json> get _entries => asMapList(widget.ctx.status['resources']);

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  @override
  void didUpdateWidget(ManagedResourcesView old) {
    super.didUpdateWidget(old);
    if (old.refreshKey != widget.refreshKey) _future = _load();
  }

  Future<LiveIndex> _load() async {
    final idx = await loadLiveIndex(widget.ctx, _entries);
    _last = idx;
    return idx;
  }

  @override
  Widget build(BuildContext context) {
    final entries = _entries;
    if (entries.isEmpty) return const Hint('No managed resources yet');
    return FutureBuilder<LiveIndex>(
      future: _future,
      builder: (context, snap) {
        final live = snap.data ?? _last;
        final all = managedResources(entries, live);
        final outOfSync = all.where((r) => r.outOfSync).length;
        final unhealthy = all.where((r) => r.unhealthy).length;
        // Default to problems when there are any, so they're visible at once.
        final filter = _filter ?? ResourceFilter.all;
        final shown = applyFilter(all, filter);
        final hasTree = all.any((r) => (live.children[dig<String>(r.live, ['metadata', 'uid']) ?? ''] ?? const []).isNotEmpty);
        return LayoutBuilder(builder: (context, box) {
          final compact = box.maxWidth < 400;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
              _FilterChip('All ${all.length}', filter == ResourceFilter.all, () => setState(() => _filter = ResourceFilter.all)),
              _FilterChip('Out of sync $outOfSync', filter == ResourceFilter.outOfSync, () => setState(() => _filter = ResourceFilter.outOfSync),
                  severity: outOfSync > 0 ? Severity.warn : null),
              _FilterChip('Unhealthy $unhealthy', filter == ResourceFilter.unhealthy, () => setState(() => _filter = ResourceFilter.unhealthy),
                  severity: unhealthy > 0 ? Severity.error : null),
              if (hasTree) _FilterChip('Tree', _tree, () => setState(() => _tree = !_tree), icon: Icons.account_tree_outlined),
              if (snap.connectionState == ConnectionState.waiting && snap.data == null)
                const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
            ]),
            const SizedBox(height: 6),
            if (shown.isEmpty)
              Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Hint(filter == ResourceFilter.outOfSync ? 'Everything is in sync' : 'Everything is healthy')),
            for (final g in groupByKind(shown)) ...[
              Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: Text('${g.key} · ${g.value.length}',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).hintColor, fontWeight: FontWeight.w600)),
              ),
              for (final r in g.value) ...[
                _ResourceRow(r, compact: compact, destNs: dig<String>(widget.ctx.spec, ['destination', 'namespace'])),
                if (_tree && r.live != null) ..._treeRows(context, live, r.live!, 1, compact),
              ],
            ],
          ]);
        });
      },
    );
  }

  List<Widget> _treeRows(BuildContext context, LiveIndex live, Json parent, int depth, bool compact) {
    if (depth > 3) return const [];
    final uid = dig<String>(parent, ['metadata', 'uid']);
    var kids = [...?live.children[uid]];
    // Hide scaled-down ReplicaSets (old revisions) like Argo CD does.
    kids = [
      for (final k in kids)
        if (!(k['kind'] == 'ReplicaSet' && (dig<num>(k, ['spec', 'replicas']) ?? 0) == 0 && (dig<num>(k, ['status', 'replicas']) ?? 0) == 0)) k,
    ];
    kids.sort((a, b) => '${dig(a, ['metadata', 'name'])}'.compareTo('${dig(b, ['metadata', 'name'])}'));
    return [
      for (final k in kids) ...[
        _TreeRow(k, depth: depth, compact: compact),
        ..._treeRows(context, live, k, depth + 1, compact),
      ],
    ];
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  final Severity? severity;
  final IconData? icon;
  const _FilterChip(this.label, this.selected, this.onTap, {this.severity, this.icon});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = severity == null ? theme.colorScheme.primary : severityColor(context, severity!);
    return Hoverable(
      onTap: onTap,
      builder: (h) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.18) : chipFill(context, hovered: h),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: selected ? accent.withValues(alpha: 0.6) : Colors.transparent),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 12, color: selected ? accent : theme.hintColor), const SizedBox(width: 4)],
          Text(label,
              style: theme.textTheme.bodySmall?.copyWith(
                color: selected ? accent : (severity != null ? accent : null),
                fontWeight: selected ? FontWeight.w600 : null,
              )),
        ]),
      ),
    );
  }
}

class _ResourceRow extends StatelessWidget {
  final ManagedResource r;
  final bool compact;
  final String? destNs;
  const _ResourceRow(this.r, {required this.compact, this.destNs});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final health = r.health;
    final showMsg = health != null && health.status != 'Healthy' && (health.message ?? '').isNotEmpty;
    final otherNs = r.namespace != null && r.namespace != destNs;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Expanded(
            child: Row(children: [
              Flexible(child: OneLineRef(ObjectRef(group: r.group, kind: r.kind, name: r.name, namespace: r.namespace))),
              if (otherNs) ...[
                const SizedBox(width: 6),
                Flexible(child: Text(r.namespace!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))),
              ],
              if (r.requiresPruning) ...[
                const SizedBox(width: 6),
                Tooltip(
                  message: 'Not in git any more: a sync with prune deletes it',
                  child: Text('prune', style: theme.textTheme.labelSmall?.copyWith(color: severityColor(context, Severity.warn))),
                ),
              ],
            ]),
          ),
          const SizedBox(width: 6),
          _badgeBox(context, ArgoBadge.sync(context, r.sync, tooltip: compact ? r.sync : null, iconOnly: compact), compact, 88),
          _badgeBox(
              context,
              health == null
                  ? Tooltip(message: 'No health check for ${r.kind}', child: Text('—', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)))
                  : ArgoBadge.health(context, health.status, tooltip: health.toString(), iconOnly: compact),
              compact,
              96),
        ]),
        if (showMsg)
          Padding(
            padding: const EdgeInsets.only(left: 2, bottom: 2),
            child: Text(health.message!,
                maxLines: 2, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: healthStyle(context, health.status).color)),
          ),
      ]),
    );
  }
}

/// Fixed-width badge column (icon-only badges get a narrow one).
Widget _badgeBox(BuildContext context, Widget badge, bool compact, double width) => SizedBox(width: compact ? 22 : width, child: badge);

class _TreeRow extends StatelessWidget {
  final Json obj;
  final int depth;
  final bool compact;
  const _TreeRow(this.obj, {required this.depth, required this.compact});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final kind = '${obj['kind']}';
    final apiVersion = '${obj['apiVersion'] ?? 'v1'}';
    final group = apiVersion.contains('/') ? apiVersion.split('/').first : '';
    final name = '${dig(obj, ['metadata', 'name'])}';
    final ns = dig<String>(obj, ['metadata', 'namespace']);
    final h = liveHealth(group, kind, obj);
    return Padding(
      padding: EdgeInsets.only(left: 14.0 * depth, top: 1, bottom: 1),
      child: Row(children: [
        Icon(Icons.subdirectory_arrow_right, size: 13, color: theme.hintColor),
        const SizedBox(width: 4),
        Text(kind == 'ReplicaSet' ? 'rs' : (kind == 'Pod' ? 'pod' : kind.toLowerCase()), style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
        const SizedBox(width: 6),
        Expanded(child: OneLineRef(ObjectRef(group: group, kind: kind, name: name, namespace: ns))),
        const SizedBox(width: 6),
        if (h != null) _badgeBox(context, ArgoBadge.health(context, h.status, tooltip: h.toString(), iconOnly: compact), compact, 96),
      ]),
    );
  }
}
