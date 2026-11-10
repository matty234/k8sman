import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../panel.dart';
import '../../ui/inspector/inspector.dart';
import 'widgets.dart';
import '../../ui/widgets/atoms.dart';

/// The status header of an endpoint list: "N of M ready" with ready /
/// not-ready / terminating figures and an insight when none are ready.
InspectorHeader endpointsHeader(List<EndpointAddr> addrs, {required String what, List<(String, Object?)> facts = const [], Widget? footer, List<Insight> extra = const []}) {
  final ready = addrs.where((a) => a.ready).length;
  final notReady = addrs.length - ready;
  final terminating = addrs.where((a) => a.terminating).length;
  final insights = <Insight>[
    if (addrs.isEmpty) Insight(Severity.error, 'No endpoints', 'Traffic to this $what goes nowhere.'),
    if (addrs.isNotEmpty && ready == 0) Insight(Severity.error, 'None of the ${addrs.length} endpoints are ready', 'Endpoints become ready once their pods pass their readiness probes.'),
    if (ready > 0 && notReady > 0) Insight(Severity.warn, '$notReady of ${addrs.length} endpoints not ready', 'Traffic only goes to the $ready ready endpoint${ready == 1 ? '' : 's'}.'),
    ...extra,
  ];
  return InspectorHeader(
    mark: worstOf(insights) ?? Severity.ok,
    headline: addrs.isEmpty ? 'No endpoints' : (ready == addrs.length ? 'All ready' : '$ready of ${addrs.length} ready'),
    detail: addrs.isEmpty ? null : plural(addrs.length, 'address'),
    figures: [
      InspectorFigure('$ready', 'ready', of: '/${addrs.length}', severity: addrs.isEmpty || ready == 0 ? Severity.error : (ready < addrs.length ? Severity.warn : Severity.neutral)),
      InspectorFigure('$notReady', 'not ready', severity: notReady > 0 ? Severity.error : Severity.neutral),
      if (terminating > 0) InspectorFigure('$terminating', 'terminating', severity: Severity.warn),
    ],
    insights: insights,
    factsKeyWidth: 80,
    facts: facts,
    footer: footer,
  );
}

class EndpointSlicePanel extends ResourcePanel {
  const EndpointSlicePanel();

  @override
  Set<String> get kinds => {'discovery.k8s.io/EndpointSlice'};

  @override
  bool get ownerInHeader => true;

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final o = ctx.object;
    final labels = asMap(ctx.metadata['labels']);
    final svcName = labels['kubernetes.io/service-name'] as String?;
    final managedBy = labels['endpointslice.kubernetes.io/managed-by'] as String?;
    final addrs = EndpointAddr.fromSlices([o]);
    final ready = addrs.where((a) => a.ready).length;
    return [
      CoreSection('status', endpointsHeader(
        addrs,
        what: 'slice',
        facts: [
          ?ownerFact(ctx.object),
          (
            'Service',
            svcName != null
                ? ResourceLink(ObjectRef(kind: 'Service', name: svcName, namespace: ctx.namespace), label: svcName)
                : const HintText('none (no kubernetes.io/service-name label)'),
          ),
          ('Type', '${o['addressType'] ?? '?'}'),
          ('Managed by', managedBy),
          ('Ports', PortChips(asMapList(o['ports']))),
        ],
      )),
      CoreSection('endpoints', InspectorSection(
        id: 'slice-endpoints',
        title: 'Endpoints',
        trailing: SectionSummary(addrs.isEmpty ? 'none' : '$ready of ${addrs.length} ready'),
        child: EndpointList(addrs, namespace: ctx.namespace),
      )),
    ];
  }
}

class EndpointsPanel extends ResourcePanel {
  const EndpointsPanel();

  @override
  Set<String> get kinds => {'/Endpoints'};

  @override
  bool get ownerInHeader => true;

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final subsets = asMapList(ctx.object['subsets']);
    List<EndpointAddr> addrsOf(Json s) => [
          for (final a in asMapList(s['addresses'])) EndpointAddr.fromLegacy(a, ready: true),
          for (final a in asMapList(s['notReadyAddresses'])) EndpointAddr.fromLegacy(a, ready: false),
        ];
    final all = [for (final s in subsets) ...addrsOf(s)];
    return [
      CoreSection('status', endpointsHeader(
        all,
        what: 'service',
        extra: [if (subsets.isEmpty) const Insight(Severity.error, 'No subsets', 'This service has no endpoints.')],
        facts: [
          ?ownerFact(ctx.object),
          ('Service', ResourceLink(ObjectRef(kind: 'Service', name: ctx.name, namespace: ctx.namespace), label: ctx.name)),
          ('Subsets', '${subsets.length}'),
        ],
        footer: const HintText('Legacy core/v1 Endpoints (mirrors EndpointSlices; capped at 1000 addresses).'),
      )),
      for (var i = 0; i < subsets.length; i++)
        CoreSection('subset-$i', InspectorSection(
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
                const SizedBox(width: 48, child: HintText('Ports')),
                Expanded(child: PortChips(asMapList(subsets[i]['ports']))),
              ]),
            ),
            EndpointList(addrsOf(subsets[i]), namespace: ctx.namespace),
          ]),
        )),
    ];
  }
}
