/// Heuristic detection of object references inside arbitrary spec/status.
library;

import '../../api/models.dart';
import '../../state/app_state.dart';
import '../../util/k8s.dart';
import 'humanize.dart';

/// Field-name stems that name a well-known kind. Matched exactly or as a
/// suffix (`tlsSecret` → Secret). Longer stems first.
const _knownStems = <String, String>{
  'secretKey': 'Secret',
  'configMapKey': 'ConfigMap',
  'serviceAccount': 'ServiceAccount',
  'persistentVolumeClaim': 'PersistentVolumeClaim',
  'persistentVolume': 'PersistentVolume',
  'storageClass': 'StorageClass',
  'priorityClass': 'PriorityClass',
  'ingressClass': 'IngressClass',
  'runtimeClass': 'RuntimeClass',
  'configMap': 'ConfigMap',
  'secret': 'Secret',
  'service': 'Service',
  'claim': 'PersistentVolumeClaim',
  'node': 'Node',
  'pod': 'Pod',
  'volume': 'PersistentVolume',
  'deployment': 'Deployment',
  'statefulSet': 'StatefulSet',
};

const _objectRefKeys = {'apiVersion', 'apiGroup', 'kind', 'name', 'namespace', 'uid', 'resourceVersion', 'fieldPath'};

/// Resolves reference-looking fields to [ObjectRef]s. [namespace] is the
/// default namespace (the object's own).
class RefResolver {
  final AppState? app;
  final String? namespace;
  const RefResolver({this.app, this.namespace});

  static String? _kindForStem(String stem) {
    if (stem.isEmpty) return null;
    for (final e in _knownStems.entries) {
      if (stem == e.key || stem.endsWith(capitalize(e.key))) return e.value;
    }
    return null;
  }

  static String? _stem(String key, List<String> suffixes) {
    for (final s in suffixes) {
      if (key.length > s.length && key.endsWith(s)) return key.substring(0, key.length - s.length);
      if (key == s.toLowerCase()) return '';
    }
    return null;
  }

  /// Group for [kind]: explicit if given, else the discovered type (core preferred).
  String _group(String kind, Map m) {
    final av = m['apiVersion'];
    if (av is String && av.isNotEmpty) return av.contains('/') ? av.split('/').first : '';
    for (final k in const ['apiGroup', 'group']) {
      if (m[k] is String) return m[k] as String;
    }
    final types = app?.types ?? const <ResourceType>[];
    final matches = types.where((t) => t.kind == kind).toList();
    if (matches.isEmpty) return '';
    return matches.any((t) => t.group.isEmpty) ? '' : matches.first.group;
  }

  /// `fooRef: {name, kind?, apiVersion?, namespace?}` or an objectReference-shaped map.
  ObjectRef? fromMap(String key, Json m) {
    final name = m['name'];
    if (name is! String || name.isEmpty) return null;
    final stem = _stem(key, const ['Reference', 'Ref']);
    final refShaped = m.containsKey('kind') && m.keys.every(_objectRefKeys.contains);
    // `configMap: {name}`, `service: {name, port}` (volume sources, backends).
    final namedStem = _knownStems.containsKey(key) && !key.endsWith('Key');
    if (stem == null && !refShaped && !namedStem) return null;
    if (namedStem && stem == null && !refShaped) {
      return ObjectRef(group: _group(_knownStems[key]!, m), kind: _knownStems[key]!, name: name, namespace: (m['namespace'] as String?) ?? namespace);
    }
    final explicitKind = m['kind'] is String && (m['kind'] as String).isNotEmpty ? m['kind'] as String : null;
    final kind = explicitKind ?? _kindForStem(stem ?? '') ?? (stem == null || stem.isEmpty ? null : capitalize(stem));
    if (kind == null) return null;
    return ObjectRef(group: _group(kind, m), kind: kind, name: name, namespace: (m['namespace'] as String?) ?? namespace);
  }

  /// `secretName: foo`, `serviceAccountName: bar`, `claimName: data`, …
  ObjectRef? fromScalar(String key, dynamic v) {
    if (v is! String || v.isEmpty) return null;
    final stem = _stem(key, const ['Name']);
    if (stem == null) return null;
    final kind = _kindForStem(stem);
    if (kind == null) return null;
    return ObjectRef(group: _group(kind, const {}), kind: kind, name: v, namespace: namespace);
  }

  /// `parentRefs: [{name, kind}]`, `imagePullSecrets: [{name}]`, `secrets: [{name}]`.
  List<ObjectRef>? fromList(String key, List v) {
    if (v.isEmpty || v.any((e) => e is! Map || e['name'] is! String)) return null;
    final maps = asMapList(v);
    final stem = _stem(key, const ['References', 'Refs']);
    if (stem != null) {
      final refs = [for (final m in maps) fromMap('${stem}Ref', m)];
      return refs.every((r) => r != null) ? refs.cast<ObjectRef>() : null;
    }
    if (key.length > 1 && key.endsWith('s') && maps.every((m) => m.keys.every((k) => k == 'name' || k == 'namespace'))) {
      final kind = _kindForStem(key.substring(0, key.length - 1));
      if (kind == null) return null;
      return [
        for (final m in maps) ObjectRef(group: _group(kind, m), kind: kind, name: m['name'], namespace: (m['namespace'] as String?) ?? namespace),
      ];
    }
    return null;
  }

  /// Display label: `Kind/name`, with namespace when it differs from ours.
  String label(ObjectRef r) =>
      r.namespace != null && r.namespace != namespace ? '${r.kind}/${r.namespace}/${r.name}' : '${r.kind}/${r.name}';
}
