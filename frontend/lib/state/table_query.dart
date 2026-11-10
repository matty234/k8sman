/// The resource table's filter language, and suggestions for composing it.
///
/// A query is whitespace-separated terms, all of which must match:
///   `nginx`            any cell contains "nginx"
///   `status=running`   the Status column contains "running" (`:` works too)
///   `status!=running`  … doesn't contain it
///   `restarts>0`       numbers and quantities compare by value (`>=`, `<`, `<=`)
///   `age<1h`           age columns compare durations (s, m, h, d)
///   `cpu>500m`         usage columns (CPU, Memory, Used) compare the value;
///   `cpu%>80`          … or the percentage of limit/request/capacity
///                      (`cpu>80%` works too; PVC `used>80` is a percentage)
///   `"a b"`            quotes keep spaces in a term or value
///   `!nginx`           no cell contains "nginx" (`-nginx` too); `!status=x`
///                      negates a column term (same as `status!=x`)
///   `/ngi+x$/`         any cell matches the regex (case-insensitive)
///   `name=/^web-\d+/`  the Name column matches the regex (`!=` negates)
/// A regex that doesn't compile matches nothing, and [TableQuery.error] says why.
/// A `key=value` term whose key isn't a column is plain text, so `app=web`
/// still finds that label in a Labels column (or, exactly, in the row's
/// object's labels).
library;

import '../api/models.dart';
import '../metrics/quantity.dart';
import '../util/k8s.dart';

/// A column (or the row's name/namespace) a term can name.
class FilterField {
  /// What you type: the column name, lowercased, spaces as hyphens.
  final String key;
  final String label;

  /// Column index, or null for the row's own name/namespace.
  final int? column;

  /// The column type (string, number, quantity, age, …).
  final String type;
  const FilterField({required this.key, required this.label, required this.column, required this.type});

  bool get comparable => type == 'number' || type == 'quantity' || type == 'bytes' || type == 'percent' || type == 'usage' || type == 'age';
}

String fieldKey(String name) => name.toLowerCase().trim().replaceAll(RegExp(r'[^a-z0-9]+'), '-').replaceAll(RegExp(r'^-|-$'), '');
String _loose(String key) => key.replaceAll('-', '');

/// The fields for [columns], plus `name` and `namespace` when no column
/// already has those keys.
List<FilterField> filterFields(List<ColumnDef> columns, {bool namespaced = true}) {
  final out = <FilterField>[
    for (final (i, c) in columns.indexed)
      if (fieldKey(c.name).isNotEmpty) FilterField(key: fieldKey(c.name), label: c.name, column: i, type: c.type),
  ];
  final keys = {for (final f in out) f.key};
  if (!keys.contains('name')) out.insert(0, const FilterField(key: 'name', label: 'Name', column: null, type: 'string'));
  if (namespaced && !keys.contains('namespace')) out.insert(1, const FilterField(key: 'namespace', label: 'Namespace', column: null, type: 'string'));
  return out;
}

FilterField? _field(List<FilterField> fields, String key) {
  final k = _loose(fieldKey(key));
  if (k.isEmpty) return null;
  for (final f in fields) {
    if (_loose(f.key) == k) return f;
  }
  return null;
}

/// Operators, longest first so `!=` wins over `=`.
const _ops = ['!=', '>=', '<=', '=', ':', '>', '<'];

/// Splits on whitespace outside double quotes; quotes are dropped.
List<String> tokenizeQuery(String s) {
  final out = <String>[];
  final b = StringBuffer();
  var quoted = false;
  var any = false;
  for (final ch in s.split('')) {
    if (ch == '"') {
      quoted = !quoted;
      any = true;
    } else if (!quoted && ch.trim().isEmpty) {
      if (any) out.add(b.toString());
      b.clear();
      any = false;
    } else {
      b.write(ch);
      any = true;
    }
  }
  if (any) out.add(b.toString());
  return out;
}

/// `restarts>=3` → ('restarts', '>=', '3'); null if there's no operator.
(String, String, String)? splitTerm(String t) {
  var best = -1;
  String? op;
  for (final o in _ops) {
    final i = t.indexOf(o);
    if (i > 0 && (best < 0 || i < best || (i == best && o.length > op!.length))) {
      best = i;
      op = o;
    }
  }
  if (op == null) return null;
  return (t.substring(0, best), op, t.substring(best + op.length));
}

/// `90s`, `5m`, `1h30m`, `2d` → Duration.
Duration? parseAgeDuration(String s) {
  final t = s.trim().toLowerCase();
  final re = RegExp(r'(\d+(?:\.\d+)?)(d|h|m|s)');
  var ms = 0.0;
  var consumed = 0;
  for (final m in re.allMatches(t)) {
    final v = double.parse(m.group(1)!);
    consumed += m.group(0)!.length;
    ms += v * switch (m.group(2)) { 'd' => 86400000, 'h' => 3600000, 'm' => 60000, _ => 1000 };
  }
  if (consumed == 0 || consumed != t.length) return null;
  return Duration(milliseconds: ms.round());
}

String cellText(dynamic v) {
  if (v == null) return '';
  if (v is List) return v.join(', ');
  if (v is Map) {
    final u = UsageValue.of(v);
    if (u != null) return u.text;
  }
  return '$v';
}

typedef _Pred = bool Function(TableRowData row, DateTime now);

/// A parsed query. Empty queries match everything.
class TableQuery {
  final List<_Pred> _preds;

  /// The first invalid regex's message, or null. Such a term matches nothing.
  final String? error;
  TableQuery._(this._preds, this.error);

  bool get isEmpty => _preds.isEmpty;
  bool matches(TableRowData row, {DateTime? now}) {
    final n = now ?? DateTime.now();
    return _preds.every((p) => p(row, n));
  }

  factory TableQuery.parse(String text, List<ColumnDef> columns) {
    final fields = filterFields(columns);
    final preds = <_Pred>[];
    String? error;
    var badCount = 0;
    // `/pattern/` → matcher (compiled once); null when it isn't one, and
    // a never-matching one (with [error] set) when it doesn't compile.
    bool Function(String)? regex(String v) {
      if (v.length < 3 || !v.startsWith('/') || !v.endsWith('/')) return null;
      try {
        return RegExp(v.substring(1, v.length - 1), caseSensitive: false).hasMatch;
      } on FormatException catch (e) {
        error ??= e.message;
        badCount++;
        return (_) => false;
      }
    }

    for (var t in tokenizeQuery(text)) {
      var negate = false;
      if (t.length > 1 && (t[0] == '!' || t[0] == '-') && !t.startsWith('!=')) {
        negate = true;
        t = t.substring(1);
      }
      final before = preds.length, bads = badCount;
      _term(t, fields, preds, regex);
      // Negate the term just added, unless it can never match (bad regex).
      if (negate && preds.length > before) {
        final p = preds.removeLast();
        preds.add(badCount != bads ? p : (row, now) => !p(row, now));
      }
    }
    return TableQuery._(preds, error);
  }

  static void _term(String t, List<FilterField> fields, List<_Pred> preds, bool Function(String)? Function(String) regex) {
    {
      final split = splitTerm(t);
      final f = split == null ? null : _field(fields, split.$1);
      final re = split == null || f == null ? regex(t) : null;
      if (re != null) {
        preds.add((row, _) => re(row.name) || row.cells.any((c) => re(cellText(c))));
        return;
      }
      if (split == null || f == null) {
        final needle = t.toLowerCase();
        preds.add((row, _) =>
            row.name.toLowerCase().contains(needle) || row.cells.any((c) => cellText(c).toLowerCase().contains(needle)) || (split != null && _hasLabel(row, needle)));
        return;
      }
      final (_, op, rawValue) = split;
      final value = rawValue.toLowerCase();
      if (value.isEmpty) return; // still typing `status=`
      final colRe = op == '=' || op == ':' || op == '!=' ? regex(rawValue) : null;
      String text(TableRowData row) => switch (f.column) {
        null => f.key == 'name' ? row.name : (row.namespace ?? ''),
        final i => cellText(row.cells.elementAtOrNull(i)),
      };
      switch (op) {
        case '=' || ':' || '!=' when colRe != null:
          preds.add(op == '!=' ? (row, _) => !colRe(text(row)) : (row, _) => colRe(text(row)));
        case '=' || ':':
          preds.add((row, _) => text(row).toLowerCase().contains(value));
        case '!=':
          preds.add((row, _) => !text(row).toLowerCase().contains(value));
        default:
          final cmp = _comparison(f, op, rawValue, percent: split.$1.trim().endsWith('%'));
          preds.add(cmp == null ? (_, _) => false : (row, now) => cmp(f.column == null ? null : row.cells.elementAtOrNull(f.column!), now));
      }
    }
  }
}

/// The row's object has the label [term] (`key=value`, lowercased), shown
/// in a column or not.
bool _hasLabel(TableRowData row, String term) {
  final labels = dig(row.object, ['metadata', 'labels']);
  if (labels is! Map) return false;
  return labels.entries.any((e) => '${e.key}=${e.value}'.toLowerCase() == term);
}

/// `>`/`<` on ages (durations) and numbers/quantities; null when [raw]
/// isn't a value of that kind.
bool Function(dynamic cell, DateTime now)? _comparison(FilterField f, String op, String raw, {bool percent = false}) {
  bool test(num a, num b) => switch (op) { '>' => a > b, '>=' => a >= b, '<' => a < b, _ => a <= b };
  if (f.type == 'age') {
    final d = parseAgeDuration(raw);
    if (d == null) return null;
    return (cell, now) {
      final t = parseTime(cell);
      return t != null && test(now.difference(t).inMilliseconds, d.inMilliseconds);
    };
  }
  final want = parseQuantity(raw);
  if (want == null) return null;
  if (f.type == 'usage') {
    // `cpu%>80` or `cpu>80%`: the percentage; otherwise the value.
    // A bare number against a capacity (PVC Used: `used>80`) is a percentage too.
    final bare = RegExp(r'^[0-9.]+$').hasMatch(raw.trim());
    final pct = percent || raw.trim().endsWith('%');
    return (cell, _) {
      final u = UsageValue.of(cell);
      final have = u == null ? null : (pct || (bare && u.basis == 'capacity') ? u.percent : u.raw);
      return have != null && test(have, want);
    };
  }
  return (cell, _) {
    if (cell is num) return test(cell, want);
    final have = parseQuantity(cellText(cell));
    return have != null && test(have, want);
  };
}

/// One suggestion: what the filter text becomes if it's picked.
class FilterSuggestion {
  final String label;
  final String? detail;
  final String result;

  /// A field (more to type after it) rather than a finished value.
  final bool isField;
  const FilterSuggestion({required this.label, this.detail, required this.result, this.isField = false});

  @override
  String toString() => result;
}

/// Suggestions for the term being typed at the end of [text]: fields when
/// it has no operator yet, values seen in that column once it has one.
List<FilterSuggestion> filterSuggestions(
  String text,
  List<ColumnDef> columns,
  Iterable<TableRowData> rows, {
  bool namespaced = true,
  int maxValues = 8,
}) {
  final fields = filterFields(columns, namespaced: namespaced);
  // The term being typed: after the last unquoted space.
  var start = 0;
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    if (text[i] == '"') quoted = !quoted;
    if (!quoted && text[i].trim().isEmpty) start = i + 1;
  }
  var before = text.substring(0, start);
  var term = text.substring(start);
  if (term.length > 1 && (term[0] == '!' || term[0] == '-') && !term.startsWith('!=')) {
    before += term[0]; // `!sta` completes to `!status=`
    term = term.substring(1);
  }
  final split = splitTerm(term);
  final f = split == null ? null : _field(fields, split.$1);

  if (split == null || f == null) {
    if (split != null) return const []; // `app=web`: plain text, nothing to add
    final t = _loose(term.toLowerCase());
    final used = {for (final u in tokenizeQuery(before)) _loose(fieldKey(splitTerm(u)?.$1 ?? ''))};
    return [
      for (final fl in fields)
        if (_loose(fl.key).startsWith(t) && !used.contains(_loose(fl.key)))
          FilterSuggestion(
            label: '${fl.key}=',
            detail: fl.type == 'age'
                ? 'age, e.g. ${fl.key}<1h'
                : fl.comparable
                ? '${fl.type}, e.g. ${fl.key}>0'
                : fl.label,
            result: '$before${fl.key}=',
            isField: true,
          ),
    ];
  }

  final (key, op, partial) = split;
  if (f.type == 'age') {
    if (partial.isNotEmpty) return const [];
    return [
      for (final (o, v, d) in [('<', '1h', 'created in the last hour'), ('<', '1d', 'created today'), ('>', '7d', 'older than a week')])
        FilterSuggestion(label: '$key$o$v', detail: d, result: '$before$key$o$v '),
    ];
  }
  if (op != '=' && op != ':' && op != '!=') return const [];
  final counts = <String, int>{};
  for (final r in rows) {
    final dynamic v = switch (f.column) {
      null => f.key == 'name' ? r.name : r.namespace,
      final i => r.cells.elementAtOrNull(i),
    };
    for (final s in v is List ? v.map(cellText) : [cellText(v)]) {
      if (s.isEmpty || s.length > 80) continue;
      counts[s] = (counts[s] ?? 0) + 1;
    }
  }
  final p = partial.toLowerCase();
  final values = counts.entries.where((e) => e.key.toLowerCase().contains(p) && e.key.toLowerCase() != p).toList()
    ..sort((a, b) {
      // Prefix matches first, then the most common.
      final ap = a.key.toLowerCase().startsWith(p), bp = b.key.toLowerCase().startsWith(p);
      if (ap != bp) return ap ? -1 : 1;
      final c = b.value.compareTo(a.value);
      return c != 0 ? c : a.key.compareTo(b.key);
    });
  String quote(String v) => v.contains(RegExp(r'\s')) ? '"$v"' : v;
  return [
    for (final e in values.take(maxValues))
      FilterSuggestion(label: e.key, detail: '${e.value}', result: '$before$key$op${quote(e.key)} '),
  ];
}
