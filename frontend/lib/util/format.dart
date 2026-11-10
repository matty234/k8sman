/// Text for durations, ages and CPU quantities, shared by every panel.
library;

/// kubectl-style short age: 45s, 12m, 3h, 5d, 2y.
String formatAge(DateTime? t, {DateTime? now}) {
  if (t == null) return '';
  var d = (now ?? DateTime.now()).toUtc().difference(t.toUtc());
  if (d.isNegative) d = Duration.zero;
  if (d.inSeconds < 60) return '${d.inSeconds}s';
  if (d.inMinutes < 60) return '${d.inMinutes}m';
  if (d.inHours < 24) return d.inMinutes % 60 == 0 || d.inHours >= 10 ? '${d.inHours}h' : '${d.inHours}h${d.inMinutes % 60}m';
  if (d.inDays < 365) return '${d.inDays}d';
  return '${d.inDays ~/ 365}y${d.inDays % 365}d';
}

/// Time left until [t], kubectl style ("29d", "3h"); once [t] has passed,
/// the time since, with a minus ("-2d").
String formatUntil(DateTime t, {DateTime? now}) {
  final n = (now ?? DateTime.now()).toUtc();
  final u = t.toUtc();
  if (u.isBefore(n)) return '-${formatAge(u, now: n)}';
  // The mirror image: as long ago as t is ahead.
  return formatAge(n.subtract(u.difference(n)), now: n);
}

/// "5m ago" ('' when [t] is null).
String formatAgo(DateTime? t, {DateTime? now}) => t == null ? '' : '${formatAge(t, now: now)} ago';

/// A span in prose: "just now", "5 min ago", "yesterday".
String formatAgoProse(Duration d) {
  if (d.inMinutes < 1) return 'just now';
  if (d.inHours < 1) return '${d.inMinutes} min ago';
  if (d.inDays < 1) return '${d.inHours} h ago';
  return d.inDays == 1 ? 'yesterday' : '${d.inDays} days ago';
}

/// Local "2026-11-03 11:22:57".
String formatLocal(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  final l = t.toLocal();
  return '${l.year}-${two(l.month)}-${two(l.day)} ${two(l.hour)}:${two(l.minute)}:${two(l.second)}';
}

enum DurationStyle {
  /// `1m5s`, `2h3m`, `4d5h`.
  compact,

  /// `3m05s`, `2h05m`, `4d3h`: minutes and seconds zero-padded.
  padded,

  /// `10m`, `1h30m`, `2h`, `1d6h`: zero parts dropped.
  trimmed,
}

String formatDuration(Duration d, {DurationStyle style = DurationStyle.compact}) {
  final s = d.inSeconds;
  switch (style) {
    case DurationStyle.compact:
      if (s < 60) return '${s}s';
      if (d.inMinutes < 60) return '${d.inMinutes}m${s % 60}s';
      if (d.inHours < 24) return '${d.inHours}h${d.inMinutes % 60}m';
      return '${d.inDays}d${d.inHours % 24}h';
    case DurationStyle.padded:
      String two(int n) => n.toString().padLeft(2, '0');
      if (s < 60) return '${s}s';
      if (s < 3600) return '${s ~/ 60}m${two(s % 60)}s';
      if (s < 86400) return '${s ~/ 3600}h${two((s % 3600) ~/ 60)}m';
      return '${s ~/ 86400}d${(s % 86400) ~/ 3600}h';
    case DurationStyle.trimmed:
      if (s < 60) return '${s}s';
      if (s < 3600) return s % 60 == 0 ? '${s ~/ 60}m' : '${s ~/ 60}m${s % 60}s';
      if (s < 86400) return (s ~/ 60) % 60 == 0 ? '${s ~/ 3600}h' : '${s ~/ 3600}h${(s ~/ 60) % 60}m';
      return (s ~/ 3600) % 24 == 0 ? '${s ~/ 86400}d' : '${s ~/ 86400}d${(s ~/ 3600) % 24}h';
  }
}

enum CpuStyle {
  /// Requests and limits: `250m`, `1`, `1.50`; '' when unknown.
  quantity,

  /// Usage readouts: `<1m`, `850m`, `3.46`; '—' when unknown.
  usage,

  /// Whole cores with at most one decimal and no unit: `12.4`, `32`.
  cores,
}

/// CPU given in millicores.
String formatCpu(double? millis, {CpuStyle style = CpuStyle.quantity}) {
  if (millis == null) return style == CpuStyle.usage ? '—' : '';
  switch (style) {
    case CpuStyle.quantity:
      if (millis < 1000) return '${millis.toStringAsFixed(0)}m';
      final cores = millis / 1000;
      return cores == cores.roundToDouble() ? cores.toStringAsFixed(0) : cores.toStringAsFixed(2);
    case CpuStyle.usage:
      if (millis > 0 && millis < 1) return '<1m';
      if (millis < 1000) return '${millis.round()}m';
      final cores = millis / 1000;
      return cores >= 10 ? cores.toStringAsFixed(1) : cores.toStringAsFixed(2);
    case CpuStyle.cores:
      final c = millis / 1000;
      if (c == c.roundToDouble()) return c.toStringAsFixed(0);
      return c < 10 ? c.toStringAsFixed(c < 1 ? 2 : 1) : c.toStringAsFixed(1);
  }
}

String formatCpuUsage(double? millis) => formatCpu(millis, style: CpuStyle.usage);
String formatCores(double millis) => formatCpu(millis, style: CpuStyle.cores);
