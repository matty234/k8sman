import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../panel.dart';
import 'inspector_kit.dart';
import 'widgets.dart';

/// The status header of an endpoint list: "N of M ready" with ready /
/// not-ready / terminating figures and an insight when none are ready.
InspectorHeader endpointsHeader(List<EndpointAddr> addrs, {required String what, Widget? facts, List<PodInsight> extra = const []}) {
  final ready = addrs.where((a) => a.ready).length;
  final notReady = addrs.length - ready;
  final terminating = addrs.where((a) => a.terminating).length;
  final insights = <PodInsight>[
    if (addrs.isEmpty) PodInsight(Severity.error, 'No endpoints', 'Traffic to this $what goes nowhere.'),
    if (addrs.isNotEmpty && ready == 0) PodInsight(Severity.error, 'None of the ${addrs.length} endpoints are ready', 'Endpoints become ready once their pods pass their readiness probes.'),
    if (ready > 0 && notReady > 0) PodInsight(Severity.warn, '$notReady of ${addrs.length} endpoints not ready', 'Traffic only goes to the $ready ready endpoint${ready == 1 ? '' : 's'}.'),
    ...extra,
  ];
  return InspectorHeader(
    mark: worstOf(insights) ?? Severity.ok,
    headline: addrs.isEmpty ? 'No endpoints' : (ready == addrs.length ? 'All ready' : '$ready of ${addrs.length} ready'),
    detail: addrs.isEmpty ? null : plural(addrs.length, 'address'),
    figures: [
      HeaderFigure('$ready', 'ready', of: '/${addrs.length}', severity: addrs.isEmpty || ready == 0 ? Severity.error : (ready < addrs.length ? Severity.warn : Severity.neutral)),
      HeaderFigure('$notReady', 'not ready', severity: notReady > 0 ? Severity.error : Severity.neutral),
      if (terminating > 0) HeaderFigure('$terminating', 'terminating', severity: Severity.warn),
    ],
    insights: insights,
    facts: facts,
  );
}

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
    return [
      endpointsHeader(
        addrs,
        what: 'slice',
        facts: KeyValueTable([
          (
            'Service',
            svcName != null
                ? ResourceLink(ObjectRef(kind: 'Service', name: svcName, namespace: ctx.namespace), label: svcName)
                : const Muted('none (no kubernetes.io/service-name label)'),
          ),
          ('Type', '${o['addressType'] ?? '?'}'),
          ('Managed by', managedBy),
          ('Ports', PortChips(asMapList(o['ports']))),
        ], keyWidth: 80),
      ),
      PodSection(
        id: 'slice-endpoints',
        title: 'Endpoints',
        trailing: SectionSummary(addrs.isEmpty ? 'none' : '$ready of ${addrs.length} ready'),
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
    List<EndpointAddr> addrsOf(Json s) => [
          for (final a in asMapList(s['addresses'])) EndpointAddr.fromLegacy(a, ready: true),
          for (final a in asMapList(s['notReadyAddresses'])) EndpointAddr.fromLegacy(a, ready: false),
        ];
    final all = [for (final s in subsets) ...addrsOf(s)];
    return [
      endpointsHeader(
        all,
        what: 'service',
        extra: [if (subsets.isEmpty) const PodInsight(Severity.error, 'No subsets', 'This service has no endpoints.')],
        facts: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KeyValueTable([
            ('Service', ResourceLink(ObjectRef(kind: 'Service', name: ctx.name, namespace: ctx.namespace), label: ctx.name)),
            ('Subsets', '${subsets.length}'),
          ], keyWidth: 80),
          const SizedBox(height: 4),
          const Muted('Legacy core/v1 Endpoints (mirrors EndpointSlices; capped at 1000 addresses).'),
        ]),
      ),
      for (var i = 0; i < subsets.length; i++)
        PodSection(
          id: 'endpoints-subset-$i',
          title: subsets.length == 1 ? 'Subset' : 'Subset ${i + 1}',
          trailing: SectionSummary(() {
            final a = addrsOf(subsets[i]);
            return '${a.where((x) => x.ready).length} of ${a.length} ready';
          }()),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 0, 0, 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const SizedBox(width: 48, child: Muted('Ports')),
                Expanded(child: PortChips(asMapList(subsets[i]['ports']))),
              ]),
            ),
            EndpointList(addrsOf(subsets[i]), namespace: ctx.namespace),
          ]),
        ),
    ];
  }
}
