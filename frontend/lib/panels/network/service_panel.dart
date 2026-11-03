import '../../ui/portforward/quick_forward.dart';

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../gateway/routed_by.dart';
import '../panel.dart';
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

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final type = '${spec['type'] ?? 'ClusterIP'}';
    final ns = ctx.namespace ?? 'default';
    final headless = spec['clusterIP'] == 'None';
    final dns = '${ctx.name}.$ns.svc.cluster.local';
    final ports = asMapList(spec['ports']);
    final selector = asMap(spec['selector']);
    return [
      DetailSection(
        title: 'Service',
        icon: Icons.lan_outlined,
        trailing: Wrap(
          spacing: 4,
          children: [
            StatusBadge(type, dense: true, severity: Severity.info),
            if (headless) const StatusBadge('Headless', dense: true, severity: Severity.neutral),
          ],
        ),
        child: _summary(context, ctx, type, headless),
      ),
      DetailSection(
        title: 'Access',
        icon: Icons.terminal,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            CopyLine(dns, label: 'DNS'),
            if (type == 'ExternalName' && spec['externalName'] != null) CopyLine('${spec['externalName']}', label: 'CNAME'),
            if (type != 'ExternalName')
              for (final p in ports.take(4))
                if ((p['protocol'] ?? 'TCP') == 'TCP') CopyLine('kubectl -n $ns port-forward svc/${ctx.name} ${p['port']}:${p['port']}', label: 'Forward'),
            if (type != 'ExternalName' && ports.isNotEmpty && !headless)
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
          ],
        ),
      ),
      DetailSection(
        title: 'Selector',
        icon: Icons.filter_alt_outlined,
        child: selector.isEmpty ? const InlineMessage('No selector: endpoints are managed manually (or by another controller).') : LabelChips(selector),
      ),
      _ServiceBackendsView(key: ValueKey('${ctx.uid}/backends'), ctx: ctx, ports: ports, headless: headless, dns: dns),
      RoutedBySection(key: ValueKey('${ctx.uid}/routed-by'), ctx: ctx),
    ];
  }

  Widget _summary(BuildContext context, PanelContext ctx, String type, bool headless) {
    final spec = ctx.spec;
    final ips = [
      for (final ip in (spec['clusterIPs'] as List? ?? [if (spec['clusterIP'] != null) spec['clusterIP']])) '$ip',
    ];
    final lbIngress = asMapList(dig(ctx.status, ['loadBalancer', 'ingress']));
    final externalIPs = [for (final ip in (spec['externalIPs'] as List? ?? const [])) '$ip'];
    final families = [for (final f in (spec['ipFamilies'] as List? ?? const [])) '$f'].join(', ');
    final affinityTimeout = dig<num>(spec, ['sessionAffinityConfig', 'clientIP', 'timeoutSeconds']);
    final isExternal = type == 'NodePort' || type == 'LoadBalancer';
    Widget ipWrap(List<String> v) => Wrap(spacing: 10, runSpacing: 2, children: [for (final ip in v) CopyText(ip)]);
    return KeyValueTable([
      (
        'Cluster IP',
        type == 'ExternalName'
            ? null
            : headless
            ? Row(
                children: [
                  const StatusBadge('None', dense: true, severity: Severity.neutral),
                  const SizedBox(width: 6),
                  const Expanded(child: Muted('headless')),
                ],
              )
            : ipWrap(ips),
      ),
      ('External name', spec['externalName'] != null ? CopyText('${spec['externalName']}') : null),
      ('IP families', families.isEmpty ? null : '$families${spec['ipFamilyPolicy'] != null ? '  ·  ${spec['ipFamilyPolicy']}' : ''}'),
      ('External IPs', externalIPs.isEmpty ? null : ipWrap(externalIPs)),
      (
        'Load balancer',
        type != 'LoadBalancer'
            ? null
            : lbIngress.isEmpty
            ? const StatusBadge('Pending', dense: true, severity: Severity.warn)
            : ipWrap([for (final i in lbIngress) '${i['ip'] ?? i['hostname'] ?? ''}']),
      ),
      ('LB class', spec['loadBalancerClass'] as String?),
      ('LB source ranges', (spec['loadBalancerSourceRanges'] as List?)?.join(', ')),
      ('Session affinity', '${spec['sessionAffinity'] ?? 'None'}${affinityTimeout != null ? ' (${affinityTimeout}s)' : ''}'),
      ('External traffic', isExternal ? spec['externalTrafficPolicy'] as String? : null),
      ('Internal traffic', spec['internalTrafficPolicy'] as String?),
      ('Publish not-ready', spec['publishNotReadyAddresses'] == true ? 'true (not-ready pods are in DNS)' : null),
    ], keyWidth: 120);
  }
}

class _ServiceBackendsView extends StatelessWidget {
  final PanelContext ctx;
  final List<Json> ports;
  final bool headless;
  final String dns;
  const _ServiceBackendsView({super.key, required this.ctx, required this.ports, required this.headless, required this.dns});

  Future<ServiceBackends> _load() async {
    final ns = ctx.namespace;
    final selector = asMap(ctx.spec['selector']);
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
    final external = ctx.spec['type'] == 'ExternalName';
    return NetFetch<ServiceBackends>(
      fetchKey: fingerprint([ctx.spec['selector'], ctx.spec['ports']]),
      load: _load,
      builder: (context, snap, reload) {
        final data = snap.data;
        final children = <Widget>[DetailSection(title: 'Ports', icon: Icons.settings_ethernet, child: _portsTable(context, data))];
        if (!external) {
          final addrs = data == null ? const <EndpointAddr>[] : EndpointAddr.fromSlices(data.slices);
          final ready = addrs.where((a) => a.ready).length;
          final diag = data == null ? null : diagnoseService(ctx.object, data);
          children.add(
            DetailSection(
              title: 'Endpoints',
              icon: Icons.hub_outlined,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (data != null) CountBadge(ready: ready, total: addrs.length),
                  const SizedBox(width: 4),
                  RefreshButton(reload),
                ],
              ),
              child: snap.hasError
                  ? InlineMessage('${snap.error}', isError: true)
                  : data == null
                  ? spinner
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (diag != null) Callout(severity: diag.severity, title: diag.title, detail: diag.detail),
                        if (addrs.isNotEmpty)
                          EndpointList(addrs, namespace: ctx.namespace, headlessDnsSuffix: headless ? dns : null)
                        else if (diag == null)
                          const InlineMessage('No endpoints'),
                        if (data.pods != null && ready == 0 && data.pods!.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          const Muted('Matching pods'),
                          const SizedBox(height: 2),
                          for (final p in data.pods!.take(20))
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 2),
                              child: Row(
                                children: [
                                  StatusBadge(
                                    podReady(p) ? 'Ready' : 'NotReady · ${dig(p, ['status', 'phase']) ?? 'Unknown'}',
                                    dense: true,
                                    severity: podReady(p) ? Severity.ok : Severity.error,
                                  ),
                                  const SizedBox(width: 6),
                                  Flexible(
                                    child: ResourceLink(ObjectRef(kind: 'Pod', name: '${dig(p, ['metadata', 'name'])}', namespace: ctx.namespace)),
                                  ),
                                ],
                              ),
                            ),
                        ],
                        if (data.slices.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 8,
                            runSpacing: 2,
                            children: [
                              const Muted('Slices:'),
                              for (final s in data.slices)
                                ResourceLink(
                                  ObjectRef(
                                    group: 'discovery.k8s.io',
                                    kind: 'EndpointSlice',
                                    name: '${dig(s, ['metadata', 'name'])}',
                                    namespace: ctx.namespace,
                                  ),
                                  label: '${dig(s, ['metadata', 'name'])}',
                                ),
                            ],
                          ),
                        ],
                      ],
                    ),
            ),
          );
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: children);
      },
    );
  }

  Widget _portsTable(BuildContext context, ServiceBackends? data) {
    if (ports.isEmpty) return const InlineMessage('No ports');
    final hasNodePort = ports.any((p) => p['nodePort'] != null);
    final hasApp = ports.any((p) => p['appProtocol'] != null);
    final warn = severityColor(context, Severity.warn);
    // One-click forward needs pods behind a selector (not ExternalName / manual endpoints).
    final canForward = !ctx.app.readOnly && asMap(ctx.spec['selector']).isNotEmpty && ctx.spec['type'] != 'ExternalName';
    return NetTable(
      headers: ['Name', 'Port', 'Target', if (hasNodePort) 'NodePort', 'Proto', if (hasApp) 'App', if (canForward) ''],
      flex: [null, null, null, if (hasNodePort) null, hasApp ? null : 1, if (hasApp) 1, if (canForward) null],
      rows: [
        for (final p in ports)
          () {
            final t = resolveTargetPort(p, pods: data?.pods, slices: data?.slices ?? const []);
            return <Widget>[
              Mono('${p['name'] ?? '—'}'),
              Mono('${p['port']}'),
              _maybeTip(
                t.note,
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (t.unresolved) ...[Icon(Icons.warning_amber_rounded, size: 13, color: warn), const SizedBox(width: 3)],
                    Flexible(child: Mono(t.text, color: t.unresolved ? warn : null)),
                  ],
                ),
              ),
              if (hasNodePort) Mono(p['nodePort'] != null ? '${p['nodePort']}' : '—'),
              Mono('${p['protocol'] ?? 'TCP'}'),
              if (hasApp) Mono('${p['appProtocol'] ?? '—'}'),
              if (canForward)
                QuickForwardButton(
                  api: ctx.api,
                  app: ctx.app,
                  namespace: ctx.namespace ?? 'default',
                  kind: 'service',
                  name: ctx.name,
                  port: '${p['port']}',
                  protocol: p['protocol'] as String?,
                ),
            ];
          }(),
      ],
    );
  }

  static Widget _maybeTip(String? msg, Widget child) => msg == null ? child : Tooltip(message: msg, child: child);
}
