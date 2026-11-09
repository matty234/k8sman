import '../../ui/logs/open_logs.dart';
import '../../ui/portforward/quick_forward.dart';

import 'package:flutter/material.dart';

import '../../actions/actions.dart' show ResourceAction;
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../gateway/routed_by.dart';
import '../panel.dart';
import '../../util/text.dart';
import '../pod/pod_widgets.dart' show InlineWrap;
import 'inspector_kit.dart';
import 'widgets.dart';
import '../../util/pod.dart';

/// Backends of a Service: its EndpointSlices and the pods its selector matches.
class ServiceBackends {
  final List<Json> slices;

  /// Null when the service has no selector (pods were not fetched).
  final List<Json>? pods;
  const ServiceBackends({required this.slices, this.pods});
}

/// Result of resolving a Service port's targetPort.
class ResolvedTarget {
  final String text;
  final bool unresolved;
  final String? note;
  const ResolvedTarget(this.text, {this.unresolved = false, this.note});
}

/// Resolve `targetPort` (number or name) for [port]. Named ports are looked
/// up on the backing pods' containers, then on EndpointSlice ports (which
/// carry the resolved number under the Service port's name).
ResolvedTarget resolveTargetPort(Json port, {List<Json>? pods, List<Json> slices = const []}) {
  final tp = port['targetPort'] ?? port['port'];
  if (tp is num) return ResolvedTarget('$tp');
  final name = '$tp';
  final asInt = int.tryParse(name);
  if (asInt != null) return ResolvedTarget(name);
  for (final pod in pods ?? const <Json>[]) {
    for (final c in [
      ...asMapList(dig(pod, ['spec', 'containers'])),
      ...asMapList(dig(pod, ['spec', 'initContainers'])),
    ]) {
      for (final cp in asMapList(c['ports'])) {
        if (cp['name'] == name) return ResolvedTarget('$name → ${cp['containerPort']}', note: 'container ${c['name']}');
      }
    }
  }
  final svcPortName = port['name'];
  for (final s in slices) {
    for (final sp in asMapList(s['ports'])) {
      if (sp['name'] == svcPortName && sp['port'] != null) return ResolvedTarget('$name → ${sp['port']}', note: 'from EndpointSlice');
    }
  }
  final known = pods != null && pods.isNotEmpty;
  return ResolvedTarget(name, unresolved: known, note: known ? 'no container port named "$name" on matching pods' : null);
}

/// A derived explanation of the Service's backend health.
class ServiceDiagnosis {
  final Severity severity;
  final String title;
  final String? detail;
  const ServiceDiagnosis(this.severity, this.title, [this.detail]);
}

/// Explains why a Service has (or lacks) ready endpoints. Returns null
/// when everything is healthy.
ServiceDiagnosis? diagnoseService(Json svc, ServiceBackends b) {
  final spec = asMap(svc['spec']);
  if (spec['type'] == 'ExternalName') return null;
  final addrs = EndpointAddr.fromSlices(b.slices);
  final ready = addrs.where((a) => a.ready).length;
  final selector = asMap(spec['selector']);
  if (selector.isEmpty) {
    if (addrs.isEmpty) {
      return const ServiceDiagnosis(
        Severity.error,
        'Service has no selector (manual endpoints)',
        'No EndpointSlices labelled with this service name exist, so traffic goes nowhere. Create an EndpointSlice/Endpoints object, or add a selector.',
      );
    }
    if (ready == 0) {
      return const ServiceDiagnosis(Severity.error, 'Service has no selector (manual endpoints)', 'Manually managed endpoints exist but none are ready.');
    }
    return const ServiceDiagnosis(Severity.info, 'Service has no selector (manual endpoints)', 'Endpoints are managed outside the endpoint controller.');
  }
  final pods = b.pods ?? const <Json>[];
  final sel = selectorToString(selector);
  if (ready > 0) {
    final notReady = addrs.length - ready;
    if (notReady > 0) {
      return ServiceDiagnosis(
        Severity.warn,
        '$notReady of ${addrs.length} endpoints not ready',
        'Traffic only goes to the $ready ready endpoint${ready == 1 ? '' : 's'}.',
      );
    }
    return null;
  }
  if (pods.isEmpty) {
    return ServiceDiagnosis(
      Severity.error,
      'Selector matches 0 pods',
      'No pod in ${dig<String>(svc, ['metadata', 'namespace']) ?? 'this namespace'} has labels $sel. Check for a typo in the selector or pod template labels.',
    );
  }
  final readyPods = pods.where(podReady).length;
  if (readyPods == 0) {
    return ServiceDiagnosis(
      Severity.error,
      pods.length == 1 ? '1 pod matches but it is not ready' : '${pods.length} pods match but none are ready',
      'Endpoints are only added once a pod passes its readiness probe. Check the pods below.',
    );
  }
  return ServiceDiagnosis(
    Severity.warn,
    '$readyPods ready pod${readyPods == 1 ? '' : 's'} match but there are no ready endpoints',
    'The endpoint controller may be lagging, or the pods lack the target port.',
  );
}

class ServicePanel extends ResourcePanel {
  const ServicePanel();

  @override
  Set<String> get kinds => {'/Service'};

  /// Merged logs of the pods the selector picks (none for selector-less services).
  @override
  List<ResourceAction> actions(PanelContext ctx) => asMap(ctx.spec['selector']).isEmpty ? const [] : [workloadLogsAction(ctx)];

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) => [
        _ServiceView(key: ValueKey('${ctx.uid}/backends'), ctx: ctx),
        RoutedBySection(key: ValueKey('${ctx.uid}/routed-by'), ctx: ctx),
      ];
}

/// The external addresses of a Service: load balancer ingress, external
/// IPs and (ExternalName) the CNAME target.
List<String> serviceExternalAddresses(Json spec, Json status) => [
      for (final i in asMapList(dig(status, ['loadBalancer', 'ingress']))) '${i['ip'] ?? i['hostname'] ?? ''}',
      for (final ip in (spec['externalIPs'] as List? ?? const [])) '$ip',
    ];

class _ServiceView extends StatelessWidget {
  final PanelContext ctx;
  const _ServiceView({super.key, required this.ctx});

  Json get spec => ctx.spec;
  String get type => '${spec['type'] ?? 'ClusterIP'}';
  bool get headless => spec['clusterIP'] == 'None';
  bool get external => type == 'ExternalName';
  String get ns => ctx.namespace ?? 'default';
  String get dns => '${ctx.name}.$ns.svc.cluster.local';
  List<Json> get ports => asMapList(spec['ports']);
  Json get selector => asMap(spec['selector']);

  Future<ServiceBackends> _load() async {
    final ns = ctx.namespace;
    final results = await Future.wait([
      ctx.api.items(
        const ResourceRef(group: 'discovery.k8s.io', resource: 'endpointslices'),
        namespace: ns,
        labelSelector: 'kubernetes.io/service-name=${ctx.name}',
      ),
      if (selector.isNotEmpty)
        ctx.api.items(
          const ResourceRef(resource: 'pods'),
          namespace: ns,
          labelSelector: selectorToString(selector),
        ),
    ]);
    return ServiceBackends(slices: results[0], pods: selector.isEmpty ? null : results[1]);
  }

  @override
  Widget build(BuildContext context) {
    return NetFetch<ServiceBackends>(
      fetchKey: fingerprint([spec['selector'], spec['ports']]),
      load: _load,
      builder: (context, snap, reload) {
        final data = snap.data;
        final addrs = data == null ? const <EndpointAddr>[] : EndpointAddr.fromSlices(data.slices);
        final ready = addrs.where((a) => a.ready).length;
        final targets = [for (final p in ports) resolveTargetPort(p, pods: data?.pods, slices: data?.slices ?? const [])];
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(context, data, addrs, ready, targets, snap.error),
          PodSection(
            id: 'svc-ports',
            title: 'Ports',
            trailing: SectionSummary(ports.isEmpty ? 'none' : plural(ports.length, 'port')),
            child: ports.isEmpty ? const Padding(padding: EdgeInsets.only(left: 4), child: Muted('No ports')) : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final (i, p) in ports.indexed) _portRow(context, p, targets[i]),
            ]),
          ),
          if (!external)
            PodSection(
              id: 'svc-endpoints',
              title: 'Endpoints',
              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                Flexible(
                  child: SectionSummary(
                    data == null ? '' : (addrs.isEmpty ? 'none' : '$ready of ${addrs.length} ready'),
                    color: data != null && ready < addrs.length ? severityColor(context, ready == 0 ? Severity.error : Severity.warn) : null,
                  ),
                ),
                const SizedBox(width: 4),
                SizedBox(height: 20, child: RefreshButton(reload)),
              ]),
              child: snap.hasError
                  ? InlineMessage('${snap.error}', isError: true)
                  : data == null
                      ? spinner
                      : _endpoints(context, data, addrs, ready),
            ),
          ..._collapsed(context, addrs),
        ]);
      },
    );
  }

  Widget _header(BuildContext context, ServiceBackends? data, List<EndpointAddr> addrs, int ready, List<ResolvedTarget> targets, Object? error) {
    final diag = data == null ? null : diagnoseService(ctx.object, data);
    final externalAddrs = serviceExternalAddresses(spec, ctx.status);
    final lbPending = type == 'LoadBalancer' && asMapList(dig(ctx.status, ['loadBalancer', 'ingress'])).isEmpty;
    final sel = selectorToString(selector);
    final unresolved = [for (final (i, t) in targets.indexed) if (t.unresolved) (ports[i], t)];
    final insights = <PodInsight>[
      if (diag != null && diag.severity != Severity.info)
        PodInsight(
          diag.severity,
          diag.title,
          [?diag.detail, if (sel.isNotEmpty && ready == 0) 'Selector: $sel'].join('\n'),
        ),
      for (final (p, t) in unresolved) PodInsight(Severity.warn, 'Port ${p['name'] ?? p['port']}: target port "${p['targetPort']}" not found', t.note),
      if (lbPending) const PodInsight(Severity.warn, 'Load balancer pending', 'No external address has been assigned yet. Is a load-balancer controller installed?'),
      if (error != null) PodInsight(Severity.warn, 'Could not load endpoints', '$error'),
    ];
    final worst = worstOf(insights);
    final mark = worst ?? (external || data != null ? Severity.ok : Severity.neutral);
    final noneReady = !external && data != null && ready == 0;
    final detail = [
      if (headless) 'headless',
      if (external && spec['externalName'] != null) 'CNAME ${spec['externalName']}',
      if (!external && data != null) addrs.isEmpty ? 'no endpoints' : '$ready ready endpoint${ready == 1 ? '' : 's'} of ${addrs.length}',
      if (diag?.severity == Severity.info) 'manual endpoints',
    ].join(' · ');
    final nodePorts = [for (final p in ports) if (p['nodePort'] != null) '${p['nodePort']}'];
    return InspectorHeader(
      mark: mark,
      headline: type,
      detail: detail,
      figures: [
        if (!external)
          HeaderFigure(
            data == null ? '–' : '$ready',
            'ready',
            key: const ValueKey('svc-ready-figure'),
            of: data == null ? null : '/${addrs.length}',
            severity: noneReady ? Severity.error : (data != null && ready < addrs.length ? Severity.warn : Severity.neutral),
            tooltip: data == null ? null : '$ready of ${addrs.length} endpoints ready',
          ),
        HeaderFigure('${ports.length}', ports.length == 1 ? 'port' : 'ports'),
        if (data?.pods != null) HeaderFigure('${data!.pods!.length}', data.pods!.length == 1 ? 'pod matches' : 'pods match'),
      ],
      insights: insights,
      facts: KeyValueTable(keyWidth: 72, [
        (
          'Cluster IP',
          external
              ? null
              : headless
                  ? const Muted('None (headless)')
                  : InlineWrap([for (final ip in [for (final ip in (spec['clusterIPs'] as List? ?? [?spec['clusterIP']])) '$ip']) Chipish(text: ip, copyValue: ip)]),
        ),
        (
          'External',
          externalAddrs.isEmpty
              ? (lbPending ? Text('pending', style: TextStyle(color: severityColor(context, Severity.warn))) : null)
              : InlineWrap([for (final a in externalAddrs) Chipish(text: a, copyValue: a)]),
        ),
        ('Node ports', nodePorts.isEmpty ? null : Text(nodePorts.map((p) => ':$p').join('  '), style: monoStyle(context, size: 11.5))),
        ('DNS', MonoCopy(dns)),
      ]),
    );
  }

  Widget _portRow(BuildContext context, Json p, ResolvedTarget t) {
    final theme = Theme.of(context);
    final warn = severityColor(context, Severity.warn);
    final mono = monoStyle(context, size: 12);
    // One-click forward needs pods behind a selector (not ExternalName / manual endpoints).
    final canForward = !ctx.app.readOnly && selector.isNotEmpty && !external;
    final name = p['name'] as String?;
    return CompactRow(
      key: ValueKey('svc-port-${p['port']}'),
      severity: t.unresolved ? Severity.warn : Severity.ok,
      title: Text.rich(
        TextSpan(style: mono, children: [
          if (name != null) TextSpan(text: '$name  ', style: mono.copyWith(fontWeight: FontWeight.w600)),
          TextSpan(text: '${p['port']}'),
          TextSpan(text: ' → ', style: mono.copyWith(color: theme.hintColor)),
          TextSpan(text: t.text, style: t.unresolved ? mono.copyWith(color: warn) : null),
        ]),
      ),
      subtitle: dotLine([
        '${p['protocol'] ?? 'TCP'}',
        if (p['nodePort'] != null) 'nodePort ${p['nodePort']}',
        if (p['appProtocol'] != null) '${p['appProtocol']}',
        ?t.note,
      ]),
      actions: [
        if (canForward)
          QuickForwardButton(
            api: ctx.api,
            app: ctx.app,
            namespace: ns,
            kind: 'service',
            name: ctx.name,
            port: '${p['port']}',
            protocol: p['protocol'] as String?,
          ),
      ],
    );
  }

  Widget _endpoints(BuildContext context, ServiceBackends data, List<EndpointAddr> addrs, int ready) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (addrs.isNotEmpty) EndpointList(addrs, namespace: ctx.namespace, headlessDnsSuffix: headless ? dns : null) else const Padding(padding: EdgeInsets.only(left: 4), child: Muted('No endpoints')),
      if (data.pods != null && ready == 0 && data.pods!.isNotEmpty) ...[
        const RowGroupLabel('Matching pods'),
        PodRows(data.pods!),
      ],
      if (data.slices.isNotEmpty)
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 8, 0, 0),
          child: Wrap(spacing: 8, runSpacing: 2, children: [
            const Muted('Slices'),
            for (final s in data.slices)
              ResourceLink(
                ObjectRef(group: 'discovery.k8s.io', kind: 'EndpointSlice', name: '${dig(s, ['metadata', 'name'])}', namespace: ctx.namespace),
                label: '${dig(s, ['metadata', 'name'])}',
              ),
          ]),
        ),
    ]);
  }

  List<Widget> _collapsed(BuildContext context, List<EndpointAddr> addrs) {
    final affinityTimeout = dig<num>(spec, ['sessionAffinityConfig', 'clientIP', 'timeoutSeconds']);
    final isExternal = type == 'NodePort' || type == 'LoadBalancer';
    final families = [for (final f in (spec['ipFamilies'] as List? ?? const [])) '$f'];
    final ips = [for (final ip in (spec['clusterIPs'] as List? ?? [?spec['clusterIP']])) '$ip'];
    final affinity = '${spec['sessionAffinity'] ?? 'None'}';
    final topologyMode = dig<String>(ctx.metadata, ['annotations', 'service.kubernetes.io/topology-mode']) ??
        dig<String>(ctx.metadata, ['annotations', 'service.kubernetes.io/topology-aware-hints']);
    final distribution = spec['trafficDistribution'] as String?;
    final zones = {for (final a in addrs) ?a.zone}.toList()..sort();
    final hinted = addrs.where((a) => a.hints.isNotEmpty).length;
    final tcpPorts = [for (final p in ports.take(4)) if ((p['protocol'] ?? 'TCP') == 'TCP') p];
    return [
      PodSection(
        id: 'svc-access',
        title: 'Access',
        initiallyExpanded: false,
        trailing: SectionSummary(external ? 'CNAME' : (headless ? 'pod IPs via DNS' : 'kubectl port-forward')),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          if (external && spec['externalName'] != null) CopyLine('${spec['externalName']}', label: 'CNAME'),
          if (!external)
            for (final p in tcpPorts) CopyLine('kubectl -n $ns port-forward svc/${ctx.name} ${p['port']}:${p['port']}', label: 'Forward'),
          if (!external && ports.isNotEmpty && !headless)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Muted(
                'In-cluster: http://$dns:${ports.first['port']}'
                '${ports.any((p) => p['nodePort'] != null) ? '  ·  every node: ${ports.where((p) => p['nodePort'] != null).map((p) => ':${p['nodePort']}').join(' ')}' : ''}',
              ),
            ),
          if (headless)
            const Padding(
              padding: EdgeInsets.only(top: 2),
              child: Muted('Headless: DNS returns the ready pod IPs directly; no virtual IP or kube-proxy load-balancing.'),
            ),
        ]),
      ),
      PodSection(
        id: 'svc-selector',
        title: 'Selector',
        initiallyExpanded: false,
        trailing: SectionSummary(selector.isEmpty ? 'none' : selectorToString(selector)),
        child: selector.isEmpty ? const InlineMessage('No selector: endpoints are managed manually (or by another controller).') : LabelChips(selector),
      ),
      if (!external)
        PodSection(
          id: 'svc-traffic',
          title: 'Session affinity & traffic',
          initiallyExpanded: false,
          trailing: SectionSummary([
            'affinity $affinity',
            if (isExternal && spec['externalTrafficPolicy'] != null) 'external ${spec['externalTrafficPolicy']}',
            if (spec['internalTrafficPolicy'] != null) 'internal ${spec['internalTrafficPolicy']}',
          ].join(' · ')),
          child: KeyValueTable([
            ('Session affinity', '$affinity${affinityTimeout != null ? ' (${affinityTimeout}s)' : ''}'),
            ('External traffic', isExternal ? spec['externalTrafficPolicy'] as String? : null),
            ('Internal traffic', spec['internalTrafficPolicy'] as String?),
            ('Publish not-ready', spec['publishNotReadyAddresses'] == true ? 'true (not-ready pods are in DNS)' : null),
            ('LB class', spec['loadBalancerClass'] as String?),
            ('LB source ranges', (spec['loadBalancerSourceRanges'] as List?)?.join(', ')),
            ('External IPs', (spec['externalIPs'] as List?)?.join(', ')),
          ], keyWidth: 120),
        ),
      if (!external && (families.isNotEmpty || ips.isNotEmpty))
        PodSection(
          id: 'svc-families',
          title: 'IP families',
          initiallyExpanded: false,
          trailing: SectionSummary([...families, ?spec['ipFamilyPolicy'] as String?].join(' · ')),
          child: KeyValueTable([
            ('Families', families.isEmpty ? null : families.join(', ')),
            ('Policy', spec['ipFamilyPolicy'] as String?),
            ('Cluster IPs', headless ? 'None (headless)' : (ips.isEmpty ? null : InlineWrap([for (final ip in ips) Chipish(text: ip, copyValue: ip)]))),
          ], keyWidth: 120),
        ),
      if (topologyMode != null || distribution != null || zones.isNotEmpty)
        PodSection(
          id: 'svc-topology',
          title: 'Topology',
          initiallyExpanded: false,
          trailing: SectionSummary([
            ?distribution,
            if (topologyMode != null) 'mode $topologyMode',
            if (zones.isNotEmpty) plural(zones.length, 'zone'),
          ].join(' · ')),
          child: KeyValueTable([
            ('Traffic distribution', distribution),
            ('Topology mode', topologyMode),
            ('Zones', zones.isEmpty ? null : zones.join(', ')),
            ('Zone hints', addrs.isEmpty || (topologyMode == null && distribution == null) ? null : '$hinted of ${addrs.length} endpoints'),
          ], keyWidth: 120),
        ),
    ];
  }
}
