import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../panel.dart';
import '../../ui/inspector/inspector.dart';
import '../../ui/widgets/atoms.dart';

/// Annotation prefixes that configure ingress controllers / related tooling.
const controllerAnnotationPrefixes = [
  'nginx.ingress.kubernetes.io/',
  'ingress.kubernetes.io/',
  'kubernetes.io/ingress',
  'alb.ingress.kubernetes.io/',
  'service.beta.kubernetes.io/',
  'traefik.ingress.kubernetes.io/',
  'haproxy.org/',
  'haproxy.router.openshift.io/',
  'konghq.com/',
  'cert-manager.io/',
  'acme.cert-manager.io/',
  'external-dns.alpha.kubernetes.io/',
  'networking.gke.io/',
  'ingress.gcp.kubernetes.io/',
  'kubernetes.io/ingress.global-static-ip-name',
  'appgw.ingress.kubernetes.io/',
  'projectcontour.io/',
  'contour.heptio.com/',
  'getambassador.io/',
  'zalando.org/',
];

/// Ingress-controller annotations worth surfacing (order preserved).
Map<String, String> controllerAnnotations(dynamic annotations) => {
      for (final e in asMap(annotations).entries)
        if (controllerAnnotationPrefixes.any(e.key.startsWith)) e.key: '${e.value}',
    };

/// One flattened rule path.
class IngressPath {
  final String? host;
  final String path;
  final String pathType;
  final Json backend;
  const IngressPath({this.host, required this.path, required this.pathType, required this.backend});

  /// Copyable URL; https when the host is covered by a TLS entry.
  String url(Set<String> tlsHosts) {
    final h = host ?? '<address>';
    final scheme = host != null && _tlsCovers(tlsHosts, host!) ? 'https' : 'http';
    return '$scheme://$h$path';
  }
}

bool _tlsCovers(Set<String> tlsHosts, String host) {
  if (tlsHosts.contains(host)) return true;
  for (final t in tlsHosts) {
    if (t.startsWith('*.') && host.endsWith(t.substring(1)) && !host.substring(0, host.length - t.length + 1).contains('.')) return true;
  }
  return false;
}

List<IngressPath> flattenIngressRules(Json spec) => [
      for (final r in asMapList(spec['rules']))
        for (final p in asMapList(dig(r, ['http', 'paths'])))
          IngressPath(
            host: r['host'] as String?,
            path: '${p['path'] ?? '/'}',
            pathType: '${p['pathType'] ?? 'ImplementationSpecific'}',
            backend: asMap(p['backend']),
          ),
    ];

Set<String> ingressTlsHosts(Json spec) => {for (final t in asMapList(spec['tls'])) for (final h in (t['hosts'] as List? ?? const [])) '$h'};

/// Services referenced by rules and the default backend.
Set<String> referencedServices(Json spec) => {
      for (final p in flattenIngressRules(spec))
        if (dig<String>(p.backend, ['service', 'name']) != null) dig<String>(p.backend, ['service', 'name'])!,
      if (dig<String>(spec, ['defaultBackend', 'service', 'name']) != null) dig<String>(spec, ['defaultBackend', 'service', 'name'])!,
    };

class _IngressLookups {
  /// Service name → object, or null when 404.
  final Map<String, Json?> services;

  /// TLS secret name → exists? (null when unknown, e.g. forbidden).
  final Map<String, bool?> secrets;
  const _IngressLookups(this.services, this.secrets);
}

class IngressPanel extends ResourcePanel {
  const IngressPanel();

  @override
  Set<String> get kinds => {'networking.k8s.io/Ingress'};

  @override
  bool get ownerInHeader => true;

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    return [_IngressView(key: ValueKey('${ctx.uid}/ingress'), ctx: ctx)];
  }
}

/// How a backend resolves against the looked-up Services.
class _BackendState {
  final String? service;
  final String portText;
  final bool missing;
  final bool portBad;
  const _BackendState({this.service, this.portText = '', this.missing = false, this.portBad = false});

  bool get broken => missing || portBad;
}

_BackendState _resolveBackend(Json backend, _IngressLookups? data) {
  final svc = asMap(backend['service']);
  if (svc.isEmpty) return const _BackendState();
  final name = '${svc['name']}';
  final port = asMap(svc['port']);
  final known = data != null && data.services.containsKey(name);
  final svcObj = data?.services[name];
  var portBad = false;
  String portText;
  if (port['number'] != null) {
    portText = '${port['number']}';
    if (svcObj != null && !asMapList(dig(svcObj, ['spec', 'ports'])).any((p) => p['port'] == port['number'])) portBad = true;
  } else if (port['name'] != null) {
    final match = svcObj == null ? null : asMapList(dig(svcObj, ['spec', 'ports'])).where((p) => p['name'] == port['name']).firstOrNull;
    portText = match != null ? '${port['name']} (${match['port']})' : '${port['name']}';
    if (svcObj != null && match == null) portBad = true;
  } else {
    portText = '?';
  }
  return _BackendState(service: name, portText: portText, missing: known && svcObj == null, portBad: portBad);
}

class _IngressView extends StatelessWidget {
  final PanelContext ctx;
  const _IngressView({super.key, required this.ctx});

  Future<_IngressLookups> _load() async {
    final ns = ctx.namespace;
    final svcNames = referencedServices(ctx.spec).toList();
    final secretNames = {for (final t in asMapList(ctx.spec['tls'])) if (t['secretName'] != null) '${t['secretName']}'}.toList();
    final svcs = await Future.wait(svcNames.map((n) async {
      try {
        return await ctx.api.object(const ResourceRef(resource: 'services'), namespace: ns, name: n);
      } on ApiException catch (e) {
        if (e.status == 404) return null;
        rethrow;
      }
    }));
    final secrets = await Future.wait(secretNames.map((n) async {
      try {
        await ctx.api.object(const ResourceRef(resource: 'secrets'), namespace: ns, name: n);
        return true;
      } on ApiException catch (e) {
        return e.status == 404 ? false : null;
      }
    }));
    return _IngressLookups(
      {for (var i = 0; i < svcNames.length; i++) svcNames[i]: svcs[i]},
      {for (var i = 0; i < secretNames.length; i++) secretNames[i]: secrets[i]},
    );
  }

  @override
  Widget build(BuildContext context) {
    return NetFetch<_IngressLookups>(
      fetchKey: fingerprint([ctx.spec['rules'], ctx.spec['tls'], ctx.spec['defaultBackend']]),
      load: _load,
      builder: (context, snap, reload) {
        final data = snap.data;
        final spec = ctx.spec;
        final annotations = controllerAnnotations(ctx.metadata['annotations']);
        final paths = flattenIngressRules(spec);
        final tls = asMapList(spec['tls']);
        final missingSecrets = [for (final t in tls) if (t['secretName'] != null && data?.secrets['${t['secretName']}'] == false) '${t['secretName']}'];
        final def = asMap(spec['defaultBackend']);
        final defState = _resolveBackend(def, data);
        final hosts = {for (final p in paths) p.host ?? '*'}.length;
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          _header(context, data, paths, missingSecrets, defState, snap.error),
          InspectorSection(
            id: 'ing-rules',
            title: 'Rules',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(child: SectionSummary(paths.isEmpty ? 'none' : '${plural(hosts, 'host')} · ${plural(paths.length, 'path')}')),
              const SizedBox(width: 4),
              SizedBox(height: 20, child: RefreshButton(reload)),
            ]),
            child: _rules(context, data, paths),
          ),
          if (tls.isNotEmpty)
            InspectorSection(
              id: 'ing-tls',
              title: 'TLS',
              initiallyExpanded: false,
              trailing: SectionSummary(
                missingSecrets.isNotEmpty ? 'Secret not found' : '${plural(tls.length, 'certificate')} · ${plural(ingressTlsHosts(spec).length, 'host')}',
                color: missingSecrets.isNotEmpty ? severityColor(context, Severity.error) : null,
              ),
              child: _tls(context, data),
            ),
          if (def.isNotEmpty)
            InspectorSection(
              id: 'ing-default-backend',
              title: 'Default backend',
              initiallyExpanded: false,
              trailing: SectionSummary(
                defState.service == null ? 'resource' : '${defState.service}:${defState.portText}',
                color: defState.broken ? severityColor(context, Severity.error) : null,
              ),
              child: Padding(padding: const EdgeInsets.only(left: 4), child: _backend(context, def, data)),
            ),
          if (annotations.isNotEmpty)
            InspectorSection(
              id: 'ing-annotations',
              title: 'Controller annotations',
              initiallyExpanded: false,
              trailing: SectionSummary(annotations.keys.map((k) => k.substring(k.lastIndexOf('/') + 1)).join(' · ')),
              child: _annotations(context, annotations),
            ),
        ]);
      },
    );
  }

  Widget _header(BuildContext context, _IngressLookups? data, List<IngressPath> paths, List<String> missingSecrets, _BackendState defState, Object? error) {
    final spec = ctx.spec;
    final className = spec['ingressClassName'] as String?;
    final legacyClass = dig<String>(ctx.metadata, ['annotations', 'kubernetes.io/ingress.class']);
    final lb = asMapList(dig(ctx.status, ['loadBalancer', 'ingress']));
    final tlsHosts = ingressTlsHosts(spec);
    final ruleHosts = {for (final p in paths) if (p.host != null) p.host!};
    final covered = ruleHosts.where((h) => _tlsCovers(tlsHosts, h)).toList();
    final uncovered = ruleHosts.where((h) => !_tlsCovers(tlsHosts, h)).toList();
    final states = [for (final p in paths) (p, _resolveBackend(p.backend, data))];
    final missing = {for (final (_, s) in states) if (s.missing) s.service!, if (defState.missing) defState.service!};
    final badPorts = [for (final (p, s) in states) if (s.portBad && !s.missing) (p, s)];
    final routesNothing = paths.isEmpty && asMap(spec['defaultBackend']).isEmpty;
    final insights = <Insight>[
      if (routesNothing) const Insight(Severity.error, 'No rules and no default backend', 'This Ingress routes nothing.'),
      for (final m in missing) Insight(Severity.error, 'Service $m not found', 'Requests routed to it get an error from the controller.'),
      for (final (p, s) in badPorts) Insight(Severity.error, 'Service ${s.service} has no port ${s.portText}', 'Used by ${p.host ?? '*'}${p.path}.'),
      for (final s in missingSecrets) Insight(Severity.error, 'TLS Secret $s not found', 'The controller serves its default certificate instead.'),
      if (lb.isEmpty) Insight(Severity.warn, 'No address assigned', 'No ingress controller${className != null ? ' for class $className' : ''} has published an address yet.'),
      if (tlsHosts.isNotEmpty && uncovered.isNotEmpty) Insight(Severity.warn, '${uncovered.join(', ')} ${uncovered.length == 1 ? 'is' : 'are'} not covered by TLS', 'Served over plain HTTP only.'),
      if (error != null) Insight(Severity.warn, 'Lookup failed', '$error'),
    ];
    final worst = worstOf(insights);
    final headline = routesNothing
        ? 'Routes nothing'
        : missing.isNotEmpty || badPorts.isNotEmpty
            ? 'Backend missing'
            : lb.isEmpty
                ? 'No address yet'
                : 'Serving';
    final classLabel = className ?? (legacyClass != null ? '$legacyClass (legacy annotation)' : null);
    return InspectorHeader(
      mark: worst ?? (data == null ? Severity.neutral : Severity.ok),
      headline: headline,
      detail: [
        classLabel == null ? 'default class' : 'class $classLabel',
        if (ruleHosts.isNotEmpty) tlsHosts.isEmpty ? 'no TLS' : 'TLS on ${covered.length} of ${ruleHosts.length} hosts',
      ].join(' · '),
      figures: [
        InspectorFigure('${{for (final p in paths) p.host ?? '*'}.length}', 'hosts'),
        InspectorFigure('${paths.length}', paths.length == 1 ? 'path' : 'paths'),
        if (ruleHosts.isNotEmpty)
          InspectorFigure('${covered.length}', 'on TLS',
              of: '/${ruleHosts.length}', severity: tlsHosts.isNotEmpty && uncovered.isNotEmpty ? Severity.warn : Severity.neutral, tooltip: '${covered.length} of ${ruleHosts.length} hosts covered by TLS'),
        if (missing.isNotEmpty) InspectorFigure('${missing.length}', 'not found', severity: Severity.error, tooltip: 'Services that do not exist'),
      ],
      insights: insights,
      factsKeyWidth: 64, facts: [
        ?ownerFact(ctx.object),
        (
          'Class',
          className != null
              ? ResourceLink(ObjectRef(group: 'networking.k8s.io', kind: 'IngressClass', name: className), label: className)
              : legacyClass != null
                  ? Text('$legacyClass (legacy annotation)')
                  : const HintText('none: uses the cluster default IngressClass'),
        ),
        (
          'Address',
          lb.isEmpty
              ? Text('pending', style: TextStyle(color: severityColor(context, Severity.warn)))
              : InlineWrap([for (final i in lb) Chipish(text: '${i['ip'] ?? i['hostname'] ?? ''}', copyValue: '${i['ip'] ?? i['hostname'] ?? ''}')]),
        ),
      ],
    );
  }

  Widget _backend(BuildContext context, Json backend, _IngressLookups? data) {
    final theme = Theme.of(context);
    final svc = asMap(backend['service']);
    if (svc.isEmpty) {
      final res = asMap(backend['resource']);
      if (res.isEmpty) return const HintText('—');
      final group = '${res['apiGroup'] ?? ''}';
      return ResourceLink(ObjectRef(group: group, kind: '${res['kind']}', name: '${res['name']}', namespace: ctx.namespace));
    }
    final s = _resolveBackend(backend, data);
    final err = severityColor(context, Severity.error);
    final flag = theme.textTheme.bodySmall?.copyWith(color: err, fontWeight: FontWeight.w600);
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 2, children: [
      ResourceLink(ObjectRef(kind: 'Service', name: s.service!, namespace: ctx.namespace), label: s.service),
      Text(':${s.portText}', style: monoStyle(context, size: 11.5, color: s.portBad ? err : theme.hintColor)),
      if (s.missing) Text('missing', style: flag),
      if (s.portBad) Text('no such port', style: flag),
    ]);
  }

  Widget _rules(BuildContext context, _IngressLookups? data, List<IngressPath> paths) {
    if (paths.isEmpty) {
      return asMap(ctx.spec['defaultBackend']).isEmpty
          ? const InlineMessage('No rules and no default backend: this Ingress routes nothing.', isError: true)
          : const InlineMessage('No rules: all traffic goes to the default backend.');
    }
    final tlsHosts = ingressTlsHosts(ctx.spec);
    final byHost = <String?, List<IngressPath>>{};
    for (final p in paths) {
      byHost.putIfAbsent(p.host, () => []).add(p);
    }
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final e in byHost.entries) ...[
        _HostLabel(e.key, tls: e.key != null && _tlsCovers(tlsHosts, e.key!)),
        for (final p in [...e.value]..sort((a, b) => (_resolveBackend(b.backend, data).broken ? 1 : 0).compareTo(_resolveBackend(a.backend, data).broken ? 1 : 0)))
          () {
            final s = _resolveBackend(p.backend, data);
            return InspectorRow(
              key: ValueKey('ing-rule-${p.host}${p.path}'),
              dot: s.broken ? Severity.error : (data == null ? Severity.neutral : Severity.ok),
              title: Text.rich(TextSpan(children: [
                TextSpan(text: p.path, style: monoStyle(context, size: 12)),
                TextSpan(text: '  ${p.pathType}', style: TextStyle(color: Theme.of(context).hintColor, fontSize: 11)),
              ])),
              subtitle: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                const Text('→ '),
                Flexible(child: _backend(context, p.backend, data)),
              ]),
              actions: [RowAction(icon: Icons.link, tooltip: 'Copy ${p.url(tlsHosts)}', onTap: () => copyToClipboard(context, p.url(tlsHosts)))],
            );
          }(),
      ],
    ]);
  }

  Widget _tls(BuildContext context, _IngressLookups? data) {
    final ruleHosts = {for (final p in flattenIngressRules(ctx.spec)) if (p.host != null) p.host!};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final t in asMapList(ctx.spec['tls']))
        () {
          final name = t['secretName'] as String?;
          final missing = name != null && data?.secrets[name] == false;
          final hosts = [for (final h in (t['hosts'] as List? ?? const ['(all hosts)'])) '$h'];
          final unused = [for (final h in hosts) if (ruleHosts.isNotEmpty && !ruleHosts.contains(h) && !h.startsWith('*') && !h.startsWith('(')) h];
          return InspectorRow(
            dot: missing ? Severity.error : (unused.isNotEmpty ? Severity.warn : Severity.ok),
            title: name == null
                ? const HintText('no secret (controller default cert)')
                : Row(children: [
                    Flexible(child: ResourceLink(ObjectRef(kind: 'Secret', name: name, namespace: ctx.namespace), label: name, singleLine: true)),
                    if (missing) ...[
                      const SizedBox(width: 8),
                      Text('Secret not found', style: Theme.of(context).textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.error), fontWeight: FontWeight.w600)),
                    ],
                  ]),
            subtitle: dotLine([hosts.join(', '), if (unused.isNotEmpty) 'not used by any rule: ${unused.join(', ')}']),
          );
        }(),
    ]);
  }

  Widget _annotations(BuildContext context, Map<String, String> annotations) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final e in annotations.entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: e.key.substring(0, e.key.lastIndexOf('/') + 1), style: monoStyle(context, size: 11, color: theme.hintColor)),
              TextSpan(text: e.key.substring(e.key.lastIndexOf('/') + 1), style: monoStyle(context, size: 11, color: theme.colorScheme.onSurface).copyWith(fontWeight: FontWeight.w600)),
              TextSpan(text: ': ', style: monoStyle(context, size: 11, color: theme.hintColor)),
              TextSpan(text: e.value.length > 200 ? '${e.value.substring(0, 200)}…' : e.value, style: monoStyle(context, size: 11)),
            ]),
          ),
        ),
    ]);
  }
}

/// A host heading over its paths: a lock when TLS covers it, copy on hover.
class _HostLabel extends StatelessWidget {
  final String? host;
  final bool tls;
  const _HostLabel(this.host, {required this.tls});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final text = host ?? '* (any host)';
    return Hoverable(
      builder: (h) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 0, 2),
        child: Row(children: [
          Tooltip(message: tls ? 'Covered by TLS' : 'Plain HTTP', child: Icon(tls ? Icons.lock_outline : Icons.public, size: 12, color: theme.hintColor)),
          const SizedBox(width: 6),
          Flexible(child: Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600, color: theme.hintColor))),
          Opacity(opacity: h ? 1 : 0, child: copyAction(context, host ?? '*')),
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class IngressClassPanel extends ResourcePanel {
  const IngressClassPanel();

  @override
  Set<String> get kinds => {'networking.k8s.io/IngressClass'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final isDefault = dig<String>(ctx.metadata, ['annotations', 'ingressclass.kubernetes.io/is-default-class']) == 'true';
    final params = asMap(spec['parameters']);
    return [
      DetailSection(
        title: 'Ingress class',
        icon: Icons.input,
        trailing: isDefault ? const StatusBadge('Default class', dense: true, severity: Severity.ok) : null,
        child: KeyValueTable([
          ('Controller', spec['controller'] != null ? MonoText('${spec['controller']}', copy: true) : const HintText('not set')),
          ('Default', isDefault ? 'yes: Ingresses without ingressClassName use this class' : 'no'),
          (
            'Parameters',
            params.isEmpty
                ? null
                : Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
                    ResourceLink(
                      ObjectRef(
                        group: '${params['apiGroup'] ?? ''}',
                        kind: '${params['kind']}',
                        name: '${params['name']}',
                        namespace: params['scope'] == 'Namespace' ? params['namespace'] as String? : null,
                      ),
                      label: '${params['kind']}/${params['name']}',
                    ),
                    HintText([
                      if (params['apiGroup'] != null) '${params['apiGroup']}',
                      if (params['scope'] != null) 'scope ${params['scope']}',
                      if (params['namespace'] != null) 'ns ${params['namespace']}',
                    ].join(' · ')),
                  ]),
          ),
        ], keyWidth: 100),
      ),
      _IngressClassUsers(key: ValueKey('${ctx.uid}/users'), ctx: ctx, isDefault: isDefault),
    ];
  }
}

class _IngressClassUsers extends StatelessWidget {
  final PanelContext ctx;
  final bool isDefault;
  const _IngressClassUsers({super.key, required this.ctx, required this.isDefault});

  @override
  Widget build(BuildContext context) {
    return NetFetch<List<Json>>(
      fetchKey: ctx.name,
      load: () => ctx.api.items(const ResourceRef(group: 'networking.k8s.io', resource: 'ingresses')),
      builder: (context, snap, reload) {
        final all = snap.data ?? const <Json>[];
        final users = [
          for (final i in all)
            if (dig<String>(i, ['spec', 'ingressClassName']) == ctx.name ||
                dig<String>(i, ['metadata', 'annotations', 'kubernetes.io/ingress.class']) == ctx.name ||
                (isDefault && dig(i, ['spec', 'ingressClassName']) == null && dig(i, ['metadata', 'annotations', 'kubernetes.io/ingress.class']) == null))
              i,
        ];
        return DetailSection(
          title: 'Used by',
          icon: Icons.link,
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (snap.hasData) StatusBadge('${users.length}', dense: true, severity: Severity.info),
            RefreshButton(reload),
          ]),
          child: snap.hasError
              ? InlineMessage('${snap.error}', isError: true)
              : !snap.hasData
                  ? SectionSpinner()
                  : users.isEmpty
                      ? const InlineMessage('No Ingresses use this class')
                      : Wrap(spacing: 10, runSpacing: 4, children: [
                          for (final i in users)
                            ResourceLink(
                              ObjectRef(group: 'networking.k8s.io', kind: 'Ingress', name: '${dig(i, ['metadata', 'name'])}', namespace: dig(i, ['metadata', 'namespace'])),
                              label: '${dig(i, ['metadata', 'namespace'])}/${dig(i, ['metadata', 'name'])}',
                            ),
                        ]),
        );
      },
    );
  }
}
