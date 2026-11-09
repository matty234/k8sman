import 'package:flutter/material.dart';

import '../../ui/theme.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../../ui/inspector/inspector.dart';
import '../panel.dart';
import 'gw_model.dart';
import 'gw_widgets.dart';

/// How one route sends traffic to a Service.
class ServiceRouteUse {
  final RouteObj route;

  /// Weight share in its rule (null when it is the only backend).
  final int? percent;
  final bool mirror;
  const ServiceRouteUse(this.route, {this.percent, this.mirror = false});
}

/// Routes whose backendRefs (or mirror filters) target Service [namespace]/[name].
List<ServiceRouteUse> routesTargeting(List<RouteObj> routes, String namespace, String name) {
  final out = <ServiceRouteUse>[];
  for (final r in routes) {
    ServiceRouteUse? use;
    for (final rule in r.rules) {
      final refs = [for (final b in asMapList(rule['backendRefs'])) BackendRef.fromJson(b, r.namespace)];
      for (final b in refs) {
        if (b.isService && b.namespace == namespace && b.name == name) use ??= ServiceRouteUse(r, percent: weightPercent(refs, b));
      }
      for (final m in mirrorRefs(rule, r.namespace)) {
        if (m.isService && m.namespace == namespace && m.name == name) use ??= ServiceRouteUse(r, mirror: true);
      }
    }
    if (use != null) out.add(use);
  }
  return out;
}

/// "Routed by" for the Service panel: Gateway API routes sending traffic to
/// this Service. Renders nothing when the Gateway API isn't served or no
/// route targets the Service.
class RoutedBySection extends StatelessWidget {
  final PanelContext ctx;
  const RoutedBySection({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) {
    if (servedRouteKinds(ctx.app).isEmpty) return const SizedBox.shrink();
    return NetFetch<List<ServiceRouteUse>>(
      fetchKey: '${ctx.namespace}/${ctx.name}',
      load: () async => routesTargeting(await fetchRoutes(ctx.api, ctx.app), ctx.namespace ?? '', ctx.name),
      builder: (context, snap, reload) {
        final uses = snap.data ?? const <ServiceRouteUse>[];
        if (snap.hasError || uses.isEmpty) return const SizedBox.shrink();
        return InspectorSection(
          id: 'svc-routed-by',
          title: 'Routed by',
          trailing: SectionSummary(plural(uses.length, 'route')),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final u in [...uses]..sort((a, b) => (RouteHealth.of(a.route).healthy ? 1 : 0).compareTo(RouteHealth.of(b.route).healthy ? 1 : 0)))
              () {
                final h = RouteHealth.of(u.route);
                final sev = h.healthy ? Severity.ok : diagSeverity(h.level);
                return InspectorRow(
                  dot: sev,
                  dotTooltip: h.label,
                  title: routeLink(u.route, showKind: true),
                  subtitle: dotLine([
                    if (u.route.hostnames.isNotEmpty) u.route.hostnames.join(', '),
                    if (u.percent != null) '${u.percent}% of its rule',
                    if (u.mirror) 'mirror',
                  ]),
                  trailing: [
                    if (!h.healthy)
                      Text(h.label, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: severityColor(context, sev), fontWeight: FontWeight.w600)),
                  ],
                );
              }(),
          ]),
        );
      },
    );
  }
}
