/// Pure helpers that find how pods reference a ConfigMap or Secret.
library;

import '../../api/models.dart';
import '../../util/k8s.dart';

enum RefKind { configMap, secret }

enum UsageKind { volume, projected, env, envFrom, imagePullSecret }

/// One reference from a pod to the config object.
class ConfigUsage {
  final UsageKind kind;

  /// Container the usage applies to (null for unmounted volumes and
  /// imagePullSecrets).
  final String? container;
  final bool initContainer;
  final String? volume;
  final String? mountPath;
  final String? subPath;
  final bool readOnly;

  /// Env var name (env) or prefix (envFrom).
  final String? envName;

  /// Keys this usage needs: the env key, or the volume `items` keys.
  /// Empty for whole-object usages (envFrom, volume without items).
  final List<String> keys;
  final bool optional;

  const ConfigUsage({
    required this.kind,
    this.container,
    this.initContainer = false,
    this.volume,
    this.mountPath,
    this.subPath,
    this.readOnly = false,
    this.envName,
    this.keys = const [],
    this.optional = false,
  });

  /// Text segments; `true` marks code-ish parts (rendered monospace).
  List<(String, bool)> get segments {
    final c = container == null ? null : (initContainer ? '$container (init)' : container!);
    final keyNote = keys.isEmpty ? <(String, bool)>[] : [(' (keys: ', false), (keys.join(', '), true), (')', false)];
    switch (kind) {
      case UsageKind.volume:
      case UsageKind.projected:
        final label = kind == UsageKind.projected ? 'projected volume ' : 'volume ';
        return [
          (label, false),
          (volume ?? '?', true),
          if (mountPath != null) ...[(' → ', false), ('$c:$mountPath${subPath != null ? ' [subPath $subPath]' : ''}', true)] else (' (not mounted)', false),
          ...keyNote,
        ];
      case UsageKind.env:
        return [('env ', false), (envName ?? '?', true), (' ← key ', false), (keys.isEmpty ? '?' : keys.first, true), (' (container $c)', false)];
      case UsageKind.envFrom:
        return [
          ('envFrom', false),
          if (envName != null && envName!.isNotEmpty) ...[(' prefix ', false), (envName!, true)],
          (' → all keys as env (container $c)', false),
        ];
      case UsageKind.imagePullSecret:
        return [('imagePullSecrets', false)];
    }
  }

  String get description => segments.map((s) => s.$1).join();

  /// Stable signature (ignores the pod) used to group identical pods.
  String get signature => '$kind|$container|$initContainer|$volume|$mountPath|$subPath|$envName|${keys.join(',')}|$optional';
}

class PodUsage {
  final Json pod;
  final List<ConfigUsage> usages;
  const PodUsage(this.pod, this.usages);

  String get name => dig<String>(pod, ['metadata', 'name']) ?? '';
  String? get namespace => dig<String>(pod, ['metadata', 'namespace']);
  ObjectRef get ref => ObjectRef(kind: 'Pod', name: name, namespace: namespace);
  String get signature => usages.map((u) => u.signature).join(';');
}

List<(Json, bool)> _containers(Json spec) => [
      for (final c in asMapList(spec['initContainers'])) (c, true),
      for (final c in asMapList(spec['containers'])) (c, false),
      for (final c in asMapList(spec['ephemeralContainers'])) (c, false),
    ];

List<String> _itemKeys(Json source) => [for (final i in asMapList(source['items'])) if (i['key'] is String) i['key'] as String];

/// Finds every reference to the ConfigMap/Secret [name] in [pods].
/// Pods without any reference are omitted. Only pods in [namespace] are
/// considered when it is given.
List<PodUsage> findUsages(List<Json> pods, {required RefKind kind, required String name, String? namespace}) {
  final out = <PodUsage>[];
  final volKey = kind == RefKind.configMap ? 'configMap' : 'secret';
  final volNameKey = kind == RefKind.configMap ? 'name' : 'secretName';
  final keyRef = kind == RefKind.configMap ? 'configMapKeyRef' : 'secretKeyRef';
  final fromRef = kind == RefKind.configMap ? 'configMapRef' : 'secretRef';

  for (final pod in pods) {
    if (namespace != null && dig<String>(pod, ['metadata', 'namespace']) != namespace) continue;
    final spec = asMap(pod['spec']);
    final containers = _containers(spec);
    final usages = <ConfigUsage>[];

    // Volumes (direct and projected) → their mounts.
    for (final v in asMapList(spec['volumes'])) {
      final vname = '${v['name'] ?? ''}';
      final matches = <(UsageKind, List<String>, bool)>[];
      final direct = asMap(v[volKey]);
      if (direct.isNotEmpty && direct[volNameKey] == name) {
        matches.add((UsageKind.volume, _itemKeys(direct), direct['optional'] == true));
      }
      for (final src in asMapList(asMap(v['projected'])['sources'])) {
        final s = asMap(src[volKey]);
        if (s.isNotEmpty && s['name'] == name) matches.add((UsageKind.projected, _itemKeys(s), s['optional'] == true));
      }
      for (final (uk, keys, optional) in matches) {
        var mounted = false;
        for (final (c, init) in containers) {
          for (final m in asMapList(c['volumeMounts'])) {
            if (m['name'] != vname) continue;
            mounted = true;
            usages.add(ConfigUsage(
              kind: uk,
              container: '${c['name']}',
              initContainer: init,
              volume: vname,
              mountPath: m['mountPath'] as String?,
              subPath: (m['subPath'] as String?)?.isEmpty ?? true ? null : m['subPath'] as String,
              readOnly: m['readOnly'] == true,
              keys: keys,
              optional: optional,
            ));
          }
        }
        if (!mounted) usages.add(ConfigUsage(kind: uk, volume: vname, keys: keys, optional: optional));
      }
    }

    // Env and envFrom.
    for (final (c, init) in containers) {
      final cname = '${c['name']}';
      for (final e in asMapList(c['env'])) {
        final r = asMap(dig(e, ['valueFrom', keyRef]));
        if (r.isNotEmpty && r['name'] == name) {
          usages.add(ConfigUsage(
            kind: UsageKind.env,
            container: cname,
            initContainer: init,
            envName: '${e['name']}',
            keys: [if (r['key'] is String) r['key'] as String],
            optional: r['optional'] == true,
          ));
        }
      }
      for (final ef in asMapList(c['envFrom'])) {
        final r = asMap(ef[fromRef]);
        if (r.isNotEmpty && r['name'] == name) {
          usages.add(ConfigUsage(
            kind: UsageKind.envFrom,
            container: cname,
            initContainer: init,
            envName: ef['prefix'] as String?,
            optional: r['optional'] == true,
          ));
        }
      }
    }

    if (kind == RefKind.secret) {
      for (final s in asMapList(spec['imagePullSecrets'])) {
        if (s['name'] == name) usages.add(const ConfigUsage(kind: UsageKind.imagePullSecret));
      }
    }

    if (usages.isNotEmpty) out.add(PodUsage(pod, usages));
  }
  out.sort((a, b) => a.name.compareTo(b.name));
  return out;
}

/// A key referenced by some pod that the object does not contain.
class MissingKey {
  final String key;

  /// True when every reference to it is optional (pod still starts).
  final bool allOptional;
  final List<String> pods;
  const MissingKey(this.key, this.allOptional, this.pods);
}

List<MissingKey> missingKeys(List<PodUsage> usages, Set<String> existing) {
  final optional = <String, bool>{};
  final pods = <String, Set<String>>{};
  for (final pu in usages) {
    for (final u in pu.usages) {
      for (final k in u.keys) {
        if (existing.contains(k)) continue;
        optional[k] = (optional[k] ?? true) && u.optional;
        (pods[k] ??= {}).add(pu.name);
      }
    }
  }
  final keys = optional.keys.toList()..sort();
  return [for (final k in keys) MissingKey(k, optional[k]!, pods[k]!.toList()..sort())];
}

/// Groups pods whose usages are identical (e.g. replicas of a Deployment).
List<List<PodUsage>> groupIdentical(List<PodUsage> usages) {
  final groups = <String, List<PodUsage>>{};
  for (final u in usages) {
    (groups[u.signature] ??= []).add(u);
  }
  return groups.values.toList();
}
