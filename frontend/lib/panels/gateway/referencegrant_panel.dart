import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'gw_model.dart';
import 'gw_widgets.dart';

/// A reference into the grant's namespace from a route or Gateway.
class GrantUse {
  final String kind;
  final String namespace;
  final String name;
  final BackendRef to;
  final bool permitted;
  const GrantUse(this.kind, this.namespace, this.name, this.to, {required this.permitted});
}

/// Cross-namespace references from objects in the grant's `from` namespaces
/// into its namespace. [permitted] says whether this grant allows each one.
List<GrantUse> grantUses(Json grant, List<RouteObj> routes, List<Json> gateways) {
  final ns = dig<String>(grant, ['metadata', 'namespace']) ?? '';
  final fromNs = {for (final f in asMapList(dig(grant, ['spec', 'from']))) '${f['namespace']}'};
  final out = <GrantUse>[];
  for (final r in routes) {
    if (!fromNs.contains(r.namespace)) continue;
    final refs = {for (final b in [...r.backendRefs, for (final rule in r.rules) ...mirrorRefs(rule, r.namespace)]) if (b.namespace == ns) b.key: b};
    for (final b in refs.values) {
      out.add(GrantUse(r.kind.kind, r.namespace, r.name, b,
          permitted: grantPermits(grant, fromGroup: gwGroup, fromKind: r.kind.kind, fromNamespace: r.namespace, to: b)));
    }
  }
  for (final g in gateways) {
    final gNs = dig<String>(g, ['metadata', 'namespace']) ?? '';
    if (!fromNs.contains(gNs)) continue;
    for (final l in asMapList(dig(g, ['spec', 'listeners']))) {
      for (final c in asMapList(dig(l, ['tls', 'certificateRefs']))) {
        if (c['namespace'] != ns) continue;
        final b = BackendRef(group: '${c['group'] ?? ''}', kind: '${c['kind'] ?? 'Secret'}', namespace: ns, name: '${c['name']}');
        out.add(GrantUse('Gateway', gNs, '${dig(g, ['metadata', 'name'])}', b,
            permitted: grantPermits(grant, fromGroup: gwGroup, fromKind: 'Gateway', fromNamespace: gNs, to: b)));
      }
    }
  }
  return out;
}

class ReferenceGrantPanel extends ResourcePanel {
  const ReferenceGrantPanel();

  @override
  Set<String> get kinds => {'$gwGroup/ReferenceGrant'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final sentences = describeGrant(ctx.object);
    final from = asMapList(ctx.spec['from']);
    final to = asMapList(ctx.spec['to']);
    return [
      DetailSection(
        title: 'Reference grant',
        icon: Icons.verified_user_outlined,
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final s in sentences) Padding(padding: const EdgeInsets.only(bottom: 4), child: SelectableText(s, style: Theme.of(context).textTheme.bodySmall)),
          const SizedBox(height: 4),
          NetTable(
            headers: const ['From kind', 'Namespace'],
            flex: const [1, 1],
            rows: [for (final f in from) [Mono('${f['kind']}'), Mono('${f['namespace']}')]],
          ),
          const SizedBox(height: 8),
          NetTable(
            headers: const ['To kind', 'Name'],
            flex: const [1, 1],
            rows: [
              for (final t in to)
                [
                  Mono('${(t['group'] ?? '').toString().isEmpty ? '' : '${t['group']}/'}${t['kind']}'),
                  (t['name'] ?? '').toString().isEmpty
                      ? const Muted('any')
                      : (t['kind'] == 'Service' || t['kind'] == 'Secret') && (t['group'] ?? '').toString().isEmpty
                          ? ResourceLink(ObjectRef(kind: '${t['kind']}', name: '${t['name']}', namespace: ctx.namespace), label: '${t['name']}')
                          : Mono('${t['name']}'),
                ],
            ],
          ),
        ]),
      ),
      _GrantUsers(key: ValueKey('${ctx.uid}/users'), ctx: ctx),
    ];
  }
}

class _GrantUsers extends StatelessWidget {
  final PanelContext ctx;
  const _GrantUsers({super.key, required this.ctx});

  Future<List<GrantUse>> _load() async {
    final fromNs = {for (final f in asMapList(ctx.spec['from'])) '${f['namespace']}'};
    final routes = [for (final ns in fromNs) ...await fetchRoutes(ctx.api, ctx.app, namespace: ns)];
    final wantsGateways = asMapList(ctx.spec['from']).any((f) => f['kind'] == 'Gateway');
    final gateways = !wantsGateways
        ? const <Json>[]
        : [for (final ns in fromNs) ...await ctx.api.items(const ResourceRef(group: gwGroup, resource: 'gateways'), namespace: ns)];
    return grantUses(ctx.object, routes, gateways);
  }

  @override
  Widget build(BuildContext context) {
    return NetFetch<List<GrantUse>>(
      fetchKey: fingerprint(ctx.spec),
      load: _load,
      builder: (context, snap, reload) {
        final uses = snap.data ?? const <GrantUse>[];
        final relied = [for (final u in uses) if (u.permitted) u];
        final blocked = [for (final u in uses) if (!u.permitted) u];
        Widget row(GrantUse u) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                gwLink(u.kind, u.name, namespace: u.namespace, label: '${u.kind} ${u.namespace}/${u.name}'),
                const Muted('→'),
                BackendLine(u.to, fromNamespace: u.namespace),
              ]),
            );
        return DetailSection(
          title: 'Relied on by',
          icon: Icons.link,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (snap.hasData) Text('${relied.length}'),
            const SizedBox(width: 4),
            RefreshButton(reload),
          ]),
          child: snap.hasError
              ? InlineMessage('${snap.error}', isError: true)
              : !snap.hasData
                  ? spinner
                  : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      if (relied.isEmpty) const InlineMessage('Nothing currently uses this grant.') else for (final u in relied) row(u),
                      if (blocked.isNotEmpty) ...[
                        SubHeader('NOT COVERED BY THIS GRANT', trailing: StatusBadge('${blocked.length}', dense: true, severity: Severity.warn)),
                        const Padding(
                          padding: EdgeInsets.only(bottom: 2),
                          child: Muted('References from the same namespaces into this one that this grant does not allow.'),
                        ),
                        for (final u in blocked) row(u),
                      ],
                    ]),
        );
      },
    );
  }
}
