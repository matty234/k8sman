/// What a stretch of a structured log line is.
enum LogTokKind { plain, key, string, number, keyword, punct, level, message }

/// A half-open [start, end) range of the line body and what it is.
class LogTok {
  final int start;
  final int end;
  final LogTokKind kind;
  const LogTok(this.start, this.end, this.kind);
}

const _maxLen = 8192;
const _levelKeys = {'level', 'lvl', 'severity', 'loglevel', 'log.level', 'levelname', 'log_level'};
const _msgKeys = {'msg', 'message'};
final _numRe = RegExp(r'^-?\d+(\.\d+)?([eE][+-]?\d+)?$');
final _keyRe = RegExp(r'^[A-Za-z_][\w.\-/]*=');

/// Splits a log line body into typed segments covering the whole string, or
/// null when it is neither a JSON object nor logfmt (>= 2 key=value pairs).
/// A single cheap pass: invalid or truncated JSON yields null, never throws.
List<LogTok>? tokenizeLog(String s) {
  if (s.length > _maxLen) return null;
  final t = s.trimLeft();
  if (t.isEmpty) return null;
  if (t.codeUnitAt(0) == 0x7B) return _json(s);
  if (!s.contains('=')) return null;
  return _logfmt(s);
}

LogTokKind _valueKind(String key) => _levelKeys.contains(key) ? LogTokKind.level : (_msgKeys.contains(key) ? LogTokKind.message : LogTokKind.string);

LogTokKind _bare(String v, String key) {
  if (_levelKeys.contains(key)) return LogTokKind.level;
  if (_msgKeys.contains(key)) return LogTokKind.message;
  if (v == 'true' || v == 'false' || v == 'null') return LogTokKind.keyword;
  return _numRe.hasMatch(v) ? LogTokKind.number : LogTokKind.string;
}

bool _ws(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

/// End (exclusive) of the quoted string starting at [i], or -1 if unterminated.
int _quoted(String s, int i) {
  var j = i + 1;
  while (j < s.length) {
    final c = s.codeUnitAt(j);
    if (c == 0x5C) {
      j += 2;
      continue;
    }
    if (c == 0x22) return j + 1;
    j++;
  }
  return -1;
}

List<LogTok>? _json(String s) {
  final out = <LogTok>[];
  final stack = <int>[];
  var key = '';
  var i = 0;
  final n = s.length;
  void add(int a, int b, LogTokKind k) {
    if (out.isNotEmpty && out.last.kind == k && out.last.end == a && k == LogTokKind.plain) {
      out[out.length - 1] = LogTok(out.last.start, b, k);
    } else {
      out.add(LogTok(a, b, k));
    }
  }

  while (i < n) {
    final c = s.codeUnitAt(i);
    if (_ws(c)) {
      var j = i + 1;
      while (j < n && _ws(s.codeUnitAt(j))) {
        j++;
      }
      add(i, j, LogTokKind.plain);
      i = j;
    } else if (c == 0x7B || c == 0x5B) {
      stack.add(c);
      add(i, i + 1, LogTokKind.punct);
      i++;
    } else if (c == 0x7D || c == 0x5D) {
      if (stack.isEmpty || stack.removeLast() != (c == 0x7D ? 0x7B : 0x5B)) return null;
      add(i, i + 1, LogTokKind.punct);
      i++;
      if (stack.isEmpty) {
        // Only whitespace may follow the closing brace.
        for (var j = i; j < n; j++) {
          if (!_ws(s.codeUnitAt(j))) return null;
        }
        if (i < n) add(i, n, LogTokKind.plain);
        return out;
      }
    } else if (c == 0x2C || c == 0x3A) {
      add(i, i + 1, LogTokKind.punct);
      i++;
    } else if (c == 0x22) {
      final e = _quoted(s, i);
      if (e < 0) return null;
      var j = e;
      while (j < n && _ws(s.codeUnitAt(j))) {
        j++;
      }
      if (j < n && s.codeUnitAt(j) == 0x3A) {
        key = s.substring(i + 1, e - 1).toLowerCase();
        add(i, e, LogTokKind.key);
      } else {
        add(i, e, _valueKind(key));
      }
      i = e;
    } else {
      var j = i;
      while (j < n) {
        final d = s.codeUnitAt(j);
        if (_ws(d) || d == 0x2C || d == 0x7D || d == 0x5D) break;
        j++;
      }
      final v = s.substring(i, j);
      if (v == 'true' || v == 'false' || v == 'null') {
        add(i, j, LogTokKind.keyword);
      } else if (_numRe.hasMatch(v)) {
        add(i, j, LogTokKind.number);
      } else {
        return null;
      }
      i = j;
    }
  }
  return null; // truncated: never closed
}

List<LogTok>? _logfmt(String s) {
  final out = <LogTok>[];
  var pairs = 0;
  var i = 0;
  final n = s.length;
  void add(int a, int b, LogTokKind k) {
    if (b > a) out.add(LogTok(a, b, k));
  }

  while (i < n) {
    var j = i;
    while (j < n && _ws(s.codeUnitAt(j))) {
      j++;
    }
    add(i, j, LogTokKind.plain);
    if (j >= n) break;
    var e = j;
    while (e < n && !_ws(s.codeUnitAt(e))) {
      e++;
    }
    final m = _keyRe.firstMatch(s.substring(j, e));
    if (m == null) {
      add(j, e, LogTokKind.plain);
      i = e;
      continue;
    }
    pairs++;
    final eq = j + m.end - 1;
    final key = s.substring(j, eq).toLowerCase();
    add(j, eq, LogTokKind.key);
    add(eq, eq + 1, LogTokKind.punct);
    final v = eq + 1;
    if (v < n && s.codeUnitAt(v) == 0x22) {
      var q = _quoted(s, v);
      if (q < 0) q = n;
      // Quotes are punctuation; the text between is the value.
      add(v, v + 1, LogTokKind.punct);
      final close = q > v + 1 && s.codeUnitAt(q - 1) == 0x22 ? q - 1 : q;
      add(v + 1, close, _valueKind(key));
      add(close, q, LogTokKind.punct);
      i = q;
    } else {
      add(v, e, _bare(s.substring(v, e), key));
      i = e;
    }
  }
  return pairs >= 2 ? out : null;
}

/// A small LRU of tokenisations by line text, so scrolling re-uses them.
class LogSyntaxCache {
  final int capacity;
  LogSyntaxCache([this.capacity = 2000]);
  final _map = <String, List<LogTok>?>{};

  List<LogTok>? tokens(String body) {
    if (_map.containsKey(body)) {
      final v = _map.remove(body);
      _map[body] = v;
      return v;
    }
    final v = tokenizeLog(body);
    _map[body] = v;
    if (_map.length > capacity) _map.remove(_map.keys.first);
    return v;
  }
}
