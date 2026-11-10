import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../ui/detail/detail_sidebar.dart' show EventList;
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../../ui/inspector/inspector.dart';
import '../panel.dart';
import 'logic.dart';
import 'quota_panel.dart';

class NamespacePanel extends ResourcePanel {
  const NamespacePanel();

  @override
  Set<String> get kinds => {'/Namespace'};

  @override
  bool get ownerInHeader => true;

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) => [
        CoreSection('overview', _NamespaceView(key: ValueKey(ctx.uid), ctx: ctx)),
        CoreSection('quotas', _QuotaSection(key: ValueKey('${ctx.uid}/quotas'), api: ctx.api, namespace: ctx.name)),
        CoreSection('warnings', InspectorSection(
          id: 'ns-warnings',
          title: 'Recent warnings',
          child: _Warnings(key: ValueKey('${ctx.uid}/warnings'), api: ctx.api, namespace: ctx.name),
        )),
      ];
}

/// Quotas and limit ranges, collapsed behind a count; one fetch for the
/// summary and the body.
class _QuotaSection extends StatefulWidget {
  final ApiClient api;
  final String namespace;
  const _QuotaSection({super.key, required this.api, required this.namespace});

  @override
  State<_QuotaSection> createState() => _QuotaSectionState();
}

class _QuotaSectionState extends State<_QuotaSection> {
  late final Future<(List<Json>, List<Json>)> _future = () async {
    final r = await Future.wait([
      widget.api.items(const ResourceRef(resource: 'resourcequotas'), namespace: widget.namespace),
      widget.api.items(const ResourceRef(resource: 'limitranges'), namespace: widget.namespace),
    ]);
    return (r[0], r[1]);
  }();

  @override
  Widget build(BuildContext context) => InspectorSection(
        id: 'ns-quotas',
        title: 'Quotas & limits',
        initiallyExpanded: false,
        trailing: FutureBuilder<(List<Json>, List<Json>)>(
          future: _future,
          builder: (context, snap) {
            final d = snap.data;
            if (d == null) return const SizedBox.shrink();
            final (q, l) = d;
            return SectionSummary(q.isEmpty && l.isEmpty ? 'unbounded' : [if (q.isNotEmpty) plural(q.length, 'quota'), if (l.isNotEmpty) plural(l.length, 'limit range')].join(' · '));
          },
        ),
        child: _QuotasAndLimits(future: _future, namespace: widget.namespace),
      );
}

/// The namespace's status header (phase, resource counts) and its
/// inventory as compact rows, from one fetch per bucket.
class _NamespaceView extends StatefulWidget {
  final PanelContext ctx;
  const _NamespaceView({super.key, required this.ctx});

  @override
  State<_NamespaceView> createState() => _NamespaceViewState();
}

class _NamespaceViewState extends State<_NamespaceView> {
  late final Future<List<Object>> _future = Future.wait([
    for (final b in _buckets)
      widget.ctx.api
          .items(ResourceRef(group: b.group, resource: b.resource), namespace: widget.ctx.name)
          .then<Object>((v) => v, onError: (Object e) => e),
  ]); // List<Json> or error per bucket

  PanelContext get ctx => widget.ctx;

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Object>>(
        future: _future,
        builder: (context, snap) {
          final results = snap.data;
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            _header(context, results),
            InspectorSection(
              id: 'ns-inventory',
              title: 'Inventory',
              trailing: SectionSummary(results == null ? '' : '${[for (final r in results) if (r is List<Json>) r.length].fold<int>(0, (a, b) => a + b)} objects'),
              child: snap.hasError
                  ? InlineMessage('${snap.error}', isError: true)
                  : results == null
                      ? const SectionSpinner()
                      : _Inventory(results: results, app: ctx.app, namespace: ctx.name),
            ),
          ]);
        },
      );

  Widget _header(BuildContext context, List<Object>? results) {
    final theme = Theme.of(context);
    final phase = ctx.status['phase'] as String? ?? 'Unknown';
    final deleting = ctx.metadata['deletionTimestamp'];
    final terminating = phase == 'Terminating' || deleting != null;
    final specFin = strList(ctx.spec['finalizers']);
    final metaFin = strList(ctx.metadata['finalizers']);
    final conds = asMapList(ctx.status['conditions']);
    // Namespace deletion conditions are all "bad when True".
    final blocking = conds.where((c) => c['status'] == 'True').toList();
    List<Json>? items(String resource) {
      final i = _buckets.indexWhere((b) => b.resource == resource);
      final r = results?[i];
      return r is List<Json> ? r : null;
    }

    final pods = items('pods');
    final podHealth = pods == null ? const <(String, Severity, int)>[] : inventoryHealth('pods', pods);
    final failing = podHealth.where((h) => h.$2 == Severity.error).fold<int>(0, (a, h) => a + h.$3);
    final pending = podHealth.where((h) => h.$2 == Severity.warn).fold<int>(0, (a, h) => a + h.$3);
    final workloads = [for (final r in ['deployments', 'statefulsets', 'daemonsets']) ...?items(r)];
    final degraded = [for (final r in ['deployments', 'statefulsets', 'daemonsets']) ...inventoryHealth(r, items(r) ?? const [])]
        .where((h) => h.$2 == Severity.warn)
        .fold<int>(0, (a, h) => a + h.$3);
    final services = items('services');
    final insights = <Insight>[
      if (terminating)
        Insight(
          Severity.error,
          'Terminating',
          specFin.isNotEmpty || metaFin.isNotEmpty ? 'Waiting on finalizers (below).' : 'Deletion is in progress.',
        ),
      if (terminating)
        for (final c in blocking) Insight(Severity.error, '${c['type']}${c['reason'] != null ? ' · ${c['reason']}' : ''}', c['message'] as String?),
      if (failing > 0) Insight(Severity.error, failing == 1 ? '1 pod failing' : '$failing pods failing'),
      if (pending > 0) Insight(Severity.warn, pending == 1 ? '1 pod pending' : '$pending pods pending'),
      if (degraded > 0) Insight(Severity.warn, degraded == 1 ? '1 workload degraded' : '$degraded workloads degraded'),
    ];
    final counts = [
      if (pods != null) plural(pods.length, 'pod'),
      if (items('deployments') != null) plural(items('deployments')!.length, 'deployment'),
      if (services != null) plural(services.length, 'service'),
    ].join(' · ');
    return InspectorHeader(
      mark: worstOf(insights) ?? (results == null ? Severity.neutral : Severity.ok),
      headline: terminating ? 'Terminating' : phase,
      detail: counts,
      figures: [
        InspectorFigure(pods == null ? '–' : '${pods.length}', 'pods', severity: failing > 0 ? Severity.error : (pending > 0 ? Severity.warn : Severity.neutral)),
        InspectorFigure(results == null ? '–' : '${workloads.length}', 'workloads', severity: degraded > 0 ? Severity.warn : Severity.neutral),
        InspectorFigure(services == null ? '–' : '${services.length}', 'services'),
      ],
      insights: insights,
      factsKeyWidth: 82, facts: [
        ?ownerFact(ctx.object),
        if (deleting != null)
          ('Deleting', Row(children: [Text('requested ', style: theme.textTheme.bodySmall), AgeText(deleting, suffix: ' ago', style: theme.textTheme.bodySmall)])),
        (
          'Finalizers',
          specFin.isEmpty && metaFin.isEmpty
              ? null
              : Wrap(spacing: 4, runSpacing: 4, children: [
                  for (final f in specFin) Chipish(text: terminating ? 'spec: $f' : f),
                  for (final f in metaFin) Chipish(text: 'metadata: $f'),
                ]),
        ),
        if (!terminating && conds.isNotEmpty)
          (
            'Conditions',
            Wrap(spacing: 4, runSpacing: 4, children: [
              for (final c in conds) StatusBadge('${c['type']}=${c['status']}', dense: true, severity: c['status'] == 'True' ? Severity.error : Severity.ok),
            ]),
          ),
      ],
    );
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

/// The inventory buckets as compact rows: the worst state's dot, the kind,
/// its health breakdown (coloured only when wrong) and the count. A click
/// opens the kind's table in this namespace.
class _Inventory extends StatelessWidget {
  final List<Object> results;
  final AppState app;
  final String namespace;
  const _Inventory({required this.results, required this.app, required this.namespace});

  @override
  Widget build(BuildContext context) {
    final rows = [for (var i = 0; i < _buckets.length; i++) (_buckets[i], results[i])];
    int rank((_Bucket, Object) r) {
      final items = r.$2 is List<Json> ? r.$2 as List<Json> : null;
      if (items == null) return 2;
      final h = inventoryHealth(r.$1.resource, items);
      final worst = h.isEmpty ? null : h.first.$2;
      return worst == Severity.error ? 0 : (worst == Severity.warn ? 1 : (items.isEmpty ? 4 : 3));
    }

    final ordered = [...rows]..sort((a, b) => rank(a).compareTo(rank(b)));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (b, r) in ordered) _row(context, b, r),
    ]);
  }

  Widget _row(BuildContext context, _Bucket bucket, Object result) {
    final theme = Theme.of(context);
    final items = result is List<Json> ? result : null;
    final type = app.typeFor(bucket.group, bucket.kind);
    final health = items == null ? const <(String, Severity, int)>[] : inventoryHealth(bucket.resource, items);
    final worst = health.isEmpty ? null : health.first.$2;
    final sev = items == null
        ? Severity.neutral
        : worst == Severity.error || worst == Severity.warn
            ? worst!
            : items.isEmpty
                ? Severity.neutral
                : Severity.ok;
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Tooltip(
      message: items == null ? '$result' : 'Show ${bucket.label} in $namespace',
      waitDuration: const Duration(milliseconds: 600),
      child: Hoverable(
        key: ValueKey('inventory-${bucket.resource}'),
        onTap: type == null
            ? null
            : () {
                app.setNamespace(namespace);
                app.selectType(type);
              },
        builder: (h) => Container(
          decoration: BoxDecoration(color: h ? AppColors.of(context).hover : null, borderRadius: BorderRadius.circular(5)),
          padding: const EdgeInsets.fromLTRB(4, 6, 4, 6),
          child: Row(children: [
            RowDot(sev),
            const SizedBox(width: 8),
            SizedBox(width: 96, child: Text(bucket.label, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(fontSize: 12.5))),
            Expanded(
              child: items == null
                  ? Text('no access', style: hint?.copyWith(color: severityColor(context, Severity.error)))
                  : Text.rich(
                      TextSpan(style: hint, children: [
                        for (var i = 0; i < health.length; i++) ...[
                          if (i > 0) const TextSpan(text: ' · '),
                          TextSpan(
                            text: '${health[i].$3} ${health[i].$1}',
                            style: health[i].$2 == Severity.error || health[i].$2 == Severity.warn ? TextStyle(color: severityColor(context, health[i].$2), fontWeight: FontWeight.w600) : null,
                          ),
                        ],
                      ]),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
            ),
            const SizedBox(width: 8),
            Text(items == null ? '—' : '${items.length}',
                style: theme.textTheme.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()], fontWeight: FontWeight.w600, color: items == null || items.isEmpty ? theme.hintColor : null)),
          ]),
        ),
      ),
    );
  }
}

class _QuotasAndLimits extends StatelessWidget {
  final Future<(List<Json>, List<Json>)> future;
  final String namespace;
  const _QuotasAndLimits({required this.future, required this.namespace});

  @override
  Widget build(BuildContext context) => AsyncSection<(List<Json>, List<Json>)>(
        future: future,
        builder: (context, data) {
          final (quotas, limits) = data;
          final theme = Theme.of(context);
          if (quotas.isEmpty && limits.isEmpty) return const InlineMessage('No ResourceQuotas or LimitRanges: namespace is unbounded');
          Widget header(String kind, String name) => Padding(
                padding: const EdgeInsets.only(top: 6, bottom: 2),
                child: ResourceLink(ObjectRef(kind: kind, name: name, namespace: namespace), label: '$kind/$name'),
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
