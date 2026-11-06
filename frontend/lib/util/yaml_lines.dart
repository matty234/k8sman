/// Line-level helpers for YAML manifests in the editor, without a YAML
/// parser: enough to point validation errors at lines.
library;

final _separator = RegExp(r'^---(\s.*)?$');

/// The 1-based first line of each non-empty document in [text], split on
/// `---` the same way the backend's `POST /api/apply` splits them.
List<int> yamlDocumentStarts(String text) {
  final out = <int>[];
  int? start;
  final lines = text.split('\n');
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i].trimRight();
    if (_separator.hasMatch(line)) {
      if (start != null) out.add(start);
      start = null;
      continue;
    }
    final t = line.trim();
    if (start == null && t.isNotEmpty && !t.startsWith('#') && t != '...') start = i + 1;
  }
  if (start != null) out.add(start);
  return out;
}

/// Summary of each document: `(line, kind, name)`, for the outline.
List<({int line, String kind, String name})> yamlDocumentSummaries(String text) {
  final lines = text.split('\n');
  final starts = yamlDocumentStarts(text);
  final out = <({int line, String kind, String name})>[];
  for (var d = 0; d < starts.length; d++) {
    final end = d + 1 < starts.length ? starts[d + 1] - 1 : lines.length;
    String kind = '', name = '';
    var inMeta = false;
    for (var i = starts[d] - 1; i < end && i < lines.length; i++) {
      final l = lines[i];
      if (l.startsWith('kind:')) kind = _scalar(l.substring(5));
      if (l.startsWith('metadata:')) {
        inMeta = true;
        continue;
      }
      if (inMeta && l.isNotEmpty && !l.startsWith(' ')) inMeta = false;
      final m = RegExp(r'^\s+(name|generateName):\s*(.*)$').firstMatch(l);
      if (inMeta && m != null && name.isEmpty && l.indexOf(m.group(1)!) <= 4) name = _scalar(m.group(2)!);
    }
    out.add((line: starts[d], kind: kind, name: name));
  }
  return out;
}

String _scalar(String s) {
  var v = s.trim();
  final hash = v.indexOf(' #');
  if (hash >= 0) v = v.substring(0, hash).trim();
  if (v.length >= 2 && (v.startsWith('"') && v.endsWith('"') || v.startsWith("'") && v.endsWith("'"))) v = v.substring(1, v.length - 1);
  return v;
}

class _Line {
  final int index;

  /// Column of a list item's dash, or -1.
  final int dash;

  /// Column of the key (after any dash), and the key, if the line has one.
  final int keyIndent;
  final String? key;
  _Line(this.index, this.dash, this.keyIndent, this.key);
}

final _keyRe = RegExp(r'''^("([^"]*)"|'([^']*)'|[^\s:#][^:#]*?)\s*:(\s|$)''');

_Line? _parse(int index, String raw) {
  final trimmed = raw.trimLeft();
  if (trimmed.isEmpty || trimmed.startsWith('#')) return null;
  var indent = raw.length - trimmed.length;
  var rest = trimmed;
  var dash = -1;
  if (rest == '-' || rest.startsWith('- ')) {
    dash = indent;
    final after = rest.length > 1 ? rest.substring(2) : '';
    indent += 2 + (after.length - after.trimLeft().length);
    rest = after.trimLeft();
  }
  final m = _keyRe.firstMatch(rest);
  final key = m == null ? null : (m.group(2) ?? m.group(3) ?? m.group(1)!.trim());
  return _Line(index, dash, indent, key);
}

/// The 1-based line of a Kubernetes field path (`spec.template.spec.
/// containers[0].image`) in the document starting at [docStart] (1-based),
/// or the deepest ancestor found. Null when not even the first segment
/// matches.
int? lineForFieldPath(String text, String path, {int docStart = 1}) {
  final tokens = <Object>[];
  for (final part in path.split('.')) {
    final m = RegExp(r'^([^\[]*)((\[[^\]]*\])*)$').firstMatch(part);
    if (m == null) {
      tokens.add(part);
      continue;
    }
    if (m.group(1)!.isNotEmpty) tokens.add(m.group(1)!);
    for (final idx in RegExp(r'\[([^\]]*)\]').allMatches(m.group(2) ?? '')) {
      final s = idx.group(1)!;
      tokens.add(int.tryParse(s) ?? s); // map keys like data[foo] stay strings
    }
  }
  final raw = text.split('\n');
  // The document's lines (up to the next separator).
  final parsed = <_Line>[];
  for (var i = docStart - 1; i < raw.length; i++) {
    if (i < 0) continue;
    if (i > docStart - 1 && _separator.hasMatch(raw[i].trimRight())) break;
    final l = _parse(i, raw[i]);
    if (l != null) parsed.add(l);
  }
  var lo = 0, hi = parsed.length;
  int? found;
  for (final tok in tokens) {
    if (lo >= hi) break;
    if (tok is int) {
      final dashCol = parsed[lo].dash;
      if (dashCol < 0) break;
      var n = -1, start = -1;
      for (var i = lo; i < hi; i++) {
        if (parsed[i].dash == dashCol) {
          n++;
          if (n == tok) {
            start = i;
          } else if (n == tok + 1) {
            hi = i;
            break;
          }
        }
      }
      if (start < 0) break;
      lo = start;
      found = parsed[start].index;
      continue;
    }
    final childIndent = parsed[lo].keyIndent;
    var at = -1;
    for (var i = lo; i < hi; i++) {
      final l = parsed[i];
      if (l.keyIndent < childIndent) break;
      if (l.keyIndent == childIndent && l.key == tok) {
        at = i;
        break;
      }
    }
    if (at < 0) break;
    found = parsed[at].index;
    // The value's block: following lines indented deeper than the key, or
    // a sequence at the key's own indent.
    var end = at + 1;
    while (end < hi && (parsed[end].keyIndent > childIndent || parsed[end].dash == childIndent) && !(parsed[end].dash >= 0 && parsed[end].dash < childIndent)) {
      end++;
    }
    lo = at + 1;
    hi = end;
  }
  return found == null ? null : found + 1;
}

/// A line number in a YAML parse error (`yaml: line 5: …`), made absolute
/// for the document starting at [docStart].
int? lineFromYamlError(String message, {int docStart = 1}) {
  final m = RegExp(r'line (\d+)').firstMatch(message);
  if (m == null) return null;
  return docStart + int.parse(m.group(1)!) - 1;
}
