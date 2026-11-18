import '../state/context_appearance.dart';

/// How a kube context is shown: a [primary] name and an optional faint
/// [secondary] line. Display only: the context's real name is what every
/// action, setting and search key still uses.
typedef ContextDisplay = ({String primary, String? secondary});

final _eks = RegExp(r'^arn:aws(?:-[a-z-]+)?:eks:([^:]+):(\d+):cluster/(.+)$');

/// EKS ARNs and GKE `gke_<project>_<location>_<cluster>` names, structured;
/// anything else as is.
ContextDisplay contextDisplay(String name) {
  final m = _eks.firstMatch(name);
  if (m != null) return (primary: m[3]!, secondary: '${m[1]} · ${m[2]}');
  if (name.startsWith('gke_')) {
    final p = name.split('_');
    if (p.length == 4 && p.every((s) => s.isNotEmpty)) return (primary: p[3], secondary: '${p[2]} · ${p[1]}');
  }
  return (primary: name, secondary: null);
}

/// [contextDisplay] for every name in [names]. A name in [labels] shows that
/// label, with the cloud secondary if it has one, else the real name, so a
/// renamed context can always be told apart (and two may share a label).
/// Unlabelled names that would look the same as another (same cluster,
/// different user) keep their full name.
Map<String, ContextDisplay> contextDisplays(Iterable<String> names, {Map<String, String> labels = const {}}) {
  final all = {for (final n in names) n: contextDisplay(n)};
  final seen = <String, int>{};
  for (final e in all.entries) {
    if ((labels[e.key] ?? '').isNotEmpty) continue;
    final k = '${e.value.primary}\u0000${e.value.secondary}';
    seen[k] = (seen[k] ?? 0) + 1;
  }
  return {
    for (final e in all.entries)
      e.key: (labels[e.key] ?? '').isNotEmpty
          ? (primary: labels[e.key]!, secondary: e.value.secondary ?? e.key)
          : seen['${e.value.primary}\u0000${e.value.secondary}']! > 1
              ? (primary: e.key, secondary: null)
              : e.value,
  };
}

/// [contextDisplays] with the labels from [appearance].
Map<String, ContextDisplay> contextDisplaysFor(Iterable<String> names, Map<String, ContextAppearance> appearance) =>
    contextDisplays(names, labels: {for (final e in appearance.entries) if (e.value.label.isNotEmpty) e.key: e.value.label});
