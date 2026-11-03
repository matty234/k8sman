/// Label helpers for the generic object view.
library;

const _acronyms = {
  'api', 'url', 'uri', 'ip', 'id', 'uid', 'tls', 'dns', 'cpu', 'gpu', 'ttl', 'http', 'https', 'tcp', 'udp', 'sctp', //
  'cidr', 'json', 'yaml', 'ca', 'os', 'sha', 'crd', 'cel', 'ssl', 'acl', 'arn', 'ssh', 'oidc', 'jwt', 'sni', 'mtu',
};

final _identifier = RegExp(r'^[a-z][A-Za-z0-9]*$');
final _words = RegExp(r'[A-Z]{2,}s(?=[A-Z0-9]|$)|[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+');

/// `leaseDurationSeconds` → `Lease duration seconds`, `podCIDR` → `Pod CIDR`,
/// `apiVersion` → `API version`. Keys that aren't plain camelCase identifiers
/// (label keys, file names, …) are returned unchanged.
String humanize(String key) {
  if (!_identifier.hasMatch(key)) return key;
  final words = _words.allMatches(key).map((m) => m.group(0)!).toList();
  if (words.isEmpty) return key;
  final out = <String>[];
  for (var i = 0; i < words.length; i++) {
    final w = words[i];
    final lower = w.toLowerCase();
    String word;
    if (_acronyms.contains(lower)) {
      word = lower.toUpperCase();
    } else if (lower.length > 2 && lower.endsWith('s') && _acronyms.contains(lower.substring(0, lower.length - 1))) {
      word = '${lower.substring(0, lower.length - 1).toUpperCase()}s';
    } else if (w.length > 1 && w == w.toUpperCase() && RegExp('[A-Z]').hasMatch(w)) {
      word = w; // unknown acronym run, keep as-is
    } else {
      word = i == 0 ? '${lower[0].toUpperCase()}${lower.substring(1)}' : lower;
    }
    out.add(word);
  }
  return out.join(' ');
}

final _rfc3339 = RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$');

bool looksLikeTimestamp(dynamic v) => v is String && _rfc3339.hasMatch(v);

String capitalize(String s) => s.isEmpty ? s : '${s[0].toUpperCase()}${s.substring(1)}';
