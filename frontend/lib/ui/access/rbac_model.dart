/// Pure helpers for the Access workspace: a small YAML emitter for previews,
/// editable rule models, role templates and binding construction.
library;

import '../../api/known_apis.dart';
import '../../api/models.dart';
import '../../util/k8s.dart';
import 'access_api.dart';

/// The verbs offered as toggles, in matrix order.
const standardVerbs = ['get', 'list', 'watch', 'create', 'update', 'patch', 'delete', 'deletecollection'];
const specialVerbs = ['escalate', 'bind', 'impersonate', 'use', 'approve', 'sign'];
const readVerbs = ['get', 'list', 'watch'];
const writeVerbs = ['create', 'update', 'patch', 'delete', 'deletecollection'];

/// Short column labels for narrow matrices.
String verbAbbrev(String v) => switch (v) {
      'get' => 'get',
      'list' => 'list',
      'watch' => 'wtch',
      'create' => 'crt',
      'update' => 'upd',
      'patch' => 'ptch',
      'delete' => 'del',
      'deletecollection' => 'dcol',
      'escalate' => 'esc',
      'bind' => 'bind',
      'impersonate' => 'imp',
      _ => v.length > 4 ? v.substring(0, 4) : v,
    };

// ---------------------------------------------------------------------------
// YAML
// ---------------------------------------------------------------------------

final _plain = RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_./@-]*$');
const _reserved = {'true', 'false', 'yes', 'no', 'on', 'off', 'null', 'y', 'n', '~'};

String _scalar(Object? v) {
  if (v == null) return 'null';
  if (v is bool || v is num) return '$v';
  final s = '$v';
  if (_plain.hasMatch(s) && !_reserved.contains(s.toLowerCase()) && num.tryParse(s) == null) return s;
  return '"${s.replaceAll(r'\', r'\\').replaceAll('"', r'\"')}"';
}

/// Block-style YAML for JSON-like maps/lists (for previews; the backend
/// receives JSON).
String toYaml(Object? v, [int indent = 0]) {
  final b = StringBuffer();
  _emit(b, v, indent);
  return b.toString();
}

void _emit(StringBuffer b, Object? v, int indent) {
  final pad = ' ' * indent;
  if (v is Map) {
    if (v.isEmpty) {
      b.write('$pad{}\n');
      return;
    }
    for (final e in v.entries) {
      final val = e.value;
      if (val is Map && val.isNotEmpty) {
        b.write('$pad${e.key}:\n');
        _emit(b, val, indent + 2);
      } else if (val is List && val.isNotEmpty) {
        b.write('$pad${e.key}:\n');
        _emit(b, val, indent);
      } else {
        b.write('$pad${e.key}: ${val is Map ? '{}' : val is List ? '[]' : _scalar(val)}\n');
      }
    }
  } else if (v is List) {
    for (final item in v) {
      if (item is Map && item.isNotEmpty) {
        final inner = StringBuffer();
        _emit(inner, item, indent + 2);
        final text = inner.toString();
        b.write('$pad- ${text.substring(indent + 2)}');
      } else if (item is List && item.isNotEmpty) {
        b.write('$pad-\n');
        _emit(b, item, indent + 2);
      } else {
        b.write('$pad- ${_scalar(item)}\n');
      }
    }
  } else {
    b.write('$pad${_scalar(v)}\n');
  }
}

// ---------------------------------------------------------------------------
// Editable rules
// ---------------------------------------------------------------------------

/// A mutable PolicyRule for the structured editor.
class EditableRule {
  List<String> apiGroups;
  List<String> resources;
  List<String> verbs;
  List<String> resourceNames;
  List<String> nonResourceURLs;

  /// A nonResourceURLs rule (ClusterRoles only) rather than a resource rule.
  final bool isNonResource;
  EditableRule({List<String>? apiGroups, List<String>? resources, List<String>? verbs, List<String>? resourceNames, List<String>? nonResourceURLs})
      : apiGroups = apiGroups ?? [''],
        resources = resources ?? [],
        verbs = verbs ?? [...readVerbs],
        resourceNames = resourceNames ?? [],
        nonResourceURLs = nonResourceURLs ?? [],
        isNonResource = nonResourceURLs?.isNotEmpty ?? false;

  factory EditableRule.fromJson(Json j) => EditableRule(
        apiGroups: [for (final g in asList(j['apiGroups'])) '$g'],
        resources: [for (final r in asList(j['resources'])) '$r'],
        verbs: [for (final v in asList(j['verbs'])) '$v'],
        resourceNames: [for (final n in asList(j['resourceNames'])) '$n'],
        nonResourceURLs: [for (final u in asList(j['nonResourceURLs'])) '$u'],
      );

  EditableRule copy() => EditableRule(
      apiGroups: [...apiGroups], resources: [...resources], verbs: [...verbs], resourceNames: [...resourceNames], nonResourceURLs: [...nonResourceURLs]);

  Json toJson() => isNonResource
      ? {'nonResourceURLs': nonResourceURLs, 'verbs': verbs}
      : {
          'apiGroups': apiGroups,
          'resources': resources,
          if (resourceNames.isNotEmpty) 'resourceNames': resourceNames,
          'verbs': verbs,
        };

  /// Problems that would make the API server reject (or the rule useless).
  List<String> problems({required bool clusterRole}) => [
        if (verbs.isEmpty) 'no verbs',
        if (isNonResource && !clusterRole) 'nonResourceURLs only work in a ClusterRole',
        if (isNonResource && nonResourceURLs.isEmpty) 'no URLs',
        if (!isNonResource && resources.isEmpty) 'no resources',
        if (!isNonResource && apiGroups.isEmpty) 'no API groups',
        if (resourceNames.isNotEmpty && verbs.any((v) => v == 'list' || v == 'watch' || v == 'create' || v == 'deletecollection'))
          'resourceNames can\'t restrict list, watch, create or deletecollection',
      ];
}

List<dynamic> asList(dynamic v) => v is List ? v : const [];

/// Dangerous things a rule grants (short labels).
List<String> editableRuleDangers(EditableRule r) {
  final out = <String>[];
  bool g(String x) => r.apiGroups.contains(x) || r.apiGroups.contains('*');
  bool res(String x) => r.resources.contains(x) || r.resources.contains('*');
  bool v(String x) => r.verbs.contains(x) || r.verbs.contains('*');
  if (r.verbs.contains('*') && r.resources.contains('*') && r.apiGroups.contains('*')) return ['everything (cluster-admin equivalent)'];
  if (g('') && res('secrets') && (v('get') || v('list') || v('watch'))) out.add('reads Secrets');
  if (g('') && (res('pods/exec') || res('pods/attach')) && (v('create') || v('get'))) out.add('exec into pods');
  if (g('') && res('nodes/proxy') && (v('get') || v('create'))) out.add('kubelet API (nodes/proxy)');
  if (g(rbacApiGroup) && (v('escalate') || v('bind'))) out.add('escalate/bind roles');
  if (v('impersonate')) out.add('impersonation');
  if (g(rbacApiGroup) && (v('create') || v('update') || v('patch')) && (res('roles') || res('clusterroles') || res('rolebindings') || res('clusterrolebindings'))) {
    out.add('changes RBAC');
  }
  if (g('') && res('serviceaccounts/token') && v('create')) out.add('mints tokens');
  return out;
}

// ---------------------------------------------------------------------------
// Templates
// ---------------------------------------------------------------------------

class RoleTemplate {
  final String id;
  final String label;
  final String description;
  final List<EditableRule> Function() rules;
  const RoleTemplate(this.id, this.label, this.description, this.rules);
}

final roleTemplates = <RoleTemplate>[
  RoleTemplate('read-only', 'Read-only', 'Get, list and watch common workload, config and network objects; no Secrets.', () => [
        EditableRule(apiGroups: [''], resources: ['pods', 'pods/log', 'services', 'endpoints', 'configmaps', 'persistentvolumeclaims', 'events', 'serviceaccounts'], verbs: [...readVerbs]),
        EditableRule(apiGroups: ['apps'], resources: ['deployments', 'statefulsets', 'daemonsets', 'replicasets'], verbs: [...readVerbs]),
        EditableRule(apiGroups: ['batch'], resources: ['jobs', 'cronjobs'], verbs: [...readVerbs]),
        EditableRule(apiGroups: ['networking.k8s.io'], resources: ['ingresses', 'networkpolicies'], verbs: [...readVerbs]),
      ]),
  RoleTemplate('namespace-admin', 'Namespace admin', 'Everything inside a namespace, including Roles and RoleBindings (bind it with a RoleBinding).', () => [
        EditableRule(apiGroups: ['', 'apps', 'batch', 'autoscaling', 'networking.k8s.io', 'policy'], resources: ['*'], verbs: ['*']),
        EditableRule(apiGroups: [rbacApiGroup], resources: ['roles', 'rolebindings'], verbs: ['*']),
      ]),
  RoleTemplate('ci-deployer', 'CI deployer', 'Roll out Deployments and their config; read pods and logs to watch the rollout. No Secrets read, no exec.', () => [
        EditableRule(apiGroups: ['apps'], resources: ['deployments', 'statefulsets', 'daemonsets'], verbs: ['get', 'list', 'watch', 'create', 'update', 'patch']),
        EditableRule(apiGroups: [''], resources: ['services', 'configmaps'], verbs: ['get', 'list', 'watch', 'create', 'update', 'patch']),
        EditableRule(apiGroups: [''], resources: ['secrets'], verbs: ['create', 'update', 'patch']),
        EditableRule(apiGroups: [''], resources: ['pods', 'pods/log', 'events'], verbs: [...readVerbs]),
      ]),
  RoleTemplate('debugger', 'Debugger', 'Read pods and logs, exec, port-forward and add ephemeral containers.', () => [
        EditableRule(apiGroups: [''], resources: ['pods', 'pods/log', 'events'], verbs: [...readVerbs]),
        EditableRule(apiGroups: [''], resources: ['pods/exec', 'pods/portforward', 'pods/attach'], verbs: ['create', 'get']),
        EditableRule(apiGroups: [''], resources: ['pods/ephemeralcontainers'], verbs: ['patch', 'update']),
      ]),
  RoleTemplate('secret-reader', 'Read one Secret', 'Get a single named Secret (fill in the name).', () => [
        EditableRule(apiGroups: [''], resources: ['secrets'], verbs: ['get'], resourceNames: ['my-secret']),
      ]),
  RoleTemplate('metrics', 'Metrics reader', 'Read pod and node metrics (metrics-server).', () => [
        EditableRule(apiGroups: ['metrics.k8s.io'], resources: ['pods', 'nodes'], verbs: ['get', 'list']),
      ]),
];

// ---------------------------------------------------------------------------
// Objects
// ---------------------------------------------------------------------------

/// A Role or ClusterRole object. Keeps [base]'s metadata (labels,
/// annotations, resourceVersion) and aggregationRule when editing.
Json buildRole({required bool cluster, required String name, String? namespace, required List<EditableRule> rules, Json? base}) {
  final meta = Map<String, dynamic>.from(asMap(base?['metadata']));
  for (final k in ['managedFields', 'uid', 'creationTimestamp', 'generation', 'selfLink']) {
    meta.remove(k);
  }
  meta['name'] = name;
  if (cluster) {
    meta.remove('namespace');
  } else {
    meta['namespace'] = namespace;
  }
  final ordered = <String, dynamic>{'name': meta.remove('name'), if (meta.containsKey('namespace')) 'namespace': meta.remove('namespace'), ...meta};
  return {
    'apiVersion': rbacApiVersion,
    'kind': cluster ? 'ClusterRole' : 'Role',
    'metadata': ordered,
    if (base?['aggregationRule'] != null) 'aggregationRule': base!['aggregationRule'],
    'rules': [for (final r in rules) r.toJson()],
  };
}

/// A RoleBinding (namespace set) or ClusterRoleBinding granting [roleKind]
/// [roleName] to [subjects].
Json buildBinding({required String name, String? namespace, required String roleKind, required String roleName, required List<Json> subjects}) => {
      'apiVersion': rbacApiVersion,
      'kind': namespace == null ? 'ClusterRoleBinding' : 'RoleBinding',
      'metadata': {'name': name, 'namespace': ?namespace},
      'roleRef': {'apiGroup': rbacApiGroup, 'kind': roleKind, 'name': roleName},
      'subjects': subjects,
    };

/// A DNS-1123-ish binding name: `role-subject`.
String suggestBindingName(String roleName, RbacSubject s) {
  final raw = '$roleName-${s.name}'.toLowerCase().replaceAll(RegExp(r'[^a-z0-9.-]+'), '-').replaceAll(RegExp(r'-+'), '-');
  final trimmed = raw.replaceAll(RegExp(r'^[-.]+|[-.]+$'), '');
  return trimmed.length > 63 ? trimmed.substring(0, 63).replaceAll(RegExp(r'[-.]+$'), '') : trimmed;
}

/// Whether a binding subject JSON names [s] (ServiceAccount namespace
/// defaults to the binding's).
bool subjectMatches(Json subj, RbacSubject s, {String? bindingNamespace}) {
  if ('${subj['kind']}' != s.kind || '${subj['name']}' != s.name) return false;
  if (!s.isServiceAccount) return true;
  final ns = (subj['namespace'] as String?)?.isNotEmpty == true ? subj['namespace'] as String : bindingNamespace;
  return ns == s.namespace;
}

/// [binding] without [s] among its subjects, ready to apply (keeps
/// resourceVersion so a concurrent change conflicts).
Json bindingWithout(Json binding, RbacSubject s) {
  final ns = dig<String>(binding, ['metadata', 'namespace']);
  final out = Map<String, dynamic>.from(binding);
  final meta = Map<String, dynamic>.from(asMap(binding['metadata']))..remove('managedFields');
  out['metadata'] = meta;
  out['subjects'] = [for (final subj in asMapList(binding['subjects'])) if (!subjectMatches(subj, s, bindingNamespace: ns)) subj];
  return out;
}

/// [binding] with [s] appended (no-op if already present).
Json bindingWith(Json binding, RbacSubject s) {
  final ns = dig<String>(binding, ['metadata', 'namespace']);
  final subs = asMapList(binding['subjects']);
  if (subs.any((x) => subjectMatches(x, s, bindingNamespace: ns))) return binding;
  final out = Map<String, dynamic>.from(binding);
  out['metadata'] = Map<String, dynamic>.from(asMap(binding['metadata']))..remove('managedFields');
  out['subjects'] = [...subs, s.toSubjectJson()];
  return out;
}
