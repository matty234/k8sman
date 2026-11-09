import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets/common.dart';
import '../../../util/k8s.dart';
import '../../pod/pod_containers.dart' show TemplateContainers;
import 'util.dart';

/// Summary of a pod template (`spec.template`): its containers as the pod
/// inspector's rows (without live state), then service account, node
/// selector, tolerations, volumes and config references.
class PodTemplateSummary extends StatelessWidget {
  final Json template;
  final String? namespace;

  /// Hide scheduling rows when the panel already shows them elsewhere.
  final bool showScheduling;

  /// Keys which container rows are open for the session (the workload's uid).
  final String memoryKey;
  const PodTemplateSummary({super.key, required this.template, required this.namespace, required this.memoryKey, this.showScheduling = true});

  @override
  Widget build(BuildContext context) {
    final spec = asMap(template['spec']);
    final sa = (spec['serviceAccountName'] ?? spec['serviceAccount']) as String?;
    final volumes = asMapList(spec['volumes']);
    final configRefs = _configRefs(spec, namespace);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TemplateContainers(template: template, namespace: namespace, memoryKey: memoryKey),
        const SizedBox(height: 10),
        KeyValueTable([
          (
            'Service account',
            sa == null
                ? 'default'
                : ResourceLink(
                    ObjectRef(kind: 'ServiceAccount', name: sa, namespace: namespace),
                    label: sa,
                  ),
          ),
          if (showScheduling) ...schedulingEntries(spec),
          if (spec['priorityClassName'] != null) ('Priority class', '${spec['priorityClassName']}'),
          if (spec['hostNetwork'] == true) ('Host network', StatusBadge('hostNetwork', severity: Severity.warn, dense: true)),
          if (volumes.isNotEmpty) ('Volumes', _Volumes(volumes, namespace)),
          if (configRefs.isNotEmpty) ('Config refs', Wrap(spacing: 10, runSpacing: 2, children: [for (final r in configRefs) ResourceLink(r)])),
        ], keyWidth: 110),
      ],
    );
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

class _Volumes extends StatelessWidget {
  final List<Json> volumes;
  final String? namespace;
  const _Volumes(this.volumes, this.namespace);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hint = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final v in volumes)
          Padding(
            padding: const EdgeInsets.only(bottom: 2),
            child: Wrap(
              crossAxisAlignment: WrapCrossAlignment.center,
              spacing: 6,
              children: [
                Text('${v['name']}', style: monoStyle(context, size: 11)),
                ..._source(v, hint),
              ],
            ),
          ),
      ],
    );
  }

  List<Widget> _source(Json v, TextStyle? hint) {
    ObjectRef ref(String kind, dynamic name) => ObjectRef(kind: kind, name: '$name', namespace: namespace);
    if (v['configMap'] is Map) {
      return [
        Text('ConfigMap', style: hint),
        ResourceLink(ref('ConfigMap', dig(v, ['configMap', 'name'])), label: '${dig(v, ['configMap', 'name'])}'),
      ];
    }
    if (v['secret'] is Map) {
      return [
        Text('Secret', style: hint),
        ResourceLink(ref('Secret', dig(v, ['secret', 'secretName'])), label: '${dig(v, ['secret', 'secretName'])}'),
      ];
    }
    if (v['persistentVolumeClaim'] is Map) {
      final n = dig(v, ['persistentVolumeClaim', 'claimName']);
      return [Text('PVC', style: hint), ResourceLink(ref('PersistentVolumeClaim', n), label: '$n')];
    }
    if (v['emptyDir'] is Map) {
      final m = asMap(v['emptyDir']);
      return [Text('emptyDir${m['medium'] != null ? ' (${m['medium']})' : ''}${m['sizeLimit'] != null ? ' ≤${m['sizeLimit']}' : ''}', style: hint)];
    }
    if (v['hostPath'] is Map) {
      return [
        Text('hostPath ${dig(v, ['hostPath', 'path'])}', style: hint),
      ];
    }
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
