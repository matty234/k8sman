import '../api/models.dart';
import '../state/context_appearance.dart';

/// How a kube context is shown: a [primary] name and an optional faint
/// [secondary] line. Display only: the context's real name is what every
/// action, setting and search key still uses.
typedef ContextDisplay = ({String primary, String? secondary});

final _eks = RegExp(r'^arn:aws(?:-[a-z-]+)?:eks:([^:]+):(\d+):cluster/(.+)$');

/// 'AWS', 'GCP' or 'Azure' for a context, or null when it can't be told (we
/// don't guess). Detected from the name (EKS ARN, `gke_…`), else the API
/// server host (`*.eks.amazonaws.com`, `*.azmk8s.io`), else the exec plugin
/// or auth provider name ([auth], as the backend reports it).
String? cloudProvider(String name, {String? server, String? auth}) {
  if (_eks.hasMatch(name)) return 'AWS';
  if (name.startsWith('gke_')) return 'GCP';
  final host = _host(server);
  if (host.endsWith('.eks.amazonaws.com')) return 'AWS';
  if (host.endsWith('.azmk8s.io')) return 'Azure';
  switch (auth) {
    case 'aws' || 'aws-iam-authenticator':
      return 'AWS';
    case 'gke-gcloud-auth-plugin' || 'gcp':
      return 'GCP';
    // (kubelogin is also the generic OIDC plugin, so it only counts with an azmk8s.io server.)
    case 'azure':
      return 'Azure';
  }
  return null;
}

String _host(String? server) => (server == null ? '' : Uri.tryParse(server)?.host ?? '').toLowerCase();

/// The region label just before `eks` / `azmk8s` in the server host:
/// `x.gr7.eu-west-1.eks.amazonaws.com`, `x.hcp.uksouth.azmk8s.io`.
String? _serverRegion(String? server) {
  final parts = _host(server).split('.');
  final i = parts.indexWhere((p) => p == 'eks' || p == 'azmk8s');
  return i > 0 ? parts[i - 1] : null;
}

/// EKS ARNs and GKE `gke_<project>_<location>_<cluster>` names, structured;
/// anything else as is, with just the provider (and server region) when known.
ContextDisplay contextDisplay(String name, {String? server, String? auth}) =>
    _fromName(name) ?? _plain(name, server, auth);

ContextDisplay? _fromName(String name) {
  final m = _eks.firstMatch(name);
  if (m != null) return (primary: m[3]!, secondary: 'AWS · ${m[1]} · ${m[2]}');
  if (name.startsWith('gke_')) {
    final p = name.split('_');
    if (p.length == 4 && p.every((s) => s.isNotEmpty)) return (primary: p[3], secondary: 'GCP · ${p[2]} · ${p[1]}');
  }
  return null;
}

/// "AWS · eu-west-1" for a context whose name says nothing; null if no provider.
String? _providerLine(String name, String? server, String? auth) {
  final p = cloudProvider(name, server: server, auth: auth);
  return p == null ? null : [p, ?_serverRegion(server)].join(' · ');
}

ContextDisplay _plain(String name, String? server, String? auth) => (primary: name, secondary: _providerLine(name, server, auth));

/// [contextDisplay] for every context in [contexts], keyed by name. A name in
/// [labels] shows that label, with the cloud secondary if it has one, else
/// the real name (after the provider, if known), so a renamed context can
/// always be told apart (and two may share a label). Unlabelled names that
/// would look the same as another (same cluster, different user) keep their
/// full name.
Map<String, ContextDisplay> contextDisplays(Iterable<ContextInfo> contexts, {Map<String, String> labels = const {}}) {
  final all = {for (final c in contexts) c.name: contextDisplay(c.name, server: c.server, auth: c.auth)};
  final info = {for (final c in contexts) c.name: c};
  final seen = <String, int>{};
  for (final e in all.entries) {
    if ((labels[e.key] ?? '').isNotEmpty) continue;
    final k = '${e.value.primary}\u0000${e.value.secondary}';
    seen[k] = (seen[k] ?? 0) + 1;
  }
  return {
    for (final e in all.entries)
      e.key: (labels[e.key] ?? '').isNotEmpty
          ? (primary: labels[e.key]!, secondary: _fromName(e.key) != null ? e.value.secondary : [?e.value.secondary, e.key].join(' · '))
          : seen['${e.value.primary}\u0000${e.value.secondary}']! > 1
              ? (primary: e.key, secondary: _providerLine(e.key, info[e.key]!.server, info[e.key]!.auth))
              : e.value,
  };
}

/// [contextDisplays] with the labels from [appearance].
Map<String, ContextDisplay> contextDisplaysFor(Iterable<ContextInfo> contexts, Map<String, ContextAppearance> appearance) =>
    contextDisplays(contexts, labels: {for (final e in appearance.entries) if (e.value.label.isNotEmpty) e.key: e.value.label});
