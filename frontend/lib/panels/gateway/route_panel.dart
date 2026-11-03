import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
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
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DetailSection(
            title: r.kind.kind,
            icon: Icons.alt_route,
            trailing: StatusBadge(health.label, dense: true, severity: health.healthy ? Severity.ok : diagSeverity(health.level)),
            child: _summary(context, r),
          ),
          DetailSection(
            title: 'Parents',
            icon: Icons.account_tree_outlined,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              StatusBadge('${health.accepted}/${health.parents} accepted', dense: true, severity: health.accepted == health.parents && health.parents > 0 ? Severity.ok : Severity.error),
              const SizedBox(width: 4),
              RefreshButton(reload),
            ]),
            child: _parents(context, r, data, snap.error),
          ),
          DetailSection(
            title: 'Rules',
            icon: Icons.rule,
            trailing: Text('${r.rules.length}'),
            child: _rules(context, r, data),
          ),
        ]);
      },
    );
  }

  Widget _summary(BuildContext context, RouteObj r) {
    final hosts = r.hostnames;
    final backends = {for (final b in r.backendRefs) b.key: b}.values.toList();
    return KeyValueTable([
      if (r.kind.hasHostnames)
        (
          'Hostnames',
          hosts.isEmpty
              ? const Muted('any (inherits the listener hostname)')
              : Wrap(spacing: 4, runSpacing: 4, children: [for (final h in hosts) Chipish(text: h, copyValue: h)]),
        ),
      ('Parents', r.parentRefs.isEmpty ? const Muted('none: this route is not attached to anything') : '${r.parentRefs.length}'),
      (
        'Backends',
        backends.isEmpty
            ? null
            : Wrap(spacing: 10, runSpacing: 2, children: [for (final b in backends.take(8)) BackendLine(b, fromNamespace: r.namespace)]),
      ),
    ], keyWidth: 90);
  }

  Widget _parents(BuildContext context, RouteObj r, RouteLookups? data, Object? error) {
    final refs = r.parentRefs;
    if (refs.isEmpty) return const InlineMessage('No parentRefs: the route is not attached to any Gateway, so it serves no traffic.', isError: true);
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (error != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: InlineMessage('Lookup failed: $error', isError: true)),
      HairlineList([
        for (final p in refs)
          () {
            final status = r.statusFor(p);
            final conds = status?['conditions'];
            final gw = data?.gateways[p.qualified];
            final gwKnown = data != null && data.gateways.containsKey(p.qualified);
            final diags = explainRouteParent(
              r,
              p,
              gateway: gw,
              gatewayMissing: p.isGateway && gwKnown && gw == null,
              grants: data?.grants,
              missingBackends: data?.missingBackends ?? const {},
              nsLabels: data?.nsLabels,
            );
            return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.router_outlined, size: 13, color: theme.hintColor),
                  const SizedBox(width: 5),
                  Flexible(
                    child: p.isGateway
                        ? gwLink('Gateway', p.name, namespace: p.namespace)
                        : ResourceLink(ObjectRef(group: p.group, kind: p.kind, name: p.name, namespace: p.namespace), label: '${p.kind} ${p.qualified}'),
                  ),
                ]),
                if (p.sectionText.isNotEmpty) Muted(p.sectionText),
                if (status != null) ...[
                  CondBadge(condOf(conds, 'Accepted'), label: 'Accepted', negative: 'Not accepted'),
                  CondBadge(condOf(conds, 'ResolvedRefs'), label: 'Refs resolved', negative: 'Unresolved refs'),
                ],
              ]),
              if (diags.isNotEmpty) ...[
                const SizedBox(height: 6),
                for (final d in diags) DiagCallout(d),
              ],
              if (status?['controllerName'] != null)
                Padding(padding: const EdgeInsets.only(top: 2), child: Muted('controller ${status!['controllerName']}')),
            ]);
          }(),
      ]),
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
    return HairlineList(padding: const EdgeInsets.symmetric(vertical: 8), [
      for (var i = 0; i < rules.length; i++) _rule(context, r, i, rules[i], data, grpc: grpc, address: address, listener: listener),
    ]);
  }

  Widget _rule(BuildContext context, RouteObj r, int i, Json rule, RouteLookups? data, {required bool grpc, String? address, Json? listener}) {
    final matches = asMapList(rule['matches']);
    final filters = asMapList(rule['filters']);
    final backends = [for (final b in asMapList(rule['backendRefs'])) BackendRef.fromJson(b, r.namespace)];
    final mirrors = mirrorRefs(rule, r.namespace);
    final timeouts = describeTimeouts(rule);
    final cmd = exampleCommand(r, rule, address: address, listener: listener);
    final isHttpish = r.kind.kind == 'HTTPRoute' || grpc;
    bool notPermitted(BackendRef b) =>
        data != null && b.namespace != r.namespace && !anyGrantPermits(data.grants, fromKind: r.kind.kind, fromNamespace: r.namespace, to: b);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SubHeader('RULE ${i + 1}${rule['name'] != null ? ' · ${rule['name']}' : ''}'),
      KeyValueTable([
        if (isHttpish)
          (
            'Match',
            matches.isEmpty
                ? const Muted('everything')
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    for (var j = 0; j < matches.length; j++)
                      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        if (j > 0) const Padding(padding: EdgeInsets.only(right: 6), child: Muted('or')),
                        Expanded(child: Mono(describeMatch(matches[j], grpc: grpc).join('  ·  ').ifEmpty(grpc ? 'any method' : 'any path'))),
                      ]),
                  ]),
          ),
        (
          'Filters',
          filters.isEmpty
              ? null
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final f in filters) Text(describeFilter(f, routeNamespace: r.namespace)),
                ]),
        ),
        (
          'Backends',
          backends.isEmpty
              ? (filters.any((f) => f['type'] == 'RequestRedirect') ? const Muted('none (redirect)') : const Muted('none: requests get a 500'))
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final b in backends)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 2),
                      child: BackendLine(b,
                          fromNamespace: r.namespace,
                          percent: weightPercent(backends, b),
                          exists: data?.backends[b.key],
                          notPermitted: notPermitted(b)),
                    ),
                ]),
        ),
        (
          'Mirror',
          mirrors.isEmpty
              ? null
              : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  for (final b in mirrors) BackendLine(b, fromNamespace: r.namespace, exists: data?.backends[b.key], notPermitted: notPermitted(b)),
                ]),
        ),
        ('Timeouts', timeouts),
      ], keyWidth: 72),
      if (cmd != null) ...[
        const SizedBox(height: 4),
        CopyLine(cmd, label: 'Try'),
      ],
    ]);
  }
}

extension on String {
  String ifEmpty(String other) => isEmpty ? other : this;
}
