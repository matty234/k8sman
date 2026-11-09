import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../../ui/inspector/inspector.dart';
import '../panel.dart';
import '../pod/pod_widgets.dart' show InlineWrap;
import 'gw_model.dart';
import 'gw_widgets.dart';

/// Everything a route view looks up besides the route itself.
class RouteLookups {
  /// "ns/name" of each parent Gateway → object (null = 404).
  final Map<String, Json?> gateways;

  /// BackendRef.key → exists (null = unknown).
  final Map<String, bool?> backends;

  /// ReferenceGrants in the namespaces of cross-namespace backends.
  final List<Json> grants;

  /// Namespace labels, fetched only when a listener uses a namespace selector.
  final Map<String, Json>? nsLabels;
  const RouteLookups({this.gateways = const {}, this.backends = const {}, this.grants = const [], this.nsLabels});

  Set<String> get missingBackends => {for (final e in backends.entries) if (e.value == false) e.key};
}

Future<RouteLookups> loadRouteLookups(PanelContext ctx, RouteObj route) async {
  final api = ctx.api;
  final gwRefs = {for (final p in route.parentRefs) if (p.isGateway) p.qualified: p};
  final allRefs = [...route.backendRefs, for (final r in route.rules) ...mirrorRefs(r, route.namespace)];
  final crossNs = {for (final b in allRefs) if (b.namespace != route.namespace) b.namespace};
  final gwFuture = Future.wait(gwRefs.values.map((p) => fetchOrNull(api, const ResourceRef(group: gwGroup, resource: 'gateways'), namespace: p.namespace, name: p.name)));
  final grantsFuture = ctx.app.typeForResource(gwGroup, 'referencegrants') == null
      ? Future.value(<List<Json>>[])
      : Future.wait(crossNs.map((ns) => api.items(const ResourceRef(group: gwGroup, resource: 'referencegrants'), namespace: ns)));
  final results = await Future.wait<Object>([gwFuture, existence(api, allRefs), grantsFuture]);
  final gws = results[0] as List<Json?>;
  final gateways = {for (var i = 0; i < gwRefs.length; i++) gwRefs.keys.elementAt(i): gws[i]};
  Map<String, Json>? nsLabels;
  final usesSelector = gateways.values.any((g) => asMapList(dig(g, ['spec', 'listeners'])).any((l) => dig(l, ['allowedRoutes', 'namespaces', 'from']) == 'Selector'));
  if (usesSelector) {
    try {
      final nss = await api.items(const ResourceRef(resource: 'namespaces'));
      nsLabels = {for (final n in nss) '${dig(n, ['metadata', 'name'])}': asMap(dig(n, ['metadata', 'labels']))};
    } catch (_) {
      nsLabels = null;
    }
  }
  return RouteLookups(
    gateways: gateways,
    backends: results[1] as Map<String, bool?>,
    grants: [for (final l in results[2] as List<List<Json>>) ...l],
    nsLabels: nsLabels,
  );
}

/// HTTPRoute, GRPCRoute, TLSRoute, TCPRoute and UDPRoute.
class RoutePanel extends ResourcePanel {
  const RoutePanel();

  @override
  Set<String> get kinds => {for (final k in routeKinds) k.gk};

  @override
  bool get ownerInHeader => true;

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) => [_RouteView(key: ValueKey('${ctx.uid}/route'), ctx: ctx)];
}

class _RouteView extends StatelessWidget {
  final PanelContext ctx;
  const _RouteView({super.key, required this.ctx});

  RouteObj get route => RouteObj(routeKindOf('${ctx.object['kind']}') ?? routeKinds.first, ctx.object);

  @override
  Widget build(BuildContext context) {
    final r = route;
    return NetFetch<RouteLookups>(
      fetchKey: fingerprint([ctx.spec['parentRefs'], ctx.spec['rules']]),
      load: () => loadRouteLookups(ctx, r),
      builder: (context, snap, reload) {
        final data = snap.data;
        final health = RouteHealth.of(r);
        final diags = _diags(r, data);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(context, r, data, health, diags, snap.error),
          InspectorSection(
            id: 'route-parents',
            title: 'Parents',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: SectionSummary(
                  '${health.accepted} of ${health.parents} accepted',
                  color: health.accepted == health.parents && health.parents > 0 ? null : severityColor(context, Severity.error),
                ),
              ),
              const SizedBox(width: 4),
              SizedBox(height: 20, child: RefreshButton(reload)),
            ]),
            child: _parents(context, r, data, diags),
          ),
          InspectorSection(
            id: 'route-rules',
            title: 'Rules',
            trailing: SectionSummary(plural(r.rules.length, 'rule')),
            child: _rules(context, r, data),
          ),
        ]);
      },
    );
  }

  /// Diagnoses per parentRef (by its qualified name and section).
  Map<ParentRef, List<Diag>> _diags(RouteObj r, RouteLookups? data) => {
        for (final p in r.parentRefs)
          p: () {
            final gw = data?.gateways[p.qualified];
            final gwKnown = data != null && data.gateways.containsKey(p.qualified);
            return explainRouteParent(
              r,
              p,
              gateway: gw,
              gatewayMissing: p.isGateway && gwKnown && gw == null,
              grants: data?.grants,
              missingBackends: data?.missingBackends ?? const {},
              nsLabels: data?.nsLabels,
            );
          }(),
      };

  Widget _header(BuildContext context, RouteObj r, RouteLookups? data, RouteHealth health, Map<ParentRef, List<Diag>> diags, Object? error) {
    final hosts = r.hostnames;
    final backends = {for (final b in r.backendRefs) b.key: b}.values.toList();
    final missing = data?.missingBackends ?? const <String>{};
    final many = r.parentRefs.length > 1;
    final insights = <Insight>[
      if (r.parentRefs.isEmpty) const Insight(Severity.error, 'No parentRefs', 'The route is not attached to any Gateway, so it serves no traffic.'),
      for (final e in diags.entries)
        for (final d in e.value) Insight(diagSeverity(d.level), many ? '${e.key.qualified}: ${d.title}' : d.title, d.detail),
      if (error != null) Insight(Severity.warn, 'Lookup failed', '$error'),
    ];
    final sev = health.healthy ? Severity.ok : diagSeverity(health.level);
    return InspectorHeader(
      mark: worstOf(insights) ?? (sev == Severity.info ? Severity.neutral : sev),
      headline: health.label,
      detail: [r.kind.kind, if (r.kind.hasHostnames) hosts.isEmpty ? 'any hostname' : hosts.join(', ')].join(' · '),
      figures: [
        InspectorFigure('${health.accepted}', 'accepted',
            of: '/${health.parents}', severity: health.accepted == health.parents && health.parents > 0 ? Severity.neutral : Severity.error, tooltip: '${health.accepted} of ${health.parents} parents accepted'),
        InspectorFigure('${r.rules.length}', r.rules.length == 1 ? 'rule' : 'rules'),
        InspectorFigure('${backends.length}', backends.length == 1 ? 'backend' : 'backends'),
        if (missing.isNotEmpty) InspectorFigure('${missing.length}', 'not found', severity: Severity.error),
      ],
      insights: insights,
      factsKeyWidth: 80, facts: [
        ?ownerFact(ctx.object),
        if (r.kind.hasHostnames)
          (
            'Hostnames',
            hosts.isEmpty ? const Muted('any (inherits the listener hostname)') : InlineWrap([for (final h in hosts) Chipish(text: h, copyValue: h)]),
          ),
        (
          'Backends',
          backends.isEmpty ? null : Wrap(spacing: 10, runSpacing: 2, children: [for (final b in backends.take(8)) BackendLine(b, fromNamespace: r.namespace)]),
        ),
      ],
    );
  }

  Widget _parents(BuildContext context, RouteObj r, RouteLookups? data, Map<ParentRef, List<Diag>> diags) {
    final refs = r.parentRefs;
    if (refs.isEmpty) return const InlineMessage('No parentRefs: the route is not attached to any Gateway, so it serves no traffic.', isError: true);
    final theme = Theme.of(context);
    final rows = [
      for (final p in refs)
        () {
          final status = r.statusFor(p);
          final conds = status?['conditions'];
          final accepted = condTrue(condOf(conds, 'Accepted'));
          final unresolved = condFalse(condOf(conds, 'ResolvedRefs'));
          final ds = diags[p] ?? const [];
          final sev = !accepted ? Severity.error : (unresolved || ds.isNotEmpty ? Severity.warn : Severity.ok);
          final label = status == null ? 'No status' : (!accepted ? 'Not accepted' : (unresolved ? 'Unresolved refs' : 'Accepted'));
          final bad = sev != Severity.ok;
          return (
            bad,
            InspectorRow(
              key: ValueKey('route-parent-${p.qualified}/${p.sectionText}'),
              memoryId: 'route-parent:${ctx.uid}/${p.qualified}/${p.sectionText}',
              dot: sev,
              dotTooltip: label,
              title: p.isGateway
                  ? gwLink('Gateway', p.name, namespace: p.namespace)
                  : ResourceLink(ObjectRef(group: p.group, kind: p.kind, name: p.name, namespace: p.namespace), label: '${p.kind} ${p.qualified}'),
              subtitle: dotLine([p.sectionText, if (status?['controllerName'] != null) 'controller ${status!['controllerName']}']),
              trailing: [if (bad) Text(label, style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, sev), fontWeight: FontWeight.w600))],
              details: (_) => status == null
                  ? const Muted('The controller has not reported on this parent yet.')
                  : Wrap(spacing: 8, runSpacing: 4, children: [
                      CondBadge(condOf(conds, 'Accepted'), label: 'Accepted', negative: 'Not accepted'),
                      CondBadge(condOf(conds, 'ResolvedRefs'), label: 'Refs resolved', negative: 'Unresolved refs'),
                    ]),
            ),
          );
        }(),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final r in rows) if (r.$1) r.$2,
      for (final r in rows) if (!r.$1) r.$2,
    ]);
  }

  /// Address and listener used for the example command: the first accepted
  /// Gateway parent with an address.
  (String?, Json?) _target(RouteObj r, RouteLookups? data) {
    if (data == null) return (null, null);
    for (final p in r.parentRefs) {
      final gw = data.gateways[p.qualified];
      if (gw == null || !condTrue(condOf(r.statusFor(p)?['conditions'], 'Accepted'))) continue;
      final addr = asMapList(dig(gw, ['status', 'addresses'])).map((a) => '${a['value'] ?? ''}').where((a) => a.isNotEmpty).firstOrNull;
      if (addr == null) continue;
      final listeners = listenersFor(gw, p, r, nsLabels: data.nsLabels);
      // Prefer plain HTTP for a copy-paste example.
      final l = listeners.where((l) => l['protocol'] == 'HTTP').firstOrNull ?? listeners.firstOrNull;
      return (addr, l);
    }
    return (null, null);
  }

  Widget _rules(BuildContext context, RouteObj r, RouteLookups? data) {
    final rules = r.rules;
    if (rules.isEmpty) return const InlineMessage('No rules');
    final (address, listener) = _target(r, data);
    final grpc = r.kind.kind == 'GRPCRoute';
    final rows = [for (var i = 0; i < rules.length; i++) _rule(context, r, i, rules[i], data, grpc: grpc, address: address, listener: listener)];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final x in rows) if (x.$1) x.$2,
      for (final x in rows) if (!x.$1) x.$2,
    ]);
  }

  (bool, Widget) _rule(BuildContext context, RouteObj r, int i, Json rule, RouteLookups? data, {required bool grpc, String? address, Json? listener}) {
    final theme = Theme.of(context);
    final matches = asMapList(rule['matches']);
    final filters = asMapList(rule['filters']);
    final backends = [for (final b in asMapList(rule['backendRefs'])) BackendRef.fromJson(b, r.namespace)];
    final mirrors = mirrorRefs(rule, r.namespace);
    final timeouts = describeTimeouts(rule);
    final cmd = exampleCommand(r, rule, address: address, listener: listener);
    final isHttpish = r.kind.kind == 'HTTPRoute' || grpc;
    bool notPermitted(BackendRef b) =>
        data != null && b.namespace != r.namespace && !anyGrantPermits(data.grants, fromKind: r.kind.kind, fromNamespace: r.namespace, to: b);
    final broken = [...backends, ...mirrors].where((b) => data?.backends[b.key] == false || notPermitted(b)).toList();
    final redirect = filters.any((f) => f['type'] == 'RequestRedirect');
    final noBackends = backends.isEmpty && !redirect;
    final sev = broken.isNotEmpty || noBackends ? Severity.error : Severity.ok;
    final matchText = !isHttpish
        ? 'all traffic'
        : matches.isEmpty
            ? 'everything'
            : matches.map((m) => describeMatch(m, grpc: grpc).join(' · ').ifEmpty(grpc ? 'any method' : 'any path')).join('  or  ');
    final to = backends.isEmpty
        ? (redirect ? 'redirect' : 'no backends: requests get a 500')
        : backends.map((b) => '${b.label(r.namespace)}${b.port != null ? ':${b.port}' : ''}${backends.length > 1 ? ' ${weightPercent(backends, b)}%' : ''}').join(', ');
    final title = rule['name'] != null ? '${rule['name']}' : 'Rule ${i + 1}';
    return (
      sev != Severity.ok,
      InspectorRow(
        key: ValueKey('route-rule-$i'),
        memoryId: 'route-rule:${ctx.uid}/$i',
        dot: sev,
        initiallyExpanded: sev != Severity.ok,
        title: Text.rich(TextSpan(children: [
          TextSpan(text: '$title  ', style: const TextStyle(fontWeight: FontWeight.w600)),
          TextSpan(text: matchText, style: monoStyle(context, size: 11.5, color: theme.hintColor)),
        ])),
        subtitle: Text(
          '→ $to${filters.isEmpty ? '' : ' · ${plural(filters.length, 'filter')}'}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: sev == Severity.error ? TextStyle(color: severityColor(context, Severity.error)) : null,
        ),
        details: (_) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: [
          if (isHttpish)
            QuietGroup('Match', [
              if (matches.isEmpty) const Muted('everything'),
              for (var j = 0; j < matches.length; j++)
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  if (j > 0) const Padding(padding: EdgeInsets.only(right: 6), child: Muted('or')),
                  Expanded(child: Mono(describeMatch(matches[j], grpc: grpc).join('  ·  ').ifEmpty(grpc ? 'any method' : 'any path'))),
                ]),
            ]),
          if (filters.isNotEmpty) QuietGroup('Filters', [for (final f in filters) Text(describeFilter(f, routeNamespace: r.namespace))]),
          QuietGroup('Backends', [
            if (backends.isEmpty) redirect ? const Muted('none (redirect)') : const Muted('none: requests get a 500'),
            for (final b in backends)
              BackendLine(b, fromNamespace: r.namespace, percent: weightPercent(backends, b), exists: data?.backends[b.key], notPermitted: notPermitted(b)),
          ]),
          if (mirrors.isNotEmpty)
            QuietGroup('Mirror', [
              for (final b in mirrors) BackendLine(b, fromNamespace: r.namespace, exists: data?.backends[b.key], notPermitted: notPermitted(b)),
            ]),
          if (timeouts != null) QuietGroup('Timeouts', [Text(timeouts)]),
          if (cmd != null) QuietGroup('Try', [CopyLine(cmd)]),
        ]),
      ),
    );
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
