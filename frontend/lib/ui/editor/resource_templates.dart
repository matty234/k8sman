import 'package:flutter/material.dart';

import '../../api/known_apis.dart';
import '../../api/models.dart';
import '../../plugins/plugin_icons.dart';

/// A starter manifest for the create editor.
class ResourceTemplate {
  final String label;
  final IconData icon;

  /// API group and Kind it creates (for pre-selecting from a table); the
  /// first document's kind for multi-document templates.
  final String group;
  final String kind;
  final String description;
  final String Function(String namespace) build;

  /// A plugin's template: the plugin it comes from (null for built-ins).
  final TemplatePlugin? plugin;
  const ResourceTemplate({required this.label, required this.icon, required this.group, required this.kind, required this.description, required this.build, this.plugin});

  /// One of `GET /api/plugins/templates`: ${namespace} becomes the
  /// namespace it's rendered for; other placeholders stay for the user.
  factory ResourceTemplate.fromPlugin(Json j) {
    final key = '${j['kind'] ?? ''}';
    final slash = key.indexOf('/');
    final yaml = '${j['yaml'] ?? ''}';
    return ResourceTemplate(
      label: '${j['name'] ?? ''}',
      icon: pluginIcons['${j['icon']}'] ?? Icons.extension_outlined,
      group: slash < 0 ? '' : key.substring(0, slash),
      kind: slash < 0 ? key : key.substring(slash + 1),
      description: '${j['description'] ?? ''}',
      build: (ns) => fillNamespace(yaml, ns),
      plugin: TemplatePlugin(id: '${j['plugin'] ?? ''}', name: '${j['pluginName'] ?? ''}', icon: '${j['icon'] ?? ''}', hasIcon: j['hasIcon'] == true),
    );
  }
}

/// The plugin a template comes from, for grouping the template list.
class TemplatePlugin {
  final String id;
  final String name;

  /// Its kind icon's name; [hasIcon]: it has an icon.png.
  final String icon;
  final bool hasIcon;
  const TemplatePlugin({required this.id, required this.name, this.icon = '', this.hasIcon = false});
}

/// A template placeholder: `${name}` or `${name:default}` (group 1 the
/// name, group 2 the default). Anything else with `${` is plain text. Same
/// syntax as the backend (backend/internal/plugins/templates.go).
final placeholderRe = RegExp(r'\$\{([A-Za-z_][A-Za-z0-9_-]*)(?::([^}\n]*))?\}');

/// [yaml] with each `${namespace}` (or `${namespace:…}`) replaced by [ns].
String fillNamespace(String yaml, String ns) => yaml.replaceAllMapped(placeholderRe, (m) => m[1] == 'namespace' ? ns : m[0]!);

/// [yaml] with each `${name:default}` replaced by its default.
String fillDefaults(String yaml) => yaml.replaceAllMapped(placeholderRe, (m) => m[2] ?? m[0]!);

/// The first placeholder in [lines] at or after line [index], offset
/// [offset], wrapping around to the top: its line and columns.
({int line, int start, int end, String name})? nextPlaceholder(List<String> lines, int index, int offset) {
  // One more than the lines: the start of line [index] after wrapping.
  for (var k = 0; k <= lines.length && lines.isNotEmpty; k++) {
    final i = (index + k) % lines.length;
    final from = k == 0 ? offset : 0;
    for (final m in placeholderRe.allMatches(lines[i])) {
      if (m.start >= from) return (line: i, start: m.start, end: m.end, name: m[1]!);
    }
  }
  return null;
}

/// The built-in templates, Blank last. Namespaced ones use the namespace
/// they're rendered for.
final resourceTemplates = <ResourceTemplate>[
  ResourceTemplate(
    label: 'Deployment',
    icon: Icons.layers_outlined,
    group: 'apps',
    kind: 'Deployment',
    description: 'Replicated pods from a container image',
    build: (ns) => '''apiVersion: $appsApiVersion
kind: Deployment
metadata:
  name: my-app
  namespace: $ns
  labels:
    app: my-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: my-app
  template:
    metadata:
      labels:
        app: my-app
    spec:
      containers:
        - name: app
          image: nginx:1.27
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 128Mi
''',
  ),
  ResourceTemplate(
    label: 'Service',
    icon: Icons.lan_outlined,
    group: '',
    kind: 'Service',
    description: 'A stable address for pods matching a selector',
    build: (ns) => '''apiVersion: $coreApiVersion
kind: Service
metadata:
  name: my-app
  namespace: $ns
spec:
  type: ClusterIP
  selector:
    app: my-app
  ports:
    - name: http
      port: 80
      targetPort: 80
''',
  ),
  ResourceTemplate(
    label: 'ConfigMap',
    icon: Icons.tune,
    group: '',
    kind: 'ConfigMap',
    description: 'Non-secret configuration as key/value pairs',
    build: (ns) => '''apiVersion: $coreApiVersion
kind: ConfigMap
metadata:
  name: my-config
  namespace: $ns
data:
  LOG_LEVEL: info
  config.yaml: |
    feature: true
''',
  ),
  ResourceTemplate(
    label: 'Secret',
    icon: Icons.key_outlined,
    group: '',
    kind: 'Secret',
    description: 'Opaque values; stringData is encoded for you',
    build: (ns) => '''apiVersion: $coreApiVersion
kind: Secret
metadata:
  name: my-secret
  namespace: $ns
type: Opaque
stringData:
  username: admin
  password: change-me
''',
  ),
  ResourceTemplate(
    label: 'Job',
    icon: Icons.play_circle_outline,
    group: 'batch',
    kind: 'Job',
    description: 'Run pods to completion once',
    build: (ns) => '''apiVersion: $batchApiVersion
kind: Job
metadata:
  name: my-job
  namespace: $ns
spec:
  backoffLimit: 2
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: job
          image: busybox:1.36
          command: ["sh", "-c", "echo hello"]
''',
  ),
  ResourceTemplate(
    label: 'CronJob',
    icon: Icons.schedule,
    group: 'batch',
    kind: 'CronJob',
    description: 'Run a Job on a schedule',
    build: (ns) => '''apiVersion: $batchApiVersion
kind: CronJob
metadata:
  name: my-cronjob
  namespace: $ns
spec:
  schedule: "0 * * * *"
  concurrencyPolicy: Forbid
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: job
              image: busybox:1.36
              command: ["sh", "-c", "date"]
''',
  ),
  ResourceTemplate(
    label: 'Ingress',
    icon: Icons.public,
    group: 'networking.k8s.io',
    kind: 'Ingress',
    description: 'HTTP routing from outside the cluster to a Service',
    build: (ns) => '''apiVersion: $networkingApiVersion
kind: Ingress
metadata:
  name: my-app
  namespace: $ns
spec:
  # ingressClassName: nginx
  rules:
    - host: my-app.example.com
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: my-app
                port:
                  number: 80
''',
  ),
  ResourceTemplate(
    label: 'PersistentVolumeClaim',
    icon: Icons.storage_outlined,
    group: '',
    kind: 'PersistentVolumeClaim',
    description: 'Request storage from the default StorageClass',
    build: (ns) => '''apiVersion: $coreApiVersion
kind: PersistentVolumeClaim
metadata:
  name: my-data
  namespace: $ns
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  # storageClassName: standard
''',
  ),
  ResourceTemplate(
    label: 'Namespace',
    icon: Icons.folder_outlined,
    group: '',
    kind: 'Namespace',
    description: 'A new namespace (cluster-scoped)',
    build: (ns) => '''apiVersion: $coreApiVersion
kind: Namespace
metadata:
  name: my-namespace
''',
  ),
  ResourceTemplate(
    label: 'ServiceAccount',
    icon: Icons.badge_outlined,
    group: '',
    kind: 'ServiceAccount',
    description: 'An identity for pods',
    build: (ns) => '''apiVersion: $coreApiVersion
kind: ServiceAccount
metadata:
  name: my-app
  namespace: $ns
''',
  ),
  ResourceTemplate(
    label: 'Role + RoleBinding',
    icon: Icons.admin_panel_settings_outlined,
    group: 'rbac.authorization.k8s.io',
    kind: 'Role',
    description: 'Read-only access to pods, bound to a ServiceAccount',
    build: (ns) => '''apiVersion: $rbacApiVersion
kind: Role
metadata:
  name: pod-reader
  namespace: $ns
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
---
apiVersion: $rbacApiVersion
kind: RoleBinding
metadata:
  name: pod-reader
  namespace: $ns
subjects:
  - kind: ServiceAccount
    name: my-app
    namespace: $ns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: Role
  name: pod-reader
''',
  ),
  blankTemplate(),
];

/// "Blank": a skeleton for [type] (any kind, CRs included), or a bare
/// apiVersion/kind/metadata document.
ResourceTemplate blankTemplate([ResourceType? type]) => ResourceTemplate(
      label: type == null ? 'Blank' : type.kind,
      icon: type == null ? Icons.note_add_outlined : Icons.extension_outlined,
      group: type?.group ?? '',
      kind: type?.kind ?? '',
      description: type == null ? 'Start from an empty manifest' : 'A skeleton ${type.kind} (${type.apiVersion})',
      build: (ns) => [
        'apiVersion: ${type?.apiVersion ?? ''}',
        'kind: ${type?.kind ?? ''}',
        'metadata:',
        '  name: ${type == null ? '' : 'my-${type.kind.toLowerCase()}'}',
        if (type?.namespaced ?? true) '  namespace: $ns',
        if (type != null) 'spec: {}',
        '',
      ].join('\n'),
    );

/// The template for [type]: a built-in one for its kind, else a skeleton.
ResourceTemplate templateFor(ResourceType? type) {
  if (type == null) return resourceTemplates.first;
  for (final t in resourceTemplates) {
    if (t.group == type.group && t.kind == type.kind) return t;
  }
  if (type.group == 'rbac.authorization.k8s.io' && type.kind == 'RoleBinding') return resourceTemplates.firstWhere((t) => t.kind == 'Role');
  return blankTemplate(type);
}
