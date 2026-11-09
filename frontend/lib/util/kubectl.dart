/// Builds `kubectl` command lines for the "Copy kubectl command" menus, so a
/// user can pick up in a terminal what they were looking at in the app.
library;

import '../api/models.dart';

/// Quotes [s] for a POSIX shell: left as is when it only has safe characters,
/// else wrapped in single quotes with embedded `'` escaped.
String shellQuote(String s) {
  if (s.isNotEmpty && RegExp(r'^[A-Za-z0-9_@%+=:,./-]+$').hasMatch(s)) return s;
  return "'${s.replaceAll("'", r"'\''")}'";
}

/// Groups whose kinds kubectl resolves unambiguously by lowercase kind.
const _plainGroups = {'', 'apps', 'batch', 'networking.k8s.io'};

/// How kubectl is told about the type: the lowercase kind for core and the
/// well-known groups (`pod`, `deployment`), else `<plural>.<group>`
/// (`applications.argoproj.io`), which never collides.
String kubectlResource(ResourceType t) => _plainGroups.contains(t.group) ? t.kind.toLowerCase() : '${t.resource}.${t.group}';

/// An object named on a command line (namespace null when cluster-scoped).
typedef KubectlRef = ({String? namespace, String name});

/// The kube context (and kubeconfig file) the app is on, which may differ
/// from the shell's.
class KubectlEnv {
  final String context;

  /// Empty when the app uses the default loading rules.
  final String kubeconfig;
  const KubectlEnv({this.context = '', this.kubeconfig = ''});

  List<String> get _flags => [
        if (context.isNotEmpty) '--context ${shellQuote(context)}',
        if (kubeconfig.isNotEmpty) '--kubeconfig ${shellQuote(kubeconfig)}',
      ];

  /// `kubectl <args> [-n ns] <env flags> [-- <tail>]`.
  String _cmd(List<String> args, {String? namespace, String tail = ''}) =>
      ['kubectl', ...args, if (namespace != null) '-n ${shellQuote(namespace)}', ..._flags, if (tail.isNotEmpty) '-- $tail'].join(' ');

  /// One command per namespace (kubectl only takes one `-n`), each naming all
  /// of that namespace's objects.
  String _perNamespace(ResourceType t, List<KubectlRef> refs, List<String> verb, [List<String> after = const []]) {
    final by = <String?, List<String>>{};
    for (final r in refs) {
      (by[t.namespaced ? r.namespace : null] ??= []).add(shellQuote(r.name));
    }
    return [
      for (final e in by.entries) _cmd([...verb, kubectlResource(t), ...e.value, ...after], namespace: e.key),
    ].join('\n');
  }

  /// `kubectl <args>` (each argument quoted) with the env flags.
  String args(List<String> args) => _cmd([for (final a in args) shellQuote(a)]);

  String get(ResourceType t, List<KubectlRef> refs) => _perNamespace(t, refs, ['get'], ['-o yaml']);
  String describe(ResourceType t, List<KubectlRef> refs) => _perNamespace(t, refs, ['describe']);
  String rolloutRestart(ResourceType t, List<KubectlRef> refs) => _perNamespace(t, refs, ['rollout', 'restart']);
  String rolloutStatus(ResourceType t, List<KubectlRef> refs) => _perNamespace(t, refs, ['rollout', 'status']);

  String logs(KubectlRef pod, {String? container}) =>
      _cmd(['logs', shellQuote(pod.name), if (container != null) '-c ${shellQuote(container)}', '-f'], namespace: pod.namespace);

  String exec(KubectlRef pod, {String? container}) =>
      _cmd(['exec', '-it', shellQuote(pod.name), if (container != null) '-c ${shellQuote(container)}'], namespace: pod.namespace, tail: 'sh');
}

/// Workload kinds `kubectl rollout` works on.
const kubectlRolloutKinds = {'apps/Deployment', 'apps/StatefulSet', 'apps/DaemonSet'};
