/// Argo CD sync windows: a small 5-field cron matcher plus "is this window
/// active now?" (a window is active from each scheduled start for its
/// duration).
library;

class _Field {
  final Set<int> values;
  final bool star;
  const _Field(this.values, this.star);
}

const _months = {'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6, 'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12};
const _days = {'sun': 0, 'mon': 1, 'tue': 2, 'wed': 3, 'thu': 4, 'fri': 5, 'sat': 6};

_Field? _parse(String raw, int min, int max, Map<String, int> names) {
  final out = <int>{};
  int? num(String s) => names[s.toLowerCase()] ?? int.tryParse(s);
  for (final part in raw.split(',')) {
    var range = part;
    var step = 1;
    final slash = part.indexOf('/');
    if (slash >= 0) {
      step = int.tryParse(part.substring(slash + 1)) ?? 0;
      range = part.substring(0, slash);
      if (step <= 0) return null;
    }
    int lo, hi;
    if (range == '*' || range == '?') {
      lo = min;
      hi = max;
    } else if (range.contains('-')) {
      final ab = range.split('-');
      final a = num(ab[0]), b = num(ab[1]);
      if (a == null || b == null) return null;
      lo = a;
      hi = b;
    } else {
      final a = num(range);
      if (a == null) return null;
      lo = a;
      hi = slash >= 0 ? max : a;
    }
    if (lo < min || hi > max || lo > hi) return null;
    for (var v = lo; v <= hi; v += step) {
      out.add(v);
    }
  }
  return _Field(out, raw == '*' || raw == '?');
}

/// A parsed standard cron schedule (minute hour dom month dow), evaluated in UTC.
class CronSpec {
  final _Field _min, _hour, _dom, _month, _dow;
  CronSpec._(this._min, this._hour, this._dom, this._month, this._dow);

  static CronSpec? parse(String expr) {
    var e = expr.trim();
    const macros = {'@yearly': '0 0 1 1 *', '@annually': '0 0 1 1 *', '@monthly': '0 0 1 * *', '@weekly': '0 0 * * 0', '@daily': '0 0 * * *', '@midnight': '0 0 * * *', '@hourly': '0 * * * *'};
    e = macros[e] ?? e;
    final f = e.split(RegExp(r'\s+'));
    if (f.length != 5) return null;
    final mi = _parse(f[0], 0, 59, const {});
    final h = _parse(f[1], 0, 23, const {});
    final dom = _parse(f[2], 1, 31, const {});
    final mo = _parse(f[3], 1, 12, _months);
    final dw = _parse(f[4], 0, 7, _days);
    if (mi == null || h == null || dom == null || mo == null || dw == null) return null;
    final dowValues = {for (final d in dw.values) d % 7};
    return CronSpec._(mi, h, dom, mo, _Field(dowValues, dw.star));
  }

  bool matches(DateTime t) {
    if (!_min.values.contains(t.minute) || !_hour.values.contains(t.hour) || !_month.values.contains(t.month)) return false;
    final domOk = _dom.values.contains(t.day);
    final dowOk = _dow.values.contains(t.weekday % 7);
    // Like robfig/cron: if both day fields are restricted, either may match.
    if (!_dom.star && !_dow.star) return domOk || dowOk;
    return domOk && dowOk;
  }
}

/// Go duration (`1h30m`, `8h`, `45m`, `90s`) → Duration.
Duration? parseGoDuration(String s) {
  final re = RegExp(r'(\d+(?:\.\d+)?)(h|ms|m|s)');
  var total = 0.0;
  var consumed = 0;
  for (final m in re.allMatches(s.trim())) {
    final v = double.parse(m.group(1)!);
    consumed += m.group(0)!.length;
    total += switch (m.group(2)) { 'h' => v * 3600000, 'm' => v * 60000, 's' => v * 1000, _ => v };
  }
  if (consumed == 0 || consumed != s.trim().length) return null;
  return Duration(milliseconds: total.round());
}

enum WindowState { active, inactive, unknown }

/// Whether the window is open at [now]: some scheduled start lies in
/// (now - duration, now]. Windows in a non-UTC time zone are [WindowState.unknown]
/// (the app has no tz database).
WindowState windowState(Map<String, dynamic> w, {DateTime? now}) {
  final tz = (w['timeZone'] as String?) ?? '';
  if (tz.isNotEmpty && tz != 'UTC' && tz != 'Etc/UTC') return WindowState.unknown;
  final spec = CronSpec.parse('${w['schedule'] ?? ''}');
  final dur = parseGoDuration('${w['duration'] ?? ''}');
  if (spec == null || dur == null) return WindowState.unknown;
  final t = (now ?? DateTime.now()).toUtc();
  final end = DateTime.utc(t.year, t.month, t.day, t.hour, t.minute);
  final minutes = dur.inMinutes.clamp(0, 60 * 24 * 62);
  for (var i = 0; i < minutes; i++) {
    if (spec.matches(end.subtract(Duration(minutes: i)))) return WindowState.active;
  }
  return WindowState.inactive;
}
