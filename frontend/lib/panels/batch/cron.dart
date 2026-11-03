/// A small, dependency-free cron toolkit for CronJob panels:
///
/// * [CronSchedule.tryParse] parses the 5-field syntax Kubernetes accepts
///   (robfig/cron v3 standard parser): lists, ranges, steps, names, `?`, and
///   the `@hourly`/`@daily`/... descriptors, plus an optional
///   `CRON_TZ=`/`TZ=` prefix.
/// * [describeCron] renders a human-readable description.
/// * [CronSchedule.nextRuns] evaluates upcoming run times in a [ZoneRules].
/// * [PosixTz] / [resolveZone] provide just enough time-zone support
///   (POSIX TZ rules, as found in the footer of TZif files) to honour
///   `spec.timeZone` without a tz database dependency.
library;

import 'dart:io';

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// One comma-separated element of a field: `*`, `a`, `a-b`, with a step.
class CronPart {
  final int start;
  final int end;
  final int step;

  /// Base was `*` or `?`.
  final bool all;

  /// Base was a single value without a step (`5`).
  final bool single;
  const CronPart({required this.start, required this.end, this.step = 1, this.all = false, this.single = false});
}

class CronField {
  final int min;
  final int max;
  final List<CronPart> parts;
  final Set<int> values;

  /// Field starts with `*` or `?` (affects day-of-month/day-of-week matching).
  final bool star;
  const CronField(this.min, this.max, this.parts, this.values, this.star);

  /// Matches every value (`*`, `*/1`, `?`).
  bool get isEvery => parts.length == 1 && parts.first.all && parts.first.step == 1;

  /// Only plain single values (`5`, `1,15`).
  bool get isSingles => parts.every((p) => p.single);

  List<int> get sorted => values.toList()..sort();
}

const _monthNames = {'JAN': 1, 'FEB': 2, 'MAR': 3, 'APR': 4, 'MAY': 5, 'JUN': 6, 'JUL': 7, 'AUG': 8, 'SEP': 9, 'OCT': 10, 'NOV': 11, 'DEC': 12};
const _dowNames = {'SUN': 0, 'MON': 1, 'TUE': 2, 'WED': 3, 'THU': 4, 'FRI': 5, 'SAT': 6};

const cronDescriptors = {
  '@yearly': '0 0 1 1 *',
  '@annually': '0 0 1 1 *',
  '@monthly': '0 0 1 * *',
  '@weekly': '0 0 * * 0',
  '@daily': '0 0 * * *',
  '@midnight': '0 0 * * *',
  '@hourly': '0 * * * *',
};

CronField? _parseField(String raw, int min, int max, Map<String, int> names, {bool dow = false}) {
  if (raw.isEmpty) return null;
  int? num(String s) {
    final n = names[s.toUpperCase()] ?? int.tryParse(s);
    if (n == null) return null;
    // Day-of-week 7 is an alias for Sunday.
    if (dow && n == 7) return 7;
    return n;
  }

  final parts = <CronPart>[];
  final values = <int>{};
  for (final item in raw.split(',')) {
    final slash = item.split('/');
    if (slash.length > 2 || slash.first.isEmpty) return null;
    var step = 1;
    if (slash.length == 2) {
      final s = int.tryParse(slash[1]);
      if (s == null || s <= 0) return null;
      step = s;
    }
    final base = slash.first;
    int start, end;
    var all = false, single = false;
    if (base == '*' || base == '?') {
      start = min;
      end = max;
      all = true;
    } else if (base.contains('-')) {
      final r = base.split('-');
      if (r.length != 2) return null;
      final a = num(r[0]), b = num(r[1]);
      if (a == null || b == null) return null;
      start = a;
      end = b;
    } else {
      final a = num(base);
      if (a == null) return null;
      start = a;
      // `a/n` means a..max stepping by n.
      end = slash.length == 2 ? max : a;
      single = slash.length == 1;
    }
    final hi = dow ? 7 : max;
    if (start < min || end > hi || start > end) return null;
    for (var v = start; v <= end; v += step) {
      values.add(dow && v == 7 ? 0 : v);
    }
    parts.add(CronPart(start: start, end: end, step: step, all: all, single: single));
  }
  return CronField(min, max, parts, values, raw.startsWith('*') || raw.startsWith('?'));
}

class CronSchedule {
  /// The expression as written (without any TZ prefix).
  final String expression;

  /// The 5-field form ([expression] with descriptors expanded).
  final String fields;

  /// From a `CRON_TZ=`/`TZ=` prefix, if any.
  final String? timeZone;
  final CronField minute, hour, dayOfMonth, month, dayOfWeek;

  const CronSchedule._(this.expression, this.fields, this.timeZone, this.minute, this.hour, this.dayOfMonth, this.month, this.dayOfWeek);

  bool get isDescriptor => expression.startsWith('@');

  static CronSchedule? tryParse(String input) {
    var s = input.trim().replaceAll(RegExp(r'\s+'), ' ');
    String? tz;
    final m = RegExp(r'^(?:CRON_TZ|TZ)=(\S+) (.*)$').firstMatch(s);
    if (m != null) {
      tz = m.group(1);
      s = m.group(2)!.trim();
    }
    final expr = s;
    if (s.startsWith('@')) {
      final d = cronDescriptors[s.toLowerCase()];
      if (d == null) return null; // @every and unknown descriptors
      s = d;
    }
    final f = s.split(' ');
    if (f.length != 5) return null;
    final minute = _parseField(f[0], 0, 59, const {});
    final hour = _parseField(f[1], 0, 23, const {});
    final dom = _parseField(f[2], 1, 31, const {});
    final month = _parseField(f[3], 1, 12, _monthNames);
    final dow = _parseField(f[4], 0, 6, _dowNames, dow: true);
    if (minute == null || hour == null || dom == null || month == null || dow == null) return null;
    return CronSchedule._(expr, s, tz, minute, hour, dom, month, dow);
  }

  /// Whether the schedule fires on [day] (only y/m/d are used).
  /// Standard cron rule: if both day fields are restricted they are OR'ed,
  /// otherwise AND'ed.
  bool matchesDay(DateTime day) {
    if (!month.values.contains(day.month)) return false;
    final domOk = dayOfMonth.values.contains(day.day);
    final dowOk = dayOfWeek.values.contains(day.weekday % 7);
    if (dayOfMonth.star || dayOfWeek.star) return domOk && dowOk;
    return domOk || dowOk;
  }

  /// The next [count] run instants (UTC) strictly after [from], evaluating
  /// the schedule on the wall clock of [zone] (UTC when null).
  List<DateTime> nextRuns(DateTime from, {int count = 5, ZoneRules? zone}) {
    final z = zone ?? ZoneRules.utc;
    final fromUtc = from.toUtc();
    final wallNow = fromUtc.add(z.offsetAt(fromUtc));
    final hours = hour.sorted, minutes = minute.sorted;
    final out = <DateTime>[];
    // Start a day early so DST shifts can't hide a run; scan up to ~8 years
    // so Feb 29 schedules are found.
    for (var i = -1; i < 366 * 8 && out.length < count; i++) {
      final day = DateTime.utc(wallNow.year, wallNow.month, wallNow.day + i);
      if (!matchesDay(day)) continue;
      for (final h in hours) {
        for (final mi in minutes) {
          final u = z.wallToUtc(DateTime.utc(day.year, day.month, day.day, h, mi));
          if (u == null || !u.isAfter(fromUtc)) continue;
          if (out.isEmpty || u.isAfter(out.last)) out.add(u);
          if (out.length >= count) return out;
        }
      }
    }
    return out;
  }
}

// ---------------------------------------------------------------------------
// Description
// ---------------------------------------------------------------------------

const _monthLong = ['', 'January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const _monthShort = ['', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const _dowLong = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
const _dowShort = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String ordinal(int n) {
  final mod100 = n % 100;
  if (mod100 >= 11 && mod100 <= 13) return '${n}th';
  return switch (n % 10) { 1 => '${n}st', 2 => '${n}nd', 3 => '${n}rd', _ => '${n}th' };
}

String _joinAnd(List<String> xs) {
  if (xs.isEmpty) return '';
  if (xs.length == 1) return xs.first;
  return '${xs.sublist(0, xs.length - 1).join(', ')} and ${xs.last}';
}

String _two(int n) => n.toString().padLeft(2, '0');

/// Describes one part of a field generically. [unit] is singular
/// ("minute", "hour"), [fmt] renders a value.
String _partPhrase(CronPart p, String unit, String Function(int) fmt, {required int min, required int max}) {
  if (p.single) return fmt(p.start);
  final range = p.all ? '' : ' from ${fmt(p.start)} through ${fmt(p.end)}';
  if (p.step == 1) return 'every $unit$range';
  // `a/n` with an implied end: phrase as "starting at".
  if (!p.all && p.end == max && p.start != min) return 'every ${ordinal(p.step)} $unit from ${fmt(p.start)}';
  return 'every ${ordinal(p.step)} $unit$range';
}

String _fieldPhrase(CronField f, String unit, String Function(int) fmt) =>
    _joinAnd([for (final p in f.parts) _partPhrase(p, unit, fmt, min: f.min, max: f.max)]);

String _dowPhrase(CronField f) {
  if (f.isSingles) {
    final vs = f.sorted;
    return vs.length == 1 ? _dowLong[vs.first] : _joinAnd([for (final v in vs) _dowShort[v]]);
  }
  final pieces = <String>[];
  for (final p in f.parts) {
    if (p.single) {
      pieces.add(_dowShort[p.start]);
    } else if (!p.all && p.step == 1) {
      pieces.add('${_dowShort[p.start]}–${_dowShort[p.end]}');
    } else {
      pieces.add(_partPhrase(p, 'day of the week', (v) => _dowShort[v], min: 0, max: 6));
    }
  }
  return _joinAnd(pieces);
}

String _domPhrase(CronField f) {
  if (f.isSingles) {
    final vs = f.sorted;
    return vs.length == 1 ? 'on day ${vs.first} of the month' : 'on days ${_joinAnd([for (final v in vs) '$v'])} of the month';
  }
  if (f.parts.length == 1 && !f.parts.first.all && f.parts.first.step == 1) {
    return 'on days ${f.parts.first.start}–${f.parts.first.end} of the month';
  }
  return 'on ${_fieldPhrase(f, 'day-of-month', (v) => '$v')}';
}

String _monthPhrase(CronField f) {
  if (f.isSingles) {
    final vs = f.sorted;
    return vs.length == 1 ? 'in ${_monthLong[vs.first]}' : 'in ${_joinAnd([for (final v in vs) _monthShort[v]])}';
  }
  final pieces = <String>[];
  for (final p in f.parts) {
    if (p.single) {
      pieces.add(_monthShort[p.start]);
    } else if (!p.all && p.step == 1) {
      pieces.add('${_monthShort[p.start]}–${_monthShort[p.end]}');
    } else {
      pieces.add(_partPhrase(p, 'month', (v) => _monthShort[v], min: 1, max: 12));
    }
  }
  return 'in ${_joinAnd(pieces)}';
}

String _timePhrase(CronField m, CronField h) {
  // Specific clock times: "at 02:30", "at 09:00 and 17:00".
  if (m.isSingles && h.isSingles && m.values.length * h.values.length <= 6) {
    return 'at ${_joinAnd([for (final hh in h.sorted) for (final mm in m.sorted) '${_two(hh)}:${_two(mm)}'])}';
  }
  final String minutePart;
  if (m.isEvery) {
    minutePart = 'every minute';
  } else if (m.parts.length == 1 && m.parts.first.all) {
    minutePart = 'every ${m.parts.first.step} minutes';
  } else if (m.isSingles) {
    final vs = m.sorted;
    minutePart = vs.length == 1 ? 'at minute ${vs.first}' : 'at minutes ${_joinAnd([for (final v in vs) '$v'])}';
  } else {
    minutePart = _fieldPhrase(m, 'minute', (v) => '$v');
  }
  if (h.isEvery) {
    if (m.isSingles && m.values.length == 1) return 'every hour at minute ${m.values.first}';
    return minutePart;
  }
  // "every 5 minutes between 09:00 and 17:59"
  final hp = h.parts.length == 1 ? h.parts.first : null;
  final minuteCoversHour = m.parts.length == 1 && m.parts.first.all;
  if (hp != null && !hp.all && !hp.single && hp.step == 1 && minuteCoversHour) {
    return '$minutePart between ${_two(hp.start)}:00 and ${_two(hp.end)}:59';
  }
  final String hourPart;
  if (h.isSingles) {
    final vs = h.sorted;
    hourPart = vs.length == 1 ? 'past hour ${vs.first}' : 'past hours ${_joinAnd([for (final v in vs) '$v'])}';
  } else {
    hourPart = 'past ${_fieldPhrase(h, 'hour', (v) => '$v')}';
  }
  return '$minutePart $hourPart';
}

/// Human-readable description, e.g. "every 5 minutes", "at 02:30 every day",
/// "at minute 0 past every 6th hour on Mon–Fri". Returns null if the
/// expression can't be parsed (callers show the raw expression instead).
String? describeCron(String expression) {
  final s = CronSchedule.tryParse(expression);
  if (s == null) return null;
  final special = switch (s.expression.toLowerCase()) {
    '@hourly' => 'every hour, on the hour',
    '@daily' || '@midnight' => 'every day at midnight',
    '@weekly' => 'every Sunday at midnight',
    '@monthly' => 'at midnight on the 1st of every month',
    '@yearly' || '@annually' => 'at midnight on 1 January every year',
    _ => null,
  };
  if (special != null) return special;

  final time = _timePhrase(s.minute, s.hour);
  final dom = s.dayOfMonth, dow = s.dayOfWeek, mon = s.month;
  final days = <String>[];
  if (!dom.isEvery && !dow.isEvery) {
    // Both restricted: standard cron ORs them (unless one starts with '*').
    final joiner = (dom.star || dow.star) ? 'and' : 'or';
    days.add('${_domPhrase(dom)} $joiner on ${_dowPhrase(dow)}');
  } else if (!dom.isEvery) {
    days.add(_domPhrase(dom));
  } else if (!dow.isEvery) {
    days.add('on ${_dowPhrase(dow)}');
  }
  if (!mon.isEvery) days.add(_monthPhrase(mon));
  if (days.isEmpty) {
    return time.startsWith('at ') && !time.startsWith('at minute') ? '$time every day' : time;
  }
  return '$time ${days.join(' ')}';
}

// ---------------------------------------------------------------------------
// Time zones
// ---------------------------------------------------------------------------

/// Offset rules for one zone.
abstract class ZoneRules {
  const ZoneRules();
  String get name;

  /// UTC offset in effect at the instant [utc].
  Duration offsetAt(DateTime utc);

  /// Abbreviation in effect at [utc] (e.g. "BST"), if known.
  String abbreviationAt(DateTime utc);

  /// Every offset this zone can have (std and dst).
  List<Duration> get offsets;

  /// Converts a wall-clock time (fields of a UTC DateTime, read as local) to
  /// the instant it denotes. Returns the earlier instant for ambiguous
  /// (fall-back) times and null for skipped (spring-forward) times.
  DateTime? wallToUtc(DateTime wall) {
    final w = DateTime.utc(wall.year, wall.month, wall.day, wall.hour, wall.minute, wall.second);
    final os = [...offsets]..sort((a, b) => b.compareTo(a));
    for (final o in os) {
      final u = w.subtract(o);
      if (offsetAt(u) == o) return u;
    }
    return null;
  }

  /// [utc] rendered in this zone's wall clock (as a UTC DateTime whose
  /// fields are the local wall time).
  DateTime toWall(DateTime utc) => utc.toUtc().add(offsetAt(utc.toUtc()));

  static const ZoneRules utc = PosixTz._fixed('UTC', 'UTC', Duration.zero);
}

/// A transition rule date: `Mm.w.d`, `Jn` or `n`, plus a time of day.
class _TzRule {
  final String kind; // 'M', 'J', 'n'
  final int a, b, c; // M: month, week, weekday; J/n: day in a
  final Duration time;
  const _TzRule(this.kind, this.a, this.b, this.c, this.time);

  /// The wall-clock date-time (as naive UTC fields) for [year].
  DateTime wallIn(int year) {
    DateTime d;
    switch (kind) {
      case 'M':
        final first = DateTime.utc(year, a, 1);
        final firstDow = first.weekday % 7;
        var day = 1 + (c - firstDow + 7) % 7 + (b - 1) * 7;
        final dim = DateTime.utc(year, a + 1, 0).day;
        while (day > dim) {
          day -= 7;
        }
        d = DateTime.utc(year, a, day);
      case 'J':
        final leap = DateTime.utc(year, 2, 29).month == 2;
        d = DateTime.utc(year, 1, a + (leap && a >= 60 ? 1 : 0));
      default:
        d = DateTime.utc(year, 1, 1 + a);
    }
    return d.add(time);
  }
}

/// A zone described by a POSIX TZ string, e.g. `GMT0BST,M3.5.0/1,M10.5.0`
/// or `<+0530>-5:30`.
class PosixTz extends ZoneRules {
  @override
  final String name;
  final String stdAbbr;
  final Duration stdOffset;
  final String? dstAbbr;
  final Duration? dstOffset;
  final _TzRule? _start, _end;

  const PosixTz._fixed(this.name, this.stdAbbr, this.stdOffset)
      : dstAbbr = null,
        dstOffset = null,
        _start = null,
        _end = null;

  const PosixTz._(this.name, this.stdAbbr, this.stdOffset, this.dstAbbr, this.dstOffset, this._start, this._end);

  bool get hasDst => dstOffset != null && _start != null && _end != null;

  @override
  List<Duration> get offsets => [stdOffset, ?dstOffset];

  bool _isDst(DateTime utc) {
    if (!hasDst) return false;
    final y = utc.year;
    bool inYear(int year) {
      final s = _start!.wallIn(year).subtract(stdOffset);
      final e = _end!.wallIn(year).subtract(dstOffset!);
      return s.isBefore(e) ? !utc.isBefore(s) && utc.isBefore(e) : !utc.isBefore(s) || utc.isBefore(e);
    }

    return inYear(y);
  }

  @override
  Duration offsetAt(DateTime utc) => _isDst(utc.toUtc()) ? dstOffset! : stdOffset;

  @override
  String abbreviationAt(DateTime utc) => _isDst(utc.toUtc()) ? dstAbbr! : stdAbbr;

  /// Parses a POSIX TZ string; returns null if malformed.
  static PosixTz? tryParse(String tz, {String? name}) {
    var i = 0;
    String? abbr() {
      if (i < tz.length && tz[i] == '<') {
        final end = tz.indexOf('>', i);
        if (end < 0) return null;
        final a = tz.substring(i + 1, end);
        i = end + 1;
        return a;
      }
      final m = RegExp(r'[A-Za-z]{3,}').matchAsPrefix(tz, i);
      if (m == null) return null;
      i = m.end;
      return m.group(0);
    }

    Duration? hms({bool allowSign = true}) {
      final m = RegExp(r'([+-]?)(\d{1,3})(?::(\d{1,2}))?(?::(\d{1,2}))?').matchAsPrefix(tz, i);
      if (m == null || (!allowSign && m.group(1)!.isNotEmpty)) return null;
      i = m.end;
      final d = Duration(hours: int.parse(m.group(2)!), minutes: int.parse(m.group(3) ?? '0'), seconds: int.parse(m.group(4) ?? '0'));
      return m.group(1) == '-' ? -d : d;
    }

    _TzRule? rule() {
      _TzRule? r;
      final mm = RegExp(r'M(\d{1,2})\.(\d)\.(\d)').matchAsPrefix(tz, i);
      final jm = RegExp(r'J(\d{1,3})').matchAsPrefix(tz, i);
      final nm = RegExp(r'(\d{1,3})').matchAsPrefix(tz, i);
      if (mm != null) {
        i = mm.end;
        r = _TzRule('M', int.parse(mm.group(1)!), int.parse(mm.group(2)!), int.parse(mm.group(3)!), const Duration(hours: 2));
      } else if (jm != null) {
        i = jm.end;
        r = _TzRule('J', int.parse(jm.group(1)!), 0, 0, const Duration(hours: 2));
      } else if (nm != null) {
        i = nm.end;
        r = _TzRule('n', int.parse(nm.group(1)!), 0, 0, const Duration(hours: 2));
      } else {
        return null;
      }
      if (i < tz.length && tz[i] == '/') {
        i++;
        final t = hms();
        if (t == null) return null;
        r = _TzRule(r.kind, r.a, r.b, r.c, t);
      }
      return r;
    }

    final std = abbr();
    if (std == null) return null;
    final so = hms();
    if (so == null) return null;
    final stdOffset = -so; // POSIX offsets are west-positive.
    if (i >= tz.length) return PosixTz._(name ?? tz, std, stdOffset, null, null, null, null);
    final dst = abbr();
    if (dst == null) return null;
    var dstOffset = stdOffset + const Duration(hours: 1);
    if (i < tz.length && tz[i] != ',') {
      final o = hms();
      if (o == null) return null;
      dstOffset = -o;
    }
    _TzRule? start, end;
    if (i < tz.length && tz[i] == ',') {
      i++;
      start = rule();
      if (start == null || i >= tz.length || tz[i] != ',') return null;
      i++;
      end = rule();
      if (end == null) return null;
    } else {
      // Historic POSIX default: US rules.
      start = const _TzRule('M', 3, 2, 0, Duration(hours: 2));
      end = const _TzRule('M', 11, 1, 0, Duration(hours: 2));
    }
    if (i != tz.length) return null;
    return PosixTz._(name ?? tz, std, stdOffset, dst, dstOffset, start, end);
  }
}

/// Built-in POSIX rules for common zones, used when the system tz database
/// can't be read.
const builtinZones = <String, String>{
  'UTC': 'UTC0',
  'Etc/UTC': 'UTC0',
  'GMT': 'GMT0',
  'Etc/GMT': 'GMT0',
  'Europe/London': 'GMT0BST,M3.5.0/1,M10.5.0',
  'Europe/Dublin': 'IST-1GMT0,M10.5.0,M3.5.0/1',
  'Europe/Lisbon': 'WET0WEST,M3.5.0/1,M10.5.0',
  'Europe/Paris': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Berlin': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Amsterdam': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Madrid': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Rome': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Stockholm': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Zurich': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Warsaw': 'CET-1CEST,M3.5.0,M10.5.0/3',
  'Europe/Helsinki': 'EET-2EEST,M3.5.0/3,M10.5.0/4',
  'Europe/Athens': 'EET-2EEST,M3.5.0/3,M10.5.0/4',
  'Europe/Kyiv': 'EET-2EEST,M3.5.0/3,M10.5.0/4',
  'Europe/Istanbul': '<+03>-3',
  'Europe/Moscow': 'MSK-3',
  'America/New_York': 'EST5EDT,M3.2.0,M11.1.0',
  'America/Toronto': 'EST5EDT,M3.2.0,M11.1.0',
  'America/Chicago': 'CST6CDT,M3.2.0,M11.1.0',
  'America/Denver': 'MST7MDT,M3.2.0,M11.1.0',
  'America/Phoenix': 'MST7',
  'America/Los_Angeles': 'PST8PDT,M3.2.0,M11.1.0',
  'America/Vancouver': 'PST8PDT,M3.2.0,M11.1.0',
  'America/Anchorage': 'AKST9AKDT,M3.2.0,M11.1.0',
  'Pacific/Honolulu': 'HST10',
  'America/Sao_Paulo': '<-03>3',
  'America/Mexico_City': 'CST6',
  'Asia/Tokyo': 'JST-9',
  'Asia/Seoul': 'KST-9',
  'Asia/Shanghai': 'CST-8',
  'Asia/Hong_Kong': 'HKT-8',
  'Asia/Singapore': '<+08>-8',
  'Asia/Kolkata': 'IST-5:30',
  'Asia/Dubai': '<+04>-4',
  'Asia/Jakarta': 'WIB-7',
  'Australia/Sydney': 'AEST-10AEDT,M10.1.0,M4.1.0/3',
  'Australia/Melbourne': 'AEST-10AEDT,M10.1.0,M4.1.0/3',
  'Australia/Brisbane': 'AEST-10',
  'Australia/Perth': 'AWST-8',
  'Pacific/Auckland': 'NZST-12NZDT,M9.5.0,M4.1.0/3',
  'Africa/Johannesburg': 'SAST-2',
  'Africa/Lagos': 'WAT-1',
};

/// Reads the POSIX footer of a TZif file from the system tz database.
/// Overridable for tests.
String? Function(String zone) zoneInfoFooter = _readZoneInfoFooter;

String? _readZoneInfoFooter(String zone) {
  if (zone.contains('..') || zone.startsWith('/')) return null;
  for (final dir in const ['/usr/share/zoneinfo', '/var/db/timezone/zoneinfo']) {
    try {
      final f = File('$dir/$zone');
      if (!f.existsSync()) continue;
      final bytes = f.readAsBytesSync();
      if (bytes.length < 5 || String.fromCharCodes(bytes.sublist(0, 4)) != 'TZif') continue;
      // v2+ files end with "\n<POSIX TZ>\n".
      if (bytes.last != 0x0A) continue;
      final start = bytes.lastIndexOf(0x0A, bytes.length - 2);
      if (start < 0) continue;
      final footer = String.fromCharCodes(bytes.sublist(start + 1, bytes.length - 1));
      if (footer.isNotEmpty) return footer;
    } catch (_) {
      // Unreadable: try the next location / built-ins.
    }
  }
  return null;
}

/// Resolves an IANA zone name (as used by `spec.timeZone`). Returns null if
/// the zone is unknown.
ZoneRules? resolveZone(String? name) {
  if (name == null || name.isEmpty || name == 'UTC' || name == 'Etc/UTC') return ZoneRules.utc;
  final etc = RegExp(r'^Etc/GMT([+-])(\d{1,2})$').firstMatch(name);
  if (etc != null) {
    // Etc/GMT+5 is UTC-5 (POSIX sign convention).
    final h = int.parse(etc.group(2)!);
    final off = Duration(hours: etc.group(1) == '+' ? -h : h);
    return PosixTz._(name, 'GMT${etc.group(1) == '+' ? '-' : '+'}$h', off, null, null, null, null);
  }
  final footer = zoneInfoFooter(name);
  final tz = footer ?? builtinZones[name];
  if (tz == null) return null;
  return PosixTz.tryParse(tz, name: name);
}
