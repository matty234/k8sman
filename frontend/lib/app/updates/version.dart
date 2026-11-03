/// Semantic versions (`1.2.3`, `v1.2.3-beta.1+7`) for update checks and the
/// About panel. Build metadata (`+…`) is kept but ignored when comparing.
class SemVer implements Comparable<SemVer> {
  final int major, minor, patch;

  /// Pre-release identifiers (`beta.1` → `['beta', '1']`); empty for a release.
  final List<String> pre;
  final String build;

  const SemVer(this.major, this.minor, this.patch, {this.pre = const [], this.build = ''});

  static final _re = RegExp(r'^v?(\d+)(?:\.(\d+))?(?:\.(\d+))?(?:-([0-9A-Za-z.-]+))?(?:\+([0-9A-Za-z.-]+))?$');

  /// Parses `1`, `1.2`, `1.2.3`, with an optional `v`, pre-release and
  /// build metadata. Returns null for anything else.
  static SemVer? tryParse(String? s) {
    final m = _re.firstMatch((s ?? '').trim());
    if (m == null) return null;
    return SemVer(
      int.parse(m[1]!),
      int.parse(m[2] ?? '0'),
      int.parse(m[3] ?? '0'),
      pre: m[4]?.split('.') ?? const [],
      build: m[5] ?? '',
    );
  }

  bool get isPreRelease => pre.isNotEmpty;

  @override
  int compareTo(SemVer o) {
    for (final d in [major - o.major, minor - o.minor, patch - o.patch]) {
      if (d != 0) return d.sign;
    }
    // A release sorts after its pre-releases (1.0.0-rc.1 < 1.0.0).
    if (pre.isEmpty || o.pre.isEmpty) return pre.isEmpty == o.pre.isEmpty ? 0 : (pre.isEmpty ? 1 : -1);
    for (var i = 0; i < pre.length && i < o.pre.length; i++) {
      final a = pre[i], b = o.pre[i];
      final ai = int.tryParse(a), bi = int.tryParse(b);
      final c = ai != null && bi != null
          ? ai.compareTo(bi)
          // Numeric identifiers sort before alphanumeric ones.
          : ai != null
              ? -1
              : bi != null
                  ? 1
                  : a.compareTo(b);
      if (c != 0) return c.sign;
    }
    return (pre.length - o.pre.length).sign;
  }

  bool operator <(SemVer o) => compareTo(o) < 0;
  bool operator >(SemVer o) => compareTo(o) > 0;

  @override
  bool operator ==(Object other) => other is SemVer && compareTo(other) == 0;

  @override
  int get hashCode => Object.hash(major, minor, patch, pre.join('.'));

  @override
  String toString() => '$major.$minor.$patch${pre.isEmpty ? '' : '-${pre.join('.')}'}${build.isEmpty ? '' : '+$build'}';
}

/// True for versions that must never self-update: unparseable, `0.0.0`, or
/// tagged as a development build (`-dev`).
bool isDevVersion(String? version) {
  final v = SemVer.tryParse(version);
  if (v == null) return true;
  if (v.major == 0 && v.minor == 0 && v.patch == 0) return true;
  return v.pre.any((p) => p.toLowerCase() == 'dev');
}
