import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'gw_model.dart';
import 'gw_widgets.dart';

/// One route's attachment to this Gateway through one parentRef.
class Attachment {
  final RouteObj route;
  final ParentRef ref;
  const Attachment(this.route, this.ref);

  Json? get status => route.statusFor(ref);
  Json? get accepted => condOf(status?['conditions'], 'Accepted');
  bool get isAccepted => condTrue(accepted);
  bool get unresolved => condFalse(condOf(status?['conditions'], 'ResolvedRefs'));
}

class GatewayLookups {
  final List<Attachment> attachments;
  final Json? gatewayClass;
  final bool classMissing;

  /// BackendRef.key → exists, for certificate Secrets and route backends.
  final Map<String, bool?> exists;
  final Map<String, Json>? nsLabels;
  const GatewayLookups({this.attachments = const [], this.gatewayClass, this.classMissing = false, this.exists = const {}, this.nsLabels});
}

/// Certificate references of a listener, normalised.
List<BackendRef> certRefs(Json listener, String gwNamespace) => [
      for (final c in asMapList(dig(listener, ['tls', 'certificateRefs'])))
        BackendRef(group: '${c['group'] ?? ''}', kind: '${c['kind'] ?? 'Secret'}', namespace: '${c['namespace'] ?? gwNamespace}', name: '${c['name'] ?? ''}'),
    ];

/// Groups attachments by listener name. Routes without a sectionName/port
/// appear under every listener that would accept them; '' collects routes
/// that match no listener.
Map<String, List<Attachment>> groupByListener(Json gateway, List<Attachment> attachments, {Map<String, Json>? nsLabels}) {
  final listeners = asMapList(dig(gateway, ['spec', 'listeners']));
  final out = <String, List<Attachment>>{for (final l in listeners) '${l['name']}': []};
  for (final a in attachments) {
    final names = a.ref.sectionName != null
        ? [if (out.containsKey(a.ref.sectionName)) a.ref.sectionName!]
        : [for (final l in listenersFor(gateway, a.ref, a.route, nsLabels: nsLabels)) '${l['name']}'];
    if (names.isEmpty) {
      out.putIfAbsent('', () => []).add(a);
    } else {
      for (final n in names) {
        out[n]!.add(a);
      }
    }
  }
  return out;
}

class GatewayPanel extends ResourcePanel {
  const GatewayPanel();

  @override
  Set<String> get kinds => {'$gwGroup/Gateway'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) => [_GatewayView(key: ValueKey('${ctx.uid}/gateway'), ctx: ctx)];
}

class _GatewayView extends StatelessWidget {
  final PanelContext ctx;
  const _GatewayView({super.key, required this.ctx});

  String get ns => ctx.namespace ?? '';
  List<Json> get listeners => asMapList(ctx.spec['listeners']);
  Json? listenerStatus(String name) => asMapList(ctx.status['listeners']).where((l) => l['name'] == name).firstOrNull;

  Future<GatewayLookups> _load() async {
    final api = ctx.api;
    final className = '${ctx.spec['gatewayClassName'] ?? ''}';
    final classFuture = fetchOrNull(api, const ResourceRef(group: gwGroup, resource: 'gatewayclasses'), name: className);
    final routesFuture = fetchRoutes(api, ctx.app);
    final usesSelector = listeners.any((l) => dig(l, ['allowedRoutes', 'namespaces', 'from']) == 'Selector');
    final nsFuture = usesSelector ? api.items(const ResourceRef(resource: 'namespaces')).then<List<Json>?>((v) => v, onError: (_) => null) : Future.value(null);
    final gwClass = await classFuture;
    final routes = await routesFuture;
    final nss = await nsFuture;
    final attachments = [
      for (final r in routes)
        for (final p in r.parentRefs)
          if (p.targets(ns, ctx.name)) Attachment(r, p),
    ];
    final refs = [
      for (final l in listeners) ...certRefs(l, ns),
      for (final a in attachments) ...a.route.backendRefs,
    ];
    return GatewayLookups(
      attachments: attachments,
      gatewayClass: gwClass,
      classMissing: gwClass == null,
      exists: await existence(api, refs, limit: 60),
      nsLabels: nss == null ? null : {for (final n in nss) '${dig(n, ['metadata', 'name'])}': asMap(dig(n, ['metadata', 'labels']))},
    );
  }

  @override
  Widget build(BuildContext context) {
    return NetFetch<GatewayLookups>(
      fetchKey: fingerprint([ctx.spec['listeners'], ctx.spec['gatewayClassName']]),
      load: _load,
      builder: (context, snap, reload) {
        final data = snap.data;
        final conds = ctx.status['conditions'];
        final grouped = data == null ? null : groupByListener(ctx.object, data.attachments, nsLabels: data.nsLabels);
        final infra = asMap(ctx.spec['infrastructure']);
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DetailSection(
            title: 'Gateway',
            icon: Icons.router_outlined,
            trailing: condTrue(condOf(conds, 'Accepted'))
                ? CondBadge(condOf(conds, 'Programmed'), label: 'Programmed', negative: 'Not programmed')
                : CondBadge(condOf(conds, 'Accepted'), label: 'Accepted', negative: 'Not accepted'),
            child: _summary(context, data),
          ),
          DetailSection(
            title: 'Listeners',
            icon: Icons.sensors,
            trailing: Text('${listeners.length}'),
            child: _listeners(context, data),
          ),
          DetailSection(
            title: 'Attached routes',
            icon: Icons.alt_route,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (data != null) Text('${{for (final a in data.attachments) a.route}.length}'),
              const SizedBox(width: 4),
              RefreshButton(reload),
            ]),
            child: snap.hasError
                ? InlineMessage('${snap.error}', isError: true)
                : grouped == null
                    ? spinner
                    : _routes(context, grouped),
          ),
          if (grouped != null && data!.attachments.isNotEmpty)
            DetailSection(key: const ValueKey('topology'), title: 'Topology', icon: Icons.account_tree_outlined, child: _topology(context, grouped, data)),
          if (asMap(infra['labels']).isNotEmpty || asMap(infra['annotations']).isNotEmpty || infra['parametersRef'] != null)
            DetailSection(key: const ValueKey('infra'), title: 'Infrastructure', icon: Icons.dns_outlined, child: _infra(context, infra)),
          DetailSection(key: const ValueKey('conditions'), title: 'Conditions', icon: Icons.checklist, initiallyExpanded: false, child: ConditionsTable(conds as List?)),
        ]);
      },
    );
  }

  Widget _summary(BuildContext context, GatewayLookups? data) {
    final addresses = asMapList(ctx.status['addresses']);
    final className = '${ctx.spec['gatewayClassName'] ?? ''}';
    final diags = explainGateway(ctx.object, gatewayClass: data?.gatewayClass);
    final badListeners = [for (final l in listeners) if (listenerProblems(listenerStatus('${l['name']}')).isNotEmpty) '${l['name']}'];
    final classAccepted = data?.gatewayClass == null ? null : condOf(dig(data!.gatewayClass, ['status', 'conditions']), 'Accepted');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final d in diags) DiagCallout(d),
      if (badListeners.isNotEmpty)
        Callout(
          severity: Severity.warn,
          title: '${badListeners.length} of ${listeners.length} listener${listeners.length == 1 ? '' : 's'} ${badListeners.length == 1 ? 'has' : 'have'} problems',
          detail: 'See ${badListeners.map((n) => "'$n'").join(', ')} below. Routes attached only to ${badListeners.length == 1 ? 'it' : 'them'} get no traffic.',
        ),
      KeyValueTable([
        (
          'Status',
          Wrap(spacing: 10, runSpacing: 2, children: [
            CondBadge(condOf(ctx.status['conditions'], 'Accepted'), label: 'Accepted', negative: 'Not accepted'),
            CondBadge(condOf(ctx.status['conditions'], 'Programmed'), label: 'Programmed', negative: 'Not programmed'),
          ]),
        ),
        (
          'Class',
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            gwLink('GatewayClass', className, label: className),
            if (data?.classMissing == true) const StatusBadge('not found', dense: true, severity: Severity.error),
            if (classAccepted != null && !condTrue(classAccepted)) CondBadge(classAccepted, label: 'Accepted', negative: 'Class not accepted'),
          ]),
        ),
        (
          'Addresses',
          addresses.isEmpty
              ? const Muted('none assigned')
              : Wrap(spacing: 12, runSpacing: 2, children: [
                  for (final a in addresses)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(child: CopyText('${a['value']}')),
                      if (a['type'] != null && a['type'] != 'IPAddress') Muted(' ${a['type']}'),
                    ]),
                ]),
        ),
        (
          'Requested',
          asMapList(ctx.spec['addresses']).isEmpty ? null : asMapList(ctx.spec['addresses']).map((a) => '${a['value']}').join(', '),
        ),
      ], keyWidth: 90),
    ]);
  }

  Widget _listeners(BuildContext context, GatewayLookups? data) {
    if (listeners.isEmpty) return const InlineMessage('No listeners', isError: true);
    final theme = Theme.of(context);
    return HairlineList([
      for (final l in listeners)
        () {
          final name = '${l['name']}';
          final st = listenerStatus(name);
          final problems = listenerProblems(st);
          final programmed = condOf(st?['conditions'], 'Programmed');
          final sev = problems.isNotEmpty
              ? diagSeverity(problems.first.level)
              : condTrue(programmed)
                  ? Severity.ok
                  : Severity.warn;
          final tls = asMap(l['tls']);
          final certs = certRefs(l, ns);
          final kinds = listenerKinds(l);
          final explicitKinds = asMapList(dig(l, ['allowedRoutes', 'kinds'])).isNotEmpty;
          final attached = st?['attachedRoutes'];
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Row(children: [
              Container(width: 7, height: 7, decoration: BoxDecoration(color: severityColor(context, sev), shape: BoxShape.circle)),
              const SizedBox(width: 8),
              Flexible(child: Text(name, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600))),
              const SizedBox(width: 8),
              Mono('${l['protocol']} :${l['port']}'),
              const SizedBox(width: 8),
              Expanded(child: Text('${l['hostname'] ?? '*'}', overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11.5, color: theme.hintColor))),
              if (attached != null) Muted('$attached route${attached == 1 ? '' : 's'}'),
            ]),
            Padding(
              padding: const EdgeInsets.only(left: 15, top: 3),
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                if (tls.isNotEmpty || certs.isNotEmpty)
                  Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    Icon(Icons.lock_outline, size: 12, color: theme.hintColor),
                    Muted('TLS ${tls['mode'] ?? 'Terminate'}'),
                    for (final c in certs) BackendLine(c, fromNamespace: ns, exists: data?.exists[c.key]),
                  ]),
                Muted('Routes from ${describeAllowedNamespaces(l, ns)} · ${explicitKinds ? '' : 'default '}kinds ${kinds.join(', ')}'),
                for (final p in problems)
                  Padding(padding: const EdgeInsets.only(top: 4), child: DiagCallout(p)),
              ]),
            ),
          ]);
        }(),
    ]);
  }

  Widget _routeRow(BuildContext context, Attachment a) {
    final acc = a.accepted;
    final sev = !a.isAccepted ? Severity.error : (a.unresolved ? Severity.warn : Severity.ok);
    final text = !a.isAccepted ? (acc == null ? 'No status' : 'Not accepted') : (a.unresolved ? 'Unresolved refs' : 'Accepted');
    final why = !a.isAccepted ? acc : (a.unresolved ? condOf(a.status?['conditions'], 'ResolvedRefs') : null);
    final tip = why == null ? null : [why['reason'], why['message']].whereType<String>().join(': ');
    final hosts = a.route.hostnames;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
            routeLink(a.route, showKind: true),
            if (hosts.isNotEmpty) Muted(hosts.join(', '), mono: true),
          ]),
        ),
        const SizedBox(width: 8),
        Tooltip(message: tip ?? '', child: StatusBadge(text, dense: true, severity: sev)),
      ]),
    );
  }

  Widget _routes(BuildContext context, Map<String, List<Attachment>> grouped) {
    if (grouped.values.every((v) => v.isEmpty)) {
      return const InlineMessage('No routes reference this Gateway in their parentRefs.');
    }
    final protocolOf = {for (final l in listeners) '${l['name']}': '${l['protocol']} :${l['port']}'};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final e in grouped.entries)
        if (e.value.isNotEmpty || e.key.isNotEmpty) ...[
          SubHeader(e.key.isEmpty ? 'NO MATCHING LISTENER' : '${e.key.toUpperCase()} · ${protocolOf[e.key] ?? ''}'),
          if (e.value.isEmpty) const Muted('no routes') else for (final a in e.value) _routeRow(context, a),
        ],
    ]);
  }

  Widget _topology(BuildContext context, Map<String, List<Attachment>> grouped, GatewayLookups data) {
    final theme = Theme.of(context);
    final byName = {for (final l in listeners) '${l['name']}': l};
    final addr = asMapList(ctx.status['addresses']).map((a) => '${a['value']}').join(', ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TreeRow(
        icon: Icons.router_outlined,
        main: Text(ctx.name, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
        extras: [if (addr.isNotEmpty) Muted(addr, mono: true)],
      ),
      TreeIndent(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          for (final e in grouped.entries)
            if (e.value.isNotEmpty) ...[
              TreeRow(
                icon: Icons.sensors,
                main: Text(e.key.isEmpty ? '(no listener)' : e.key, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w500)),
                extras: [
                  if (byName[e.key] != null) Muted('${byName[e.key]!['protocol']} :${byName[e.key]!['port']}${byName[e.key]!['hostname'] != null ? '  ${byName[e.key]!['hostname']}' : ''}', mono: true),
                ],
              ),
              TreeIndent(
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  for (final a in e.value) ...[
                    TreeRow(
                      icon: Icons.alt_route,
                      status: a.isAccepted ? (a.unresolved ? Severity.warn : null) : Severity.error,
                      main: routeLink(a.route, showKind: true),
                      extras: [if (!a.isAccepted) const StatusBadge('not accepted', dense: true, severity: Severity.error)],
                    ),
                    if (a.route.backendRefs.isNotEmpty)
                      TreeIndent(
                        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          for (final b in {for (final b in a.route.backendRefs) b.key: b}.values)
                            TreeRow(
                              icon: Icons.lan_outlined,
                              status: data.exists[b.key] == false ? Severity.error : null,
                              main: BackendLine(b, fromNamespace: a.route.namespace, exists: data.exists[b.key]),
                            ),
                        ]),
                      ),
                  ],
                ]),
              ),
            ],
        ]),
      ),
    ]);
  }

  Widget _infra(BuildContext context, Json infra) {
    final p = asMap(infra['parametersRef']);
    return KeyValueTable([
      ('Labels', asMap(infra['labels']).isEmpty ? null : LabelChips(asMap(infra['labels']))),
      ('Annotations', asMap(infra['annotations']).isEmpty ? null : LabelChips(asMap(infra['annotations']))),
      (
        'Parameters',
        p.isEmpty ? null : ResourceLink(ObjectRef(group: '${p['group'] ?? ''}', kind: '${p['kind']}', name: '${p['name']}', namespace: ns), label: '${p['kind']}/${p['name']}'),
      ),
    ], keyWidth: 90);
  }
}
