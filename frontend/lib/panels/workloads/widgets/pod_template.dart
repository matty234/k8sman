import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets/common.dart';
import '../../../util/k8s.dart';
import 'util.dart';

/// Summary of a pod template (`spec.template`): containers with copyable
/// images, ports, resources, command and probes; then service account,
/// node selector, tolerations, volumes and config references.
class PodTemplateSummary extends StatelessWidget {
  final Json template;
  final String? namespace;

  /// Hide scheduling rows when the panel already shows them elsewhere.
  final bool showScheduling;
  const PodTemplateSummary({super.key, required this.template, required this.namespace, this.showScheduling = true});

  @override
  Widget build(BuildContext context) {
    final spec = asMap(template['spec']);
    final inits = asMapList(spec['initContainers']);
    final containers = asMapList(spec['containers']);
    final sa = (spec['serviceAccountName'] ?? spec['serviceAccount']) as String?;
    final volumes = asMapList(spec['volumes']);
    final configRefs = _configRefs(spec, namespace);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final c in inits) _ContainerCard(c, init: true),
      for (final c in containers) _ContainerCard(c),
      const SizedBox(height: 4),
      KeyValueTable([
        ('Service account', sa == null ? 'default' : ResourceLink(ObjectRef(kind: 'ServiceAccount', name: sa, namespace: namespace), label: sa)),
        if (showScheduling) ...schedulingEntries(spec),
        if (spec['priorityClassName'] != null) ('Priority class', '${spec['priorityClassName']}'),
        if (spec['hostNetwork'] == true) ('Host network', StatusBadge('hostNetwork', severity: Severity.warn, dense: true)),
        if (volumes.isNotEmpty) ('Volumes', _Volumes(volumes, namespace)),
        if (configRefs.isNotEmpty)
          (
            'Config refs',
            Wrap(spacing: 10, runSpacing: 2, children: [
              for (final r in configRefs) ResourceLink(r),
            ])
          ),
      ], keyWidth: 110),
    ]);
  }

  /// nodeSelector / tolerations / affinity rows.
  static List<(String, Object?)> schedulingEntries(Json spec) {
    final ns = asMap(spec['nodeSelector']);
    final tols = asMapList(spec['tolerations']);
    final aff = asMap(spec['affinity']);
    return [
      if (ns.isNotEmpty) ('Node selector', LabelChips(ns)),
      if (tols.isNotEmpty) ('Tolerations', Wrap(spacing: 4, runSpacing: 4, children: [for (final t in tols) Chipish(text: formatToleration(t))])),
      if (aff.isNotEmpty) ('Affinity', Text(aff.keys.join(', '))),
    ];
  }

  /// ConfigMaps/Secrets referenced by env, envFrom and volumes (deduped).
  static List<ObjectRef> _configRefs(Json spec, String? namespace) {
    final seen = <String>{};
    final out = <ObjectRef>[];
    void add(String kind, dynamic name) {
      if (name is! String || !seen.add('$kind/$name')) return;
      out.add(ObjectRef(kind: kind, name: name, namespace: namespace));
    }

    for (final c in [...asMapList(spec['initContainers']), ...asMapList(spec['containers'])]) {
      for (final e in asMapList(c['env'])) {
        add('ConfigMap', dig(e, ['valueFrom', 'configMapKeyRef', 'name']));
        add('Secret', dig(e, ['valueFrom', 'secretKeyRef', 'name']));
      }
      for (final e in asMapList(c['envFrom'])) {
        add('ConfigMap', dig(e, ['configMapRef', 'name']));
        add('Secret', dig(e, ['secretRef', 'name']));
      }
    }
    for (final s in asMapList(spec['imagePullSecrets'])) {
      add('Secret', s['name']);
    }
    return out;
  }
}

class _ContainerCard extends StatelessWidget {
  final Json c;
  final bool init;
  const _ContainerCard(this.c, {this.init = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final small = theme.textTheme.bodySmall;
    final hint = small?.copyWith(color: theme.hintColor);
    final ports = asMapList(c['ports']);
    final res = asMap(c['resources']);
    final cmd = [...?(c['command'] as List?), ...?(c['args'] as List?)].map((e) => '$e').toList();
    final mounts = asMapList(c['volumeMounts']);
    final probes = <String>[
      for (final p in const ['startup', 'liveness', 'readiness'])
        if (c['${p}Probe'] is Map) '$p ${_probe(asMap(c['${p}Probe']))}',
    ];
    final restartAlways = init && c['restartPolicy'] == 'Always';

    Widget line(String label, Widget child) => Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(width: 64, child: Text(label, style: hint)),
            Expanded(child: child),
          ]),
        );

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: init ? theme.hintColor : theme.colorScheme.primary, width: 2)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('${c['name']}', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          if (init) ...[
            const SizedBox(width: 6),
            StatusBadge(restartAlways ? 'sidecar' : 'init', severity: Severity.neutral, dense: true),
          ],
          const SizedBox(width: 8),
          Flexible(child: Align(alignment: Alignment.centerRight, child: ImageChip('${c['image'] ?? ''}'))),
        ]),
        if (ports.isNotEmpty)
          line(
              'ports',
              Wrap(spacing: 4, runSpacing: 2, children: [
                for (final p in ports)
                  Chipish(text: '${p['name'] != null ? '${p['name']} ' : ''}${p['containerPort']}/${p['protocol'] ?? 'TCP'}'),
              ])),
        line('resources', _resources(context, res)),
        if (cmd.isNotEmpty)
          line(
              'command',
              Tooltip(
                message: cmd.join(' '),
                child: Text(cmd.map(_shellQuote).join(' '), maxLines: 2, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11)),
              )),
        if (probes.isNotEmpty) line('probes', Text(probes.join(' · '), style: small)),
        if (mounts.isNotEmpty)
          line(
              'mounts',
              Text(
                mounts.map((m) => '${m['name']}→${m['mountPath']}${m['readOnly'] == true ? ' (ro)' : ''}').join('  '),
                style: monoStyle(context, size: 11),
              )),
      ]),
    );
  }

  static String _shellQuote(String s) => s.contains(RegExp(r'''[\s"'$;|&]''')) ? "'${s.replaceAll("'", r"'\''")}'" : s;

  static String _probe(Json p) {
    String target;
    if (p['httpGet'] is Map) {
      final h = asMap(p['httpGet']);
      target = 'GET ${h['path'] ?? '/'}:${h['port']}';
    } else if (p['tcpSocket'] is Map) {
      target = 'tcp:${dig(p, ['tcpSocket', 'port'])}';
    } else if (p['grpc'] is Map) {
      target = 'grpc:${dig(p, ['grpc', 'port'])}';
    } else if (p['exec'] is Map) {
      target = 'exec';
    } else {
      target = '?';
    }
    final period = p['periodSeconds'];
    return period != null ? '$target /${period}s' : target;
  }

  Widget _resources(BuildContext context, Json res) {
    final theme = Theme.of(context);
    final req = asMap(res['requests']);
    final lim = asMap(res['limits']);
    if (req.isEmpty && lim.isEmpty) {
      return Text('none set', style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, Severity.warn)));
    }
    final keys = <String>{...req.keys, ...lim.keys};
    final spans = <InlineSpan>[];
    for (final k in keys) {
      if (spans.isNotEmpty) spans.add(const TextSpan(text: '   '));
      spans.add(TextSpan(text: '$k ', style: TextStyle(color: theme.hintColor)));
      spans.add(TextSpan(text: '${req[k] ?? '–'}'));
      spans.add(TextSpan(text: ' / ', style: TextStyle(color: theme.hintColor)));
      spans.add(TextSpan(
        text: '${lim[k] ?? 'no limit'}',
        style: lim[k] == null ? TextStyle(color: theme.hintColor, fontStyle: FontStyle.italic) : null,
      ));
    }
    return Tooltip(
      message: 'requests / limits',
      child: Text.rich(TextSpan(children: spans), style: monoStyle(context, size: 11)),
    );
  }
}

class _Volumes extends StatelessWidget {
  final List<Json> volumes;
  final String? namespace;
  const _Volumes(this.volumes, this.namespace);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final v in volumes)
        Padding(
          padding: const EdgeInsets.only(bottom: 2),
          child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 6, children: [
            Text('${v['name']}', style: monoStyle(context, size: 11)),
            ..._source(v, hint),
          ]),
        ),
    ]);
  }

  List<Widget> _source(Json v, TextStyle? hint) {
    ObjectRef ref(String kind, dynamic name) => ObjectRef(kind: kind, name: '$name', namespace: namespace);
    if (v['configMap'] is Map) {
      return [Text('ConfigMap', style: hint), ResourceLink(ref('ConfigMap', dig(v, ['configMap', 'name'])), label: '${dig(v, ['configMap', 'name'])}')];
    }
    if (v['secret'] is Map) {
      return [Text('Secret', style: hint), ResourceLink(ref('Secret', dig(v, ['secret', 'secretName'])), label: '${dig(v, ['secret', 'secretName'])}')];
    }
    if (v['persistentVolumeClaim'] is Map) {
      final n = dig(v, ['persistentVolumeClaim', 'claimName']);
      return [Text('PVC', style: hint), ResourceLink(ref('PersistentVolumeClaim', n), label: '$n')];
    }
    if (v['emptyDir'] is Map) {
      final m = asMap(v['emptyDir']);
      return [Text('emptyDir${m['medium'] != null ? ' (${m['medium']})' : ''}${m['sizeLimit'] != null ? ' ≤${m['sizeLimit']}' : ''}', style: hint)];
    }
    if (v['hostPath'] is Map) return [Text('hostPath ${dig(v, ['hostPath', 'path'])}', style: hint)];
    if (v['projected'] is Map) {
      final srcs = asMapList(dig(v, ['projected', 'sources']));
      return [Text('projected (${srcs.map((s) => s.keys.join()).join(', ')})', style: hint)];
    }
    if (v['downwardAPI'] is Map) return [Text('downwardAPI', style: hint)];
    if (v['ephemeral'] is Map) return [Text('ephemeral PVC', style: hint)];
    final other = v.keys.where((k) => k != 'name').join(', ');
    return [Text(other, style: hint)];
  }
}
