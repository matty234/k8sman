/// A kubeconfig file the user can switch to (`GET /api/kubeconfigs`).
class KubeconfigCandidate {
  final String path;
  final List<String> contexts;
  final String? currentContext;

  /// Why it is listed: KUBECONFIG, default, kube-dir or recent.
  final String? source;
  final String? error;

  const KubeconfigCandidate({required this.path, this.contexts = const [], this.currentContext, this.source, this.error});

  factory KubeconfigCandidate.fromJson(Map<String, dynamic> j) => KubeconfigCandidate(
        path: j['path'] as String? ?? '',
        contexts: List<String>.from(j['contexts'] as List? ?? const []),
        currentContext: j['currentContext'] as String?,
        source: j['source'] as String?,
        error: (j['error'] as String?)?.isEmpty ?? true ? null : j['error'] as String,
      );
}

/// The active kubeconfig and the candidates to switch to.
class KubeconfigList {
  /// Active kubeconfig path; '' = default loading rules merging [merged].
  final String current;
  final List<String> merged;
  final List<KubeconfigCandidate> candidates;

  /// The user's home directory, for shortening paths to `~/…`.
  final String home;

  const KubeconfigList({this.current = '', this.merged = const [], this.candidates = const [], this.home = ''});

  factory KubeconfigList.fromJson(Map<String, dynamic> j) => KubeconfigList(
        current: j['current'] as String? ?? '',
        merged: List<String>.from(j['merged'] as List? ?? const []),
        candidates: [for (final c in (j['candidates'] as List? ?? const [])) KubeconfigCandidate.fromJson(Map<String, dynamic>.from(c))],
        home: j['home'] as String? ?? '',
      );

  /// [path] with the home directory replaced by `~`.
  String shorten(String path) {
    if (home.isNotEmpty && (path == home || path.startsWith('$home/') || path.startsWith('$home\\'))) return '~${path.substring(home.length)}';
    return path;
  }

  /// Label for the active kubeconfig.
  String get currentLabel {
    if (current.isNotEmpty) return shorten(current);
    if (merged.length > 1) return '\$KUBECONFIG (${merged.length} files)';
    return 'Default kubeconfig';
  }
}
