/// The resource table's filter language, and suggestions for composing it.
///
/// A query is whitespace-separated terms, all of which must match:
///   `nginx`            any cell contains "nginx"
///   `status=running`   the Status column contains "running" (`:` works too)
///   `status!=running`  … doesn't contain it
///   `restarts>0`       numbers and quantities compare by value (`>=`, `<`, `<=`)
///   `age<1h`           age columns compare durations (s, m, h, d)
///   `"a b"`            quotes keep spaces in a term or value
/// A `key=value` term whose key isn't a column is plain text, so `app=web`
/// still finds that label in a Labels column.
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

  bool get comparable => type == 'number' || type == 'quantity' || type == 'percent' || type == 'age';
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

String cellText(dynamic v) => v == null ? '' : (v is List ? v.join(', ') : '$v');

typedef _Pred = bool Function(TableRowData row, DateTime now);

/// A parsed query. Empty queries match everything.
class TableQuery {
  final List<_Pred> _preds;
  TableQuery._(this._preds);

  bool get isEmpty => _preds.isEmpty;
  bool matches(TableRowData row, {DateTime? now}) {
    final n = now ?? DateTime.now();
    return _preds.every((p) => p(row, n));
  }

  factory TableQuery.parse(String text, List<ColumnDef> columns) {
    final fields = filterFields(columns);
    final preds = <_Pred>[];
    for (final t in tokenizeQuery(text)) {
      final split = splitTerm(t);
      final f = split == null ? null : _field(fields, split.$1);
      if (split == null || f == null) {
        final needle = t.toLowerCase();
        preds.add((row, _) => row.name.toLowerCase().contains(needle) || row.cells.any((c) => cellText(c).toLowerCase().contains(needle)));
        continue;
      }
      final (_, op, rawValue) = split;
      final value = rawValue.toLowerCase();
      if (value.isEmpty) continue; // still typing `status=`
      String text(TableRowData row) => switch (f.column) {
        null => f.key == 'name' ? row.name : (row.namespace ?? ''),
        final i => cellText(row.cells.elementAtOrNull(i)),
      };
      switch (op) {
        case '=' || ':':
          preds.add((row, _) => text(row).toLowerCase().contains(value));
        case '!=':
          preds.add((row, _) => !text(row).toLowerCase().contains(value));
        default:
          final cmp = _comparison(f, op, rawValue);
          preds.add(cmp == null ? (_, _) => false : (row, now) => cmp(f.column == null ? null : row.cells.elementAtOrNull(f.column!), now));
      }
    }
    return TableQuery._(preds);
  }
}

/// `>`/`<` on ages (durations) and numbers/quantities; null when [raw]
/// isn't a value of that kind.
bool Function(dynamic cell, DateTime now)? _comparison(FilterField f, String op, String raw) {
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
  final before = text.substring(0, start);
  final term = text.substring(start);
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
