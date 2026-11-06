import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../ui/detail/detail_sidebar.dart' show EventList;
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'logic.dart';
import 'quota_panel.dart';
import 'widgets.dart';

class NamespacePanel extends ResourcePanel {
  const NamespacePanel();

  @override
  Set<String> get kinds => {'/Namespace'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) => [
        DetailSection(title: 'Status', icon: Icons.folder_outlined, child: _NsStatus(ctx)),
        DetailSection(
          title: 'Inventory',
          icon: Icons.inventory_2_outlined,
          child: _Inventory(key: ValueKey(ctx.uid), api: ctx.api, app: ctx.app, namespace: ctx.name),
        ),
        DetailSection(
          title: 'Quotas & limits',
          icon: Icons.data_usage,
          child: _QuotasAndLimits(key: ValueKey(ctx.uid), api: ctx.api, namespace: ctx.name),
        ),
        DetailSection(
          title: 'Recent warnings',
          icon: Icons.warning_amber_rounded,
          child: _Warnings(key: ValueKey(ctx.uid), api: ctx.api, namespace: ctx.name),
        ),
      ];
}

class _NsStatus extends StatelessWidget {
  final PanelContext ctx;
  const _NsStatus(this.ctx);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final phase = ctx.status['phase'] as String? ?? 'Unknown';
    final deleting = ctx.metadata['deletionTimestamp'];
    final terminating = phase == 'Terminating' || deleting != null;
    final specFin = strList(ctx.spec['finalizers']);
    final metaFin = strList(ctx.metadata['finalizers']);
    final conds = asMapList(ctx.status['conditions']);
    // Namespace deletion conditions are all "bad when True".
    final blocking = conds.where((c) => c['status'] == 'True').toList();

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (terminating)
        Callout(
          severity: Severity.error,
          icon: Icons.hourglass_bottom,
          title: 'Terminating',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (deleting != null)
              Row(children: [
                Text('Deletion requested ', style: theme.textTheme.bodySmall),
                AgeText(deleting, suffix: ' ago'),
              ]),
            if (specFin.isNotEmpty || metaFin.isNotEmpty) ...[
              const SizedBox(height: 4),
              Text('Waiting on finalizers:', style: theme.textTheme.bodySmall),
              const SizedBox(height: 2),
              Wrap(spacing: 4, runSpacing: 4, children: [
                for (final f in specFin) Chipish(text: 'spec: $f'),
                for (final f in metaFin) Chipish(text: 'metadata: $f'),
              ]),
            ],
            if (blocking.isNotEmpty) ...[
              const SizedBox(height: 6),
              for (final c in blocking)
                Padding(
                  padding: const EdgeInsets.only(top: 3),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${c['type']}${c['reason'] != null ? ' · ${c['reason']}' : ''}',
                        style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                    if (c['message'] != null) Text('${c['message']}', style: theme.textTheme.bodySmall),
                  ]),
                ),
            ],
          ]),
        ),
      KeyValueTable([
        ('Phase', Align(alignment: Alignment.centerLeft, child: StatusBadge(terminating ? 'Terminating' : phase))),
        ('Finalizers', !terminating && specFin.isNotEmpty ? specFin.join(', ') : null),
        if (!terminating && conds.isNotEmpty)
          ('Conditions', Wrap(spacing: 4, runSpacing: 4, children: [
            for (final c in conds)
              StatusBadge('${c['type']}=${c['status']}', dense: true, severity: c['status'] == 'True' ? Severity.error : Severity.ok),
          ])),
      ], keyWidth: 100),
    ]);
  }
}

/// One inventory bucket: a listable type plus how to summarise its health.
class _Bucket {
  final String label;
  final String group;
  final String resource;
  final String kind;
  final IconData icon;
  const _Bucket(this.label, this.group, this.resource, this.kind, this.icon);
}

const _buckets = [
  _Bucket('Pods', '', 'pods', 'Pod', Icons.view_in_ar_outlined),
  _Bucket('Deployments', 'apps', 'deployments', 'Deployment', Icons.rocket_launch_outlined),
  _Bucket('StatefulSets', 'apps', 'statefulsets', 'StatefulSet', Icons.storage_outlined),
  _Bucket('DaemonSets', 'apps', 'daemonsets', 'DaemonSet', Icons.hub_outlined),
  _Bucket('Jobs', 'batch', 'jobs', 'Job', Icons.task_alt),
  _Bucket('Services', '', 'services', 'Service', Icons.settings_ethernet),
  _Bucket('ConfigMaps', '', 'configmaps', 'ConfigMap', Icons.description_outlined),
  _Bucket('Secrets', '', 'secrets', 'Secret', Icons.key_outlined),
  _Bucket('PVCs', '', 'persistentvolumeclaims', 'PersistentVolumeClaim', Icons.save_outlined),
];

/// Health breakdown for a bucket: (label, severity, count), non-zero only.
List<(String, Severity, int)> inventoryHealth(String resource, List<Json> items) {
  final counts = <(String, Severity), int>{};
  void add(String l, Severity s) => counts[(l, s)] = (counts[(l, s)] ?? 0) + 1;
  for (final i in items) {
    final st = asMap(i['status']);
    switch (resource) {
      case 'pods':
        final s = podKubectlStatus(i);
        final sev = severityOf(s);
        if (s == 'Running') {
          add('running', Severity.ok);
        } else if (s == 'Succeeded' || s == 'Completed') {
          add('done', Severity.neutral);
        } else {
          add(sev == Severity.error ? 'failing' : 'pending', sev == Severity.error ? Severity.error : Severity.warn);
        }
      case 'deployments' || 'statefulsets':
        final want = (dig<num>(i, ['spec', 'replicas']) ?? 1).toInt();
        final ready = (st['readyReplicas'] as num? ?? 0).toInt();
        ready >= want ? add('ready', Severity.ok) : add('degraded', Severity.warn);
      case 'daemonsets':
        final want = (st['desiredNumberScheduled'] as num? ?? 0).toInt();
        final ready = (st['numberReady'] as num? ?? 0).toInt();
        ready >= want ? add('ready', Severity.ok) : add('degraded', Severity.warn);
      case 'jobs':
        if ((st['failed'] as num? ?? 0) > 0 && st['completionTime'] == null && (st['active'] as num? ?? 0) == 0) {
          add('failed', Severity.error);
        } else if ((st['active'] as num? ?? 0) > 0) {
          add('active', Severity.info);
        } else if (st['completionTime'] != null || (st['succeeded'] as num? ?? 0) > 0) {
          add('complete', Severity.neutral);
        }
      case 'persistentvolumeclaims':
        st['phase'] == 'Bound' ? add('bound', Severity.ok) : add('${st['phase'] ?? 'pending'}'.toLowerCase(), Severity.warn);
    }
  }
  final order = [Severity.error, Severity.warn, Severity.info, Severity.ok, Severity.neutral];
  final out = [for (final e in counts.entries) (e.key.$1, e.key.$2, e.value)];
  out.sort((a, b) => order.indexOf(a.$2).compareTo(order.indexOf(b.$2)));
  return out;
}

class _Inventory extends StatefulWidget {
  final ApiClient api;
  final AppState app;
  final String namespace;
  const _Inventory({super.key, required this.api, required this.app, required this.namespace});

  @override
  State<_Inventory> createState() => _InventoryState();
}

class _InventoryState extends State<_Inventory> {
  late Future<List<Object>> _future; // List<Json> or error per bucket

  @override
  void initState() {
    super.initState();
    _future = Future.wait([
      for (final b in _buckets)
        widget.api
            .items(ResourceRef(group: b.group, resource: b.resource), namespace: widget.namespace)
            .then<Object>((v) => v, onError: (Object e) => e),
    ]);
  }

  @override
  Widget build(BuildContext context) => AsyncSection<List<Object>>(
        future: _future,
        builder: (context, results) => LayoutBuilder(builder: (context, box) {
          final cols = box.maxWidth > 420 ? 3 : 2;
          final w = (box.maxWidth - (cols - 1) * 6) / cols;
          // Reserve a second status line only if some tile needs it.
          var lines = 1;
          for (var i = 0; i < _buckets.length; i++) {
            final r = results[i];
            if (r is List<Json> && inventoryHealth(_buckets[i].resource, r).length > 2) lines = 2;
          }
          return Wrap(spacing: 6, runSpacing: 6, children: [
            for (var i = 0; i < _buckets.length; i++)
              SizedBox(width: w, child: _Tile(bucket: _buckets[i], result: results[i], app: widget.app, namespace: widget.namespace, lines: lines)),
          ]);
        }),
      );
}

class _Tile extends StatelessWidget {
  final _Bucket bucket;
  final Object result;
  final AppState app;
  final String namespace;
  final int lines;
  const _Tile({required this.bucket, required this.result, required this.app, required this.namespace, required this.lines});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final items = result is List<Json> ? result as List<Json> : null;
    final type = app.typeFor(bucket.group, bucket.kind);
    final health = items == null ? const <(String, Severity, int)>[] : inventoryHealth(bucket.resource, items);
    final worst = health.isEmpty ? null : health.first.$2;
    final border = worst == Severity.error || worst == Severity.warn ? severityColor(context, worst!) : theme.colorScheme.outlineVariant;
    final count = items?.length;
    return Tooltip(
      message: items == null ? '$result' : 'Show ${bucket.label} in $namespace',
      child: InkWell(
        key: ValueKey('inventory-${bucket.resource}'),
        borderRadius: BorderRadius.circular(6),
        onTap: type == null
            ? null
            : () {
                app.setNamespace(namespace);
                app.selectType(type);
              },
        child: Container(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: border.withValues(alpha: 0.6)),
            color: theme.colorScheme.surfaceContainer,
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(bucket.icon, size: 14, color: theme.hintColor),
              const SizedBox(width: 4),
              Expanded(child: Text(bucket.label, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor))),
              Text(count == null ? '—' : '$count',
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700, color: count == 0 ? theme.hintColor : null)),
            ]),
            SizedBox(
              height: 15.0 * lines + 1,
              child: health.isEmpty
                  ? (items == null ? Text('no access', style: theme.textTheme.labelSmall?.copyWith(color: theme.colorScheme.error)) : null)
                  : Text.rich(
                      TextSpan(children: [
                        for (var i = 0; i < health.length; i++) ...[
                          if (i > 0) TextSpan(text: ' · ', style: TextStyle(color: theme.hintColor)),
                          TextSpan(text: '${health[i].$3} ${health[i].$1}', style: TextStyle(color: severityColor(context, health[i].$2))),
                        ],
                      ]),
                      maxLines: lines,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelSmall,
                    ),
            ),
          ]),
        ),
      ),
    );
  }
}

class _QuotasAndLimits extends StatefulWidget {
  final ApiClient api;
  final String namespace;
  const _QuotasAndLimits({super.key, required this.api, required this.namespace});

  @override
  State<_QuotasAndLimits> createState() => _QuotasAndLimitsState();
}

class _QuotasAndLimitsState extends State<_QuotasAndLimits> {
  late Future<(List<Json>, List<Json>)> _future;

  @override
  void initState() {
    super.initState();
    _future = () async {
      final r = await Future.wait([
        widget.api.items(const ResourceRef(resource: 'resourcequotas'), namespace: widget.namespace),
        widget.api.items(const ResourceRef(resource: 'limitranges'), namespace: widget.namespace),
      ]);
      return (r[0], r[1]);
    }();
  }

  @override
  Widget build(BuildContext context) => AsyncSection<(List<Json>, List<Json>)>(
        future: _future,
        builder: (context, data) {
          final (quotas, limits) = data;
          final theme = Theme.of(context);
          if (quotas.isEmpty && limits.isEmpty) return const InlineMessage('No ResourceQuotas or LimitRanges: namespace is unbounded');
          Widget header(String kind, String name) => Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: ResourceLink(ObjectRef(kind: kind, name: name, namespace: widget.namespace), label: '$kind/$name'),
              );
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final q in quotas) ...[
              header('ResourceQuota', '${dig(q, ['metadata', 'name'])}'),
              QuotaBars(q),
            ],
            for (final l in limits) ...[
              header('LimitRange', '${dig(l, ['metadata', 'name'])}'),
              LimitRangeTables(asMapList(dig(l, ['spec', 'limits']))),
            ],
            if (quotas.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('No ResourceQuota', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
              ),
          ]);
        },
      );
}

class _Warnings extends StatefulWidget {
  final ApiClient api;
  final String namespace;
  const _Warnings({super.key, required this.api, required this.namespace});

  @override
  State<_Warnings> createState() => _WarningsState();
}

class _WarningsState extends State<_Warnings> {
  late Future<List<Json>> _future;

  @override
  void initState() {
    super.initState();
    _future = widget.api.events(namespace: widget.namespace).then((all) => all.where((e) => e['type'] == 'Warning').take(10).toList());
  }

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
        future: _future,
        builder: (context, events) {
          if (events.isEmpty) return const InlineMessage('No Warning events in this namespace', icon: Icons.check_circle_outline);
          final theme = Theme.of(context);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final e in events) ...[
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(children: [
                  Icon(Icons.subdirectory_arrow_right, size: 12, color: theme.hintColor),
                  const SizedBox(width: 2),
                  ResourceLink(ObjectRef.fromOwnerRef(asMap(e['involvedObject']), namespace: widget.namespace)),
                ]),
              ),
              EventList([e]),
            ],
          ]);
        },
      );
}
