import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'widgets.dart';

class EndpointSlicePanel extends ResourcePanel {
  const EndpointSlicePanel();

  @override
  Set<String> get kinds => {'discovery.k8s.io/EndpointSlice'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final o = ctx.object;
    final labels = asMap(ctx.metadata['labels']);
    final svcName = labels['kubernetes.io/service-name'] as String?;
    final managedBy = labels['endpointslice.kubernetes.io/managed-by'] as String?;
    final addrs = EndpointAddr.fromSlices([o]);
    final ready = addrs.where((a) => a.ready).length;
    final terminating = addrs.where((a) => a.terminating).length;
    return [
      DetailSection(
        title: 'Endpoint slice',
        icon: Icons.hub_outlined,
        trailing: StatusBadge('${o['addressType'] ?? '?'}', dense: true, severity: Severity.info),
        child: KeyValueTable([
          (
            'Service',
            svcName != null
                ? ResourceLink(ObjectRef(kind: 'Service', name: svcName, namespace: ctx.namespace), label: svcName)
                : const Muted('none (no kubernetes.io/service-name label)'),
          ),
          ('Managed by', managedBy),
          ('Ports', PortChips(asMapList(o['ports']))),
          (
            'Endpoints',
            Wrap(spacing: 4, children: [
              CountBadge(ready: ready, total: addrs.length),
              if (terminating > 0) StatusBadge('$terminating terminating', dense: true, severity: Severity.warn),
            ]),
          ),
        ], keyWidth: 100),
      ),
      DetailSection(
        title: 'Endpoints',
        icon: Icons.dns_outlined,
        child: EndpointList(addrs, namespace: ctx.namespace),
      ),
    ];
  }
}

class EndpointsPanel extends ResourcePanel {
  const EndpointsPanel();

  @override
  Set<String> get kinds => {'/Endpoints'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final subsets = asMapList(ctx.object['subsets']);
    var ready = 0, total = 0;
    for (final s in subsets) {
      final r = asMapList(s['addresses']).length;
      ready += r;
      total += r + asMapList(s['notReadyAddresses']).length;
    }
    return [
      DetailSection(
        title: 'Endpoints',
        icon: Icons.hub_outlined,
        trailing: CountBadge(ready: ready, total: total),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KeyValueTable([
            ('Service', ResourceLink(ObjectRef(kind: 'Service', name: ctx.name, namespace: ctx.namespace), label: ctx.name)),
            ('Subsets', '${subsets.length}'),
          ], keyWidth: 100),
          const SizedBox(height: 4),
          const Muted('Legacy core/v1 Endpoints (mirrors EndpointSlices; capped at 1000 addresses).'),
        ]),
      ),
      if (subsets.isEmpty)
        const DetailSection(title: 'Subsets', icon: Icons.dns_outlined, child: InlineMessage('No subsets: this service has no endpoints', isError: true)),
      for (var i = 0; i < subsets.length; i++)
        DetailSection(
          title: subsets.length == 1 ? 'Subset' : 'Subset ${i + 1}',
          icon: Icons.dns_outlined,
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [const SizedBox(width: 60, child: Muted('Ports')), Expanded(child: PortChips(asMapList(subsets[i]['ports'])))]),
            const SizedBox(height: 6),
            EndpointList([
              for (final a in asMapList(subsets[i]['addresses'])) EndpointAddr.fromLegacy(a, ready: true),
              for (final a in asMapList(subsets[i]['notReadyAddresses'])) EndpointAddr.fromLegacy(a, ready: false),
            ], namespace: ctx.namespace),
          ]),
        ),
    ];
  }
}
