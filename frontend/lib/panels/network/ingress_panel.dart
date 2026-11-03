import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'widgets.dart';

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
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    return [_IngressView(key: ValueKey('${ctx.uid}/ingress'), ctx: ctx)];
  }
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
        return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          DetailSection(title: 'Ingress', icon: Icons.input, child: _summary(context, data)),
          DetailSection(
            title: 'Rules',
            icon: Icons.alt_route,
            trailing: RefreshButton(reload),
            child: _rules(context, data, snap.error),
          ),
          if (asMapList(spec['tls']).isNotEmpty) DetailSection(title: 'TLS', icon: Icons.lock_outline, child: _tls(context, data)),
          if (annotations.isNotEmpty)
            DetailSection(title: 'Controller annotations', icon: Icons.tune, child: _annotations(context, annotations)),
        ]);
      },
    );
  }

  Widget _summary(BuildContext context, _IngressLookups? data) {
    final spec = ctx.spec;
    final className = spec['ingressClassName'] as String?;
    final legacyClass = dig<String>(ctx.metadata, ['annotations', 'kubernetes.io/ingress.class']);
    final lb = asMapList(dig(ctx.status, ['loadBalancer', 'ingress']));
    final def = asMap(spec['defaultBackend']);
    return KeyValueTable([
      (
        'Class',
        className != null
            ? ResourceLink(ObjectRef(group: 'networking.k8s.io', kind: 'IngressClass', name: className), label: className)
            : legacyClass != null
                ? Text('$legacyClass (legacy annotation)', style: Theme.of(context).textTheme.bodySmall)
                : const Muted('none: uses the cluster default IngressClass'),
      ),
      (
        'Address',
        lb.isEmpty
            ? const Row(children: [StatusBadge('Pending', dense: true, severity: Severity.warn), SizedBox(width: 6), Expanded(child: Muted('no address assigned by a controller'))])
            : Wrap(spacing: 10, children: [for (final i in lb) CopyText('${i['ip'] ?? i['hostname'] ?? ''}')]),
      ),
      ('Default backend', def.isEmpty ? null : _backend(context, def, data)),
    ], keyWidth: 110);
  }

  Widget _backend(BuildContext context, Json backend, _IngressLookups? data) {
    final theme = Theme.of(context);
    final svc = asMap(backend['service']);
    if (svc.isEmpty) {
      final res = asMap(backend['resource']);
      if (res.isEmpty) return const Muted('—');
      final group = '${res['apiGroup'] ?? ''}';
      return ResourceLink(ObjectRef(group: group, kind: '${res['kind']}', name: '${res['name']}', namespace: ctx.namespace));
    }
    final name = '${svc['name']}';
    final port = asMap(svc['port']);
    final known = data != null && data.services.containsKey(name);
    final svcObj = data?.services[name];
    final missing = known && svcObj == null;
    String portText;
    var portBad = false;
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
    final err = severityColor(context, Severity.error);
    return Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 4, runSpacing: 2, children: [
      ResourceLink(ObjectRef(kind: 'Service', name: name, namespace: ctx.namespace), label: name),
      Text(':$portText', style: monoStyle(context, size: 11.5, color: portBad ? err : theme.hintColor)),
      if (missing) const StatusBadge('missing', dense: true, severity: Severity.error),
      if (portBad) const StatusBadge('no such port', dense: true, severity: Severity.error),
    ]);
  }

  Widget _rules(BuildContext context, _IngressLookups? data, Object? error) {
    final theme = Theme.of(context);
    final paths = flattenIngressRules(ctx.spec);
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
      if (error != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: InlineMessage('Lookup failed: $error', isError: true)),
      for (final e in byHost.entries) ...[
        Padding(
          padding: const EdgeInsets.only(top: 4, bottom: 2),
          child: Row(children: [
            Icon(e.key != null && _tlsCovers(tlsHosts, e.key!) ? Icons.lock : Icons.public, size: 14, color: theme.colorScheme.primary),
            const SizedBox(width: 6),
            Flexible(child: CopyText(e.key ?? '* (any host)', copyValue: e.key ?? '*')),
          ]),
        ),
        NetTable(
          headers: const ['Path', 'Type', 'Backend', ''],
          flex: const [1.2, null, 1.6, null],
          rows: [
            for (final p in e.value)
              [
                Mono(p.path),
                Muted(p.pathType),
                _backend(context, p.backend, data),
                IconButton(
                  iconSize: 13,
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(width: 22, height: 22),
          style: const ButtonStyle(tapTargetSize: MaterialTapTargetSize.shrinkWrap),
                  tooltip: 'Copy ${p.url(tlsHosts)}',
                  icon: const Icon(Icons.link),
                  onPressed: () => copyToClipboard(context, p.url(tlsHosts)),
                ),
              ],
          ],
        ),
        const SizedBox(height: 4),
      ],
    ]);
  }

  Widget _tls(BuildContext context, _IngressLookups? data) {
    final ruleHosts = {for (final p in flattenIngressRules(ctx.spec)) if (p.host != null) p.host!};
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final t in asMapList(ctx.spec['tls']))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: Wrap(spacing: 4, runSpacing: 4, children: [
                for (final h in (t['hosts'] as List? ?? const ['(all hosts)']))
                  Chipish(text: '$h', copyValue: '$h', color: ruleHosts.isEmpty || ruleHosts.contains('$h') || '$h'.startsWith('*') ? null : severityColor(context, Severity.warn)),
              ]),
            ),
            const Padding(padding: EdgeInsets.symmetric(horizontal: 6), child: Icon(Icons.arrow_forward, size: 13)),
            Expanded(child: _secret(context, t['secretName'] as String?, data)),
          ]),
        ),
    ]);
  }

  Widget _secret(BuildContext context, String? name, _IngressLookups? data) {
    if (name == null) return const Muted('no secret (controller default cert)');
    final exists = data?.secrets[name];
    return Wrap(spacing: 6, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
      ResourceLink(ObjectRef(kind: 'Secret', name: name, namespace: ctx.namespace), label: name),
      if (data != null && exists == false) const StatusBadge('Secret not found', dense: true, severity: Severity.error),
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
              TextSpan(text: e.key.substring(e.key.lastIndexOf('/') + 1), style: monoStyle(context, size: 11, color: theme.colorScheme.primary)),
              TextSpan(text: ': ', style: monoStyle(context, size: 11, color: theme.hintColor)),
              TextSpan(text: e.value.length > 200 ? '${e.value.substring(0, 200)}…' : e.value, style: monoStyle(context, size: 11)),
            ]),
          ),
        ),
    ]);
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
          ('Controller', spec['controller'] != null ? CopyText('${spec['controller']}') : const Muted('not set')),
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
                    Muted([
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
                  ? spinner
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
