/// Pure helpers for ConfigMap/Secret values: format detection, decoding,
/// PEM and docker config inspection.
library;

import 'dart:convert';
import 'dart:typed_data';

import '../../util/k8s.dart';

enum ValueFormat { json, yaml, properties, shell, plain }

final _yamlLine = RegExp(r'''^\s*(- )?["']?[\w.\-/ ]+["']?:(\s|$)''');
final _yamlList = RegExp(r'^\s*- ');
final _propLine = RegExp(r'^\s*[\w.\-]+\s*=');
final _shellHints = RegExp(r'^\s*(export\s+\w+=|if \[|fi$|then$|for \w+ in|while |case .* in|set -\w|source |\. /|\w+\(\)\s*\{)', multiLine: true);

/// Best-effort guess of the text format of [v].
ValueFormat detectFormat(String v) {
  final t = v.trim();
  if (t.isEmpty) return ValueFormat.plain;
  if ((t.startsWith('{') && t.endsWith('}')) || (t.startsWith('[') && t.endsWith(']'))) {
    try {
      jsonDecode(t);
      return ValueFormat.json;
    } catch (_) {}
  }
  if (t.startsWith('#!') || _shellHints.hasMatch(t)) return ValueFormat.shell;
  final lines = t.split('\n').map((l) => l.trimRight()).where((l) => l.trim().isNotEmpty && !l.trimLeft().startsWith('#') && !l.trimLeft().startsWith('!')).toList();
  if (lines.isEmpty) return ValueFormat.plain;
  if (t.startsWith('---')) return ValueFormat.yaml;
  final yaml = lines.where((l) => _yamlLine.hasMatch(l) || _yamlList.hasMatch(l)).length;
  final props = lines.where((l) => _propLine.hasMatch(l) && l.contains('=')).length;
  final ratio = lines.length == 1 ? 1.0 : 0.6;
  if (props >= lines.length * ratio && props >= yaml) return ValueFormat.properties;
  if (yaml >= lines.length * ratio && (lines.length > 1 || t.contains(': '))) return ValueFormat.yaml;
  return ValueFormat.plain;
}

/// Pretty-prints JSON values; returns others unchanged.
String prettyValue(String v, ValueFormat f) {
  if (f != ValueFormat.json) return v;
  try {
    return const JsonEncoder.withIndent('  ').convert(jsonDecode(v));
  } catch (_) {
    return v;
  }
}

int lineCount(String v) {
  if (v.isEmpty) return 0;
  final n = '\n'.allMatches(v).length;
  return v.endsWith('\n') ? n : n + 1;
}

int utf8Size(String v) => utf8.encode(v).length;

/// Decodes a base64 data value; null when invalid.
Uint8List? decodeBase64(dynamic v) {
  if (v is! String) return null;
  try {
    return base64.decode(base64.normalize(v.replaceAll(RegExp(r'\s'), '')));
  } catch (_) {
    return null;
  }
}

/// Result of decoding a secret value for display.
class DecodedValue {
  final Uint8List bytes;

  /// The UTF-8 text, or null when the value is binary.
  final String? text;
  const DecodedValue(this.bytes, this.text);
  bool get isBinary => text == null;
  int get length => bytes.length;
}

/// Base64-decodes [v] and classifies it as text or binary.
DecodedValue? decodeSecretValue(dynamic v) {
  final bytes = decodeBase64(v);
  if (bytes == null) return null;
  String? text;
  try {
    text = utf8.decode(bytes);
    // Control chars other than tab/newline/CR mean it isn't meant as text.
    if (text.codeUnits.any((c) => c < 32 && c != 9 && c != 10 && c != 13)) text = null;
  } on FormatException {
    text = null;
  }
  return DecodedValue(bytes, text);
}

/// `de ad be ef …` preview of the first [max] bytes.
String hexPreview(List<int> bytes, {int max = 32}) {
  final shown = bytes.take(max).map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
  return bytes.length > max ? '$shown …' : shown;
}

/// Counts PEM blocks by type, e.g. {CERTIFICATE: 2}.
Map<String, int> pemBlocks(String? text) {
  final out = <String, int>{};
  if (text == null) return out;
  for (final m in RegExp(r'-----BEGIN ([A-Z0-9 ]+)-----').allMatches(text)) {
    final t = m.group(1)!;
    out[t] = (out[t] ?? 0) + 1;
  }
  return out;
}

String describePem(Map<String, int> blocks) =>
    blocks.isEmpty ? 'no PEM blocks' : blocks.entries.map((e) => e.value == 1 ? e.key : '${e.key} ×${e.value}').join(', ');

/// One registry entry from a `.dockerconfigjson` / `.dockercfg`.
class RegistryAuth {
  final String registry;
  final String? username;
  final String? password;
  final String? email;
  const RegistryAuth(this.registry, {this.username, this.password, this.email});
}

/// Parses the decoded docker config JSON. Usernames and passwords come
/// from the explicit fields, or from the base64 `auth` ("user:pass").
List<RegistryAuth>? parseDockerConfig(String? text) {
  if (text == null) return null;
  dynamic j;
  try {
    j = jsonDecode(text);
  } catch (_) {
    return null;
  }
  final m = asMap(j);
  final auths = m.containsKey('auths') ? asMap(m['auths']) : m; // .dockercfg has no "auths" wrapper
  final out = <RegistryAuth>[];
  for (final e in auths.entries) {
    final a = asMap(e.value);
    String? user = a['username'] as String?;
    String? pass = a['password'] as String?;
    final auth = a['auth'];
    if (auth is String && (user == null || pass == null)) {
      final decoded = decodeBase64(auth);
      if (decoded != null) {
        final s = utf8.decode(decoded, allowMalformed: true);
        final i = s.indexOf(':');
        if (i >= 0) {
          user ??= s.substring(0, i);
          pass ??= s.substring(i + 1);
        }
      }
    }
    out.add(RegistryAuth(e.key, username: user, password: pass, email: a['email'] as String?));
  }
  out.sort((a, b) => a.registry.compareTo(b.registry));
  return out;
}

/// One-line explanations of the built-in Secret types.
String secretTypeExplanation(String type) => switch (type) {
      'Opaque' => 'Arbitrary user-defined key/value data.',
      'kubernetes.io/tls' => 'TLS certificate and private key (tls.crt / tls.key), e.g. for Ingress.',
      'kubernetes.io/dockerconfigjson' => 'Registry credentials (~/.docker/config.json) for imagePullSecrets.',
      'kubernetes.io/dockercfg' => 'Legacy registry credentials (~/.dockercfg) for imagePullSecrets.',
      'kubernetes.io/service-account-token' => 'Long-lived API token for a ServiceAccount, minted by the token controller.',
      'kubernetes.io/basic-auth' => 'Credentials for basic authentication (username / password).',
      'kubernetes.io/ssh-auth' => 'SSH private key (ssh-privatekey) for SSH authentication.',
      'bootstrap.kubernetes.io/token' => 'Bootstrap token used by kubeadm to join nodes to the cluster.',
      _ when type.startsWith('helm.sh/') => 'Helm release state (gzip + base64 encoded manifest).',
      _ => 'Custom secret type.',
    };
