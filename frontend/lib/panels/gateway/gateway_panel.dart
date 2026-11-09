import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../../ui/inspector/inspector.dart';
import '../panel.dart';
import '../pod/pod_widgets.dart' show InlineWrap;
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
        final conds = asMapList(ctx.status['conditions']);
        final grouped = data == null ? null : groupByListener(ctx.object, data.attachments, nsLabels: data.nsLabels);
        final infra = asMap(ctx.spec['infrastructure']);
        final routeCount = data == null ? null : {for (final a in data.attachments) a.route}.length;
        final badConds = [for (final c in conds) if (c['status'] != 'True') '${c['type']}'];
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(context, data, snap.error),
          InspectorSection(
            id: 'gw-listeners',
            title: 'Listeners',
            trailing: SectionSummary(_listenerSummary()),
            child: _listeners(context, data),
          ),
          InspectorSection(
            id: 'gw-routes',
            title: 'Attached routes',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (data != null) Flexible(child: SectionSummary(_routesSummary(data.attachments, routeCount!))),
              const SizedBox(width: 4),
              SizedBox(height: 20, child: RefreshButton(reload)),
            ]),
            child: snap.hasError
                ? InlineMessage('${snap.error}', isError: true)
                : grouped == null
                    ? spinner
                    : _routes(context, grouped),
          ),
          if (grouped != null && data!.attachments.isNotEmpty)
            InspectorSection(
              key: const ValueKey('topology'),
              id: 'gw-topology',
              title: 'Topology',
              initiallyExpanded: false,
              trailing: SectionSummary('${plural(listeners.length, 'listener')} · ${plural(routeCount!, 'route')}'),
              child: _topology(context, grouped, data),
            ),
          if (asMap(infra['labels']).isNotEmpty || asMap(infra['annotations']).isNotEmpty || infra['parametersRef'] != null)
            InspectorSection(
              key: const ValueKey('infra'),
              id: 'gw-infra',
              title: 'Infrastructure',
              initiallyExpanded: false,
              trailing: SectionSummary([
                if (asMap(infra['labels']).isNotEmpty) plural(asMap(infra['labels']).length, 'label'),
                if (asMap(infra['annotations']).isNotEmpty) plural(asMap(infra['annotations']).length, 'annotation'),
                if (infra['parametersRef'] != null) 'parameters',
              ].join(' · ')),
              child: _infra(context, infra),
            ),
          InspectorSection(
            key: const ValueKey('conditions'),
            id: 'gw-conditions',
            title: 'Conditions',
            initiallyExpanded: false,
            trailing: SectionSummary(
              conds.isEmpty ? 'none' : (badConds.isEmpty ? 'all ${conds.length} true' : '${badConds.join(', ')} not true'),
              color: badConds.isEmpty ? null : severityColor(context, Severity.warn),
            ),
            child: ConditionsTable(ctx.status['conditions'] as List?),
          ),
        ]);
      },
    );
  }

  String _listenerSummary() {
    final bad = [for (final l in listeners) if (listenerProblems(listenerStatus('${l['name']}')).isNotEmpty) l].length;
    return [plural(listeners.length, 'listener'), if (bad > 0) '$bad with problems'].join(' · ');
  }

  static String _routesSummary(List<Attachment> attachments, int routes) {
    final bad = {for (final a in attachments) if (!a.isAccepted) a.route}.length;
    return [plural(routes, 'route'), if (bad > 0) '$bad not accepted'].join(' · ');
  }

  Widget _header(BuildContext context, GatewayLookups? data, Object? error) {
    final conds = ctx.status['conditions'];
    final accepted = condOf(conds, 'Accepted');
    final programmed = condOf(conds, 'Programmed');
    final addresses = asMapList(ctx.status['addresses']);
    final className = '${ctx.spec['gatewayClassName'] ?? ''}';
    final diags = explainGateway(ctx.object, gatewayClass: data?.gatewayClass);
    final badListeners = [for (final l in listeners) if (listenerProblems(listenerStatus('${l['name']}')).isNotEmpty) '${l['name']}'];
    final classAccepted = data?.gatewayClass == null ? null : condOf(dig(data!.gatewayClass, ['status', 'conditions']), 'Accepted');
    final insights = <Insight>[
      for (final d in diags) Insight(diagSeverity(d.level), d.title, d.detail),
      if (badListeners.isNotEmpty)
        Insight(
          Severity.warn,
          '${badListeners.length} of ${listeners.length} listener${listeners.length == 1 ? '' : 's'} ${badListeners.length == 1 ? 'has' : 'have'} problems',
          'See ${badListeners.map((n) => "'$n'").join(', ')} below. Routes attached only to ${badListeners.length == 1 ? 'it' : 'them'} get no traffic.',
        ),
      if (data?.classMissing == true) Insight(Severity.error, 'GatewayClass $className not found', 'No controller will reconcile this Gateway until the class exists.'),
      if (classAccepted != null && !condTrue(classAccepted))
        Insight(Severity.warn, 'GatewayClass $className is not accepted', [classAccepted['reason'], classAccepted['message']].whereType<String>().join(': ')),
      if (error != null) Insight(Severity.warn, 'Lookup failed', '$error'),
    ];
    final String headline;
    if (accepted == null || accepted['status'] == 'Unknown' || accepted['reason'] == 'Pending') {
      headline = 'Pending';
    } else if (!condTrue(accepted)) {
      headline = 'Not accepted';
    } else if (programmed != null && !condTrue(programmed)) {
      headline = 'Not programmed';
    } else {
      headline = 'Programmed';
    }
    String reason(Json? c) => c == null ? 'no status' : '${c['reason'] ?? c['status']}';
    final okListeners = listeners.length - badListeners.length;
    final routes = data == null ? null : {for (final a in data.attachments) a.route}.length;
    return InspectorHeader(
      mark: worstOf(insights) ?? (headline == 'Programmed' ? Severity.ok : Severity.warn),
      headline: headline,
      detail: headline == 'Programmed' ? 'Accepted · Programmed' : 'accepted: ${reason(accepted)} · programmed: ${reason(programmed)}',
      figures: [
        InspectorFigure('$okListeners', 'listeners ok',
            of: '/${listeners.length}', severity: listeners.isEmpty ? Severity.error : (badListeners.isEmpty ? Severity.neutral : Severity.warn), tooltip: '$okListeners of ${listeners.length} listeners without problems'),
        InspectorFigure(routes == null ? '–' : '$routes', routes == 1 ? 'route' : 'routes'),
        InspectorFigure('${addresses.length}', addresses.length == 1 ? 'address' : 'addresses', severity: addresses.isEmpty && headline != 'Pending' ? Severity.warn : Severity.neutral),
      ],
      insights: insights,
      factsKeyWidth: 80, facts: [
        (
          'Class',
          Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
            gwLink('GatewayClass', className, label: className),
            if (data?.classMissing == true) Text('not found', style: TextStyle(color: severityColor(context, Severity.error))),
          ]),
        ),
        (
          'Addresses',
          addresses.isEmpty
              ? const Muted('none assigned')
              : InlineWrap([
                  for (final a in addresses)
                    Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(child: Chipish(text: '${a['value']}', copyValue: '${a['value']}')),
                      if (a['type'] != null && a['type'] != 'IPAddress') Muted(' ${a['type']}'),
                    ]),
                ]),
        ),
        (
          'Requested',
          asMapList(ctx.spec['addresses']).isEmpty ? null : asMapList(ctx.spec['addresses']).map((a) => '${a['value']}').join(', '),
        ),
      ],
    );
  }

  Widget _listeners(BuildContext context, GatewayLookups? data) {
    if (listeners.isEmpty) return const InlineMessage('No listeners', isError: true);
    final theme = Theme.of(context);
    final rows = [
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
          final bad = sev == Severity.error || sev == Severity.warn;
          return (
            bad,
            InspectorRow(
              key: ValueKey('listener-$name'),
              memoryId: 'gw-listener:${ctx.uid}/$name',
              dot: sev,
              initiallyExpanded: bad,
              title: Text.rich(TextSpan(children: [
                TextSpan(text: name, style: const TextStyle(fontWeight: FontWeight.w600)),
                TextSpan(text: '  ${l['protocol']} :${l['port']}', style: monoStyle(context, size: 11.5, color: theme.hintColor)),
              ])),
              subtitle: Row(children: [
                if (tls.isNotEmpty || certs.isNotEmpty) ...[Icon(Icons.lock_outline, size: 11, color: theme.hintColor), const SizedBox(width: 3)],
                Flexible(child: Text('${l['hostname'] ?? '*'}', maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11, color: theme.hintColor))),
                if (bad) ...[
                  const SizedBox(width: 6),
                  Flexible(child: Text(problems.isEmpty ? 'not programmed' : problems.first.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: severityColor(context, sev), fontWeight: FontWeight.w600))),
                ],
              ]),
              trailing: [if (attached != null) Text('$attached route${attached == 1 ? '' : 's'}', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor))],
              details: (_) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, spacing: 10, children: [
                if (problems.isNotEmpty) InsightList([for (final p in problems) Insight(diagSeverity(p.level), p.title, p.detail)]),
                if (tls.isNotEmpty || certs.isNotEmpty)
                  QuietGroup('TLS ${tls['mode'] ?? 'Terminate'}', [
                    if (certs.isEmpty) const Muted('no certificates'),
                    for (final c in certs) BackendLine(c, fromNamespace: ns, exists: data?.exists[c.key]),
                  ]),
                QuietGroup('Allowed routes', [
                  Text('Routes from ${describeAllowedNamespaces(l, ns)} · ${explicitKinds ? '' : 'default '}kinds ${kinds.join(', ')}'),
                ]),
              ]),
            ),
          );
        }(),
    ];
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final r in rows) if (r.$1) r.$2,
      for (final r in rows) if (!r.$1) r.$2,
    ]);
  }

  Widget _routeRow(BuildContext context, Attachment a, String group) {
    final acc = a.accepted;
    final sev = !a.isAccepted ? Severity.error : (a.unresolved ? Severity.warn : Severity.ok);
    final text = !a.isAccepted ? (acc == null ? 'No status' : 'Not accepted') : (a.unresolved ? 'Unresolved refs' : 'Accepted');
    final why = !a.isAccepted ? acc : (a.unresolved ? condOf(a.status?['conditions'], 'ResolvedRefs') : null);
    final tip = why == null ? null : [why['reason'], why['message']].whereType<String>().join(': ');
    final hosts = a.route.hostnames;
    final theme = Theme.of(context);
    final bad = sev != Severity.ok;
    return InspectorRow(
      key: ValueKey('gw-route-$group/${a.route.namespace}/${a.route.name}'),
      dot: sev,
      dotTooltip: text,
      title: routeLink(a.route, showKind: true),
      subtitle: hosts.isEmpty ? null : Text(hosts.join(', '), maxLines: 1, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11, color: theme.hintColor)),
      trailing: [
        if (bad)
          Tooltip(
            message: tip ?? '',
            child: Text(text, style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, sev), fontWeight: FontWeight.w600)),
          ),
      ],
    );
  }

  Widget _routes(BuildContext context, Map<String, List<Attachment>> grouped) {
    if (grouped.values.every((v) => v.isEmpty)) {
      return const InlineMessage('No routes reference this Gateway in their parentRefs.');
    }
    final protocolOf = {for (final l in listeners) '${l['name']}': '${l['protocol']} :${l['port']}'};
    bool ok(Attachment a) => a.isAccepted && !a.unresolved;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final e in grouped.entries)
        if (e.value.isNotEmpty || e.key.isNotEmpty) ...[
          RowGroupLabel(e.key.isEmpty ? 'No matching listener' : '${e.key} · ${protocolOf[e.key] ?? ''}'),
          if (e.value.isEmpty)
            const Padding(padding: EdgeInsets.only(left: 4), child: Muted('no routes'))
          else
            for (final a in [...e.value.where((a) => !ok(a)), ...e.value.where(ok)]) _routeRow(context, a, e.key),
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
