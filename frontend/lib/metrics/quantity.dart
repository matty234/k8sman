/// Quantity maths for the metrics UI: parsing Kubernetes quantities,
/// percentages and threshold severities. Pure Dart, unit-tested.
library;

import '../util/k8s.dart';

/// Severity thresholds for utilisation (fraction of a request, limit or
/// capacity): ≥ 90% critical, ≥ 70% warning. Below that is neutral: the UI
/// uses colour for thresholds only.
const warnAt = 0.70;
const critAt = 0.90;

Severity thresholdSeverity(double? frac) {
  if (frac == null) return Severity.neutral;
  if (frac >= critAt) return Severity.error;
  if (frac >= warnAt) return Severity.warn;
  return Severity.neutral;
}

/// Parses any Kubernetes quantity to a plain number in base units:
/// `250m` → 0.25, `2` → 2, `1Ki` → 1024, `1k` → 1000, `1.5e3` → 1500,
/// `42%` → 42. Returns null for anything else.
double? parseQuantity(dynamic q) {
  if (q == null) return null;
  if (q is num) return q.toDouble();
  var s = '$q'.trim();
  if (s.isEmpty) return null;
  if (s.endsWith('%')) return double.tryParse(s.substring(0, s.length - 1));
  const small = {'n': 1e-9, 'u': 1e-6, 'm': 1e-3};
  for (final e in small.entries) {
    if (s.endsWith(e.key)) {
      final v = double.tryParse(s.substring(0, s.length - 1));
      return v == null ? null : v * e.value;
    }
  }
  if (!_quantity.hasMatch(s)) return null;
  // parseBytes handles Ki/Mi/.. and k/M/G/.. and plain numbers.
  return parseBytes(s);
}

final _quantity = RegExp(r'^[+-]?[0-9]*\.?[0-9]+(?:[eE][+-]?[0-9]+)?(?:[KMGTPE]i|[kMGTPE])?$');

/// Orders two table cells holding quantities. Empty cells sort last.
int compareQuantities(dynamic a, dynamic b) {
  final x = parseQuantity(a), y = parseQuantity(b);
  if (x == null && y == null) return '${a ?? ''}'.compareTo('${b ?? ''}');
  if (x == null) return 1;
  if (y == null) return -1;
  return x.compareTo(y);
}

/// `part / whole` as a fraction, or null when whole is missing or zero.
double? fraction(double? part, double? whole) {
  if (part == null || whole == null || whole <= 0) return null;
  return part / whole;
}

/// "42%" (no decimals; "<1%" for tiny non-zero values), or "—".
String formatPercent(double? frac) {
  if (frac == null) return '—';
  final p = frac * 100;
  if (p > 0 && p < 1) return '<1%';
  return '${p.round()}%';
}

/// Memory for usage readouts ("7.2 MiB"), or "—".
String formatMemUsage(double? bytes) => bytes == null ? '—' : formatBytes(bytes);

/// Simple spread of a sample: min, median, max.
class Spread {
  final double min;
  final double median;
  final double max;
  const Spread(this.min, this.median, this.max);

  static Spread? of(Iterable<double> values) {
    final v = values.toList()..sort();
    if (v.isEmpty) return null;
    final mid = v.length ~/ 2;
    final median = v.length.isOdd ? v[mid] : (v[mid - 1] + v[mid]) / 2;
    return Spread(v.first, median, v.last);
  }
}

/// A `usage` table cell (pods' and nodes' CPU and Memory, PVCs' Used): the
/// value in base units (cores or bytes) and, when known, what it's measured
/// against (a limit, request, allocatable or capacity) as a percentage.
class UsageValue {
  final double raw;
  final double? base;
  final double? percent;

  /// "limit", "request", "allocatable" or "capacity", or null.
  final String? basis;

  /// "cpu" (cores) or "bytes".
  final String unit;
  const UsageValue({required this.raw, this.base, this.percent, this.basis, this.unit = 'bytes'});

  /// Parses the backend's `{raw, base?, percent?, basis?, unit}`; null for
  /// anything else (an empty cell).
  static UsageValue? of(dynamic v) {
    if (v is UsageValue) return v;
    if (v is! Map) return null;
    final raw = parseQuantity(v['raw']);
    if (raw == null) return null;
    final base = parseQuantity(v['base']);
    final percent = parseQuantity(v['percent']) ?? (base != null && base > 0 ? raw / base * 100 : null);
    final basis = v['basis'];
    return UsageValue(raw: raw, base: base, percent: percent, basis: basis is String ? basis : null, unit: '${v['unit'] ?? 'bytes'}');
  }

  bool get isCpu => unit == 'cpu';
  String _fmt(double v) => isCpu ? formatCpuUsage(v * 1000) : formatBytes(v);

  /// The value alone: "250m", "1.20", "7.2 MiB".
  String get valueText => _fmt(raw);

  /// What the cell shows as text: the value, or "12 / 50 Gi" for a
  /// capacity (a PVC's used of its size).
  String get text {
    final b = base;
    if (basis != 'capacity' || b == null || isCpu) return valueText;
    var div = 1.0, i = 0;
    const units = ['B', 'Ki', 'Mi', 'Gi', 'Ti', 'Pi'];
    while (b / div >= 1024 && i < units.length - 1) {
      div *= 1024;
      i++;
    }
    String n(double x) {
      final v = x / div;
      return v >= 10 || v == 0 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    }

    return '${n(raw)} / ${n(b)} ${units[i]}';
  }

  /// "250m of 1.00 limit (25%)", for a tooltip.
  String get detail {
    final b = base, p = percent;
    if (b == null || p == null || basis == null) return valueText;
    return '$valueText of ${_fmt(b)} $basis (${formatPercent(p / 100)})';
  }

  /// Amber from 70% (80% of a capacity, like the Storage view), red from 90%.
  Severity get severity {
    final p = percent;
    if (p == null) return Severity.neutral;
    if (p >= critAt * 100) return Severity.error;
    if (p >= (basis == 'capacity' ? 80 : warnAt * 100)) return Severity.warn;
    return Severity.neutral;
  }
}

/// Orders two `usage` cells by percentage (rows without one rank below any
/// that have one), then by value. Empty cells sort last.
int compareUsage(dynamic a, dynamic b) {
  final x = UsageValue.of(a), y = UsageValue.of(b);
  if (x == null || y == null) return x == null && y == null ? 0 : (x == null ? 1 : -1);
  final px = x.percent, py = y.percent;
  if ((px == null) != (py == null)) return px == null ? -1 : 1;
  final c = px != null ? px.compareTo(py!) : 0;
  return c != 0 ? c : x.raw.compareTo(y.raw);
}
