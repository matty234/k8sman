/// Endpoint rows and badges shared by the network panels.
library;

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../ui/inspector/inspector.dart';
import '../../ui/widgets/atoms.dart';

/// Ready/total pill for section trailers.
class CountBadge extends StatelessWidget {
  final int ready;
  final int total;
  final String noun;
  const CountBadge({super.key, required this.ready, required this.total, this.noun = 'ready'});

  @override
  Widget build(BuildContext context) => StatusBadge('$ready/$total $noun',
      dense: true,
      severity: total == 0
          ? Severity.error
          : ready == total
              ? Severity.ok
              : ready == 0
                  ? Severity.error
                  : Severity.warn);
}

// ---------------------------------------------------------------------------
// Endpoint rows (shared by Service, EndpointSlice and Endpoints panels)

/// One backend address, normalised from an EndpointSlice endpoint or a
/// legacy Endpoints subset address.
class EndpointAddr {
  final String ip;
  final bool ready;
  final bool? serving;
  final bool terminating;
  final Json? targetRef;
  final String? nodeName;
  final String? zone;
  final String? hostname;
  final List<String> hints;
  const EndpointAddr({
    required this.ip,
    required this.ready,
    this.serving,
    this.terminating = false,
    this.targetRef,
    this.nodeName,
    this.zone,
    this.hostname,
    this.hints = const [],
  });

  /// One row per address of an EndpointSlice endpoint.
  static List<EndpointAddr> fromSliceEndpoint(Json e) {
    final cond = asMap(e['conditions']);
    // Per the API: a nil `ready` should be interpreted as true.
    final ready = cond['ready'] != false;
    final hints = [for (final z in asMapList(dig(e, ['hints', 'forZones']))) '${z['name']}'];
    return [
      for (final a in (e['addresses'] as List? ?? const []))
        EndpointAddr(
          ip: '$a',
          ready: ready,
          serving: cond['serving'] is bool ? cond['serving'] as bool : null,
          terminating: cond['terminating'] == true,
          targetRef: e['targetRef'] is Map ? asMap(e['targetRef']) : null,
          nodeName: e['nodeName'] as String?,
          zone: e['zone'] as String?,
          hostname: e['hostname'] as String?,
          hints: hints,
        ),
    ];
  }

  static List<EndpointAddr> fromSlices(List<Json> slices) =>
      [for (final s in slices) for (final e in asMapList(s['endpoints'])) ...fromSliceEndpoint(e)];

  static EndpointAddr fromLegacy(Json a, {required bool ready}) => EndpointAddr(
        ip: '${a['ip'] ?? ''}',
        ready: ready,
        targetRef: a['targetRef'] is Map ? asMap(a['targetRef']) : null,
        nodeName: a['nodeName'] as String?,
        hostname: a['hostname'] as String?,
      );
}

/// Addresses as compact rows, not-ready first: a state dot, the IP, what
/// backs it (pod and node links, zone) and its condition when not plainly
/// ready; copy on hover.
class EndpointList extends StatelessWidget {
  final List<EndpointAddr> addrs;
  final String? namespace;

  /// When set (headless services), show the per-pod DNS name for hostnames.
  final String? headlessDnsSuffix;
  const EndpointList(this.addrs, {super.key, this.namespace, this.headlessDnsSuffix});

  /// Not ready first, then terminating, then by IP.
  static List<EndpointAddr> ordered(List<EndpointAddr> addrs) => [...addrs]..sort((a, b) {
      int rank(EndpointAddr x) => !x.ready ? 0 : (x.terminating ? 1 : 2);
      final r = rank(a).compareTo(rank(b));
      return r != 0 ? r : a.ip.compareTo(b.ip);
    });

  @override
  Widget build(BuildContext context) {
    if (addrs.isEmpty) return const Padding(padding: EdgeInsets.only(left: 4), child: HintText('No addresses'));
    return TrimmedList([for (final a in ordered(addrs)) _row(context, a)], trimAbove: 10);
  }

  Widget _row(BuildContext context, EndpointAddr a) {
    final theme = Theme.of(context);
    final sev = !a.ready ? Severity.error : (a.terminating ? Severity.warn : Severity.ok);
    final tr = a.targetRef;
    final state = [
      if (!a.ready) 'not ready',
      if (a.serving != null && a.serving != a.ready) a.serving! ? 'serving' : 'not serving',
      if (a.terminating) 'terminating',
    ].join(' · ');
    final dns = a.hostname != null && headlessDnsSuffix != null ? '${a.hostname}.$headlessDnsSuffix' : null;
    return InspectorRow(
      key: ValueKey('endpoint-${a.ip}'),
      dot: sev,
      dotTooltip: state.isEmpty ? 'ready' : state,
      title: Row(children: [
        Text(a.ip, style: monoStyle(context, size: 12)),
        if (state.isNotEmpty) ...[
          const SizedBox(width: 8),
          Flexible(
            child: Text(state, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, sev), fontWeight: FontWeight.w600)),
          ),
        ],
      ]),
      subtitle: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
        if (tr != null)
          ResourceLink(
            ObjectRef.fromOwnerRef({...tr, 'apiVersion': tr['apiVersion'] ?? 'v1'}, namespace: namespace),
            label: tr['kind'] == 'Pod' ? '${tr['name'] ?? ''}' : '${tr['kind'] ?? ''}/${tr['name'] ?? ''}',
          )
        else
          const Text('no targetRef'),
        if (a.nodeName != null) ResourceLink(ObjectRef(kind: 'Node', name: a.nodeName!), label: a.nodeName),
        if (a.zone != null) Text(a.zone!),
        if (a.hints.isNotEmpty) Text('hints: ${a.hints.join(', ')}'),
        if (dns != null) Text(dns, style: monoStyle(context, size: 11, color: theme.hintColor)),
        if (a.hostname != null && dns == null) Text('hostname: ${a.hostname}'),
      ]),
      actions: [copyAction(context, a.ip), if (dns != null) copyAction(context, dns, tooltip: 'Copy $dns')],
    );
  }
}

/// Chips for EndpointSlice / Endpoints ports: `http 8080/TCP`.
class PortChips extends StatelessWidget {
  final List<Json> ports;
  const PortChips(this.ports, {super.key});

  @override
  Widget build(BuildContext context) {
    if (ports.isEmpty) return const HintText('all ports');
    return Wrap(spacing: 4, runSpacing: 4, children: [
      for (final p in ports)
        Chipish(text: [
          if ((p['name'] ?? '').toString().isNotEmpty) '${p['name']}',
          '${p['port'] ?? '*'}/${p['protocol'] ?? 'TCP'}',
          if (p['appProtocol'] != null) '(${p['appProtocol']})',
        ].join(' ')),
    ]);
  }
}

/// Minimal client-side label selector check for `k=v` maps (used for
/// counting / matching, not for querying).
bool labelsMatch(Json? labels, Json selector) {
  final l = labels ?? const {};
  return selector.entries.every((e) => l[e.key]?.toString() == e.value?.toString());
}
