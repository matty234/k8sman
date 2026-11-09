import 'dart:async';

import '../api/client.dart';
import '../api/models.dart';
import 'log_buffer.dart';
import 'log_session.dart';

/// How many palette colours [LogSource.colorIndex] indexes.
const int kLogSourceColors = 8;

/// Longest source label shown in the line prefix.
const int kMaxSourceLabel = 26;

/// One (pod, container) feeding an aggregated stream. Its label and colour
/// are worked out once here, not per line.
class LogSource {
  final int index;
  final String pod;
  final String container;
  final int colorIndex;

  /// Short text shown in the prefix (see [AggregateLogStream.labelFor]).
  String label = '';
  final String lowerFull;
  bool hidden = false;

  LogSource(this.index, this.pod, this.container, this.colorIndex) : lowerFull = '$pod/$container'.toLowerCase();

  String get full => '$pod/$container';
}

/// What a buffered row is: a log line from a source, or a notice.
class LineMeta {
  final int src;
  final String ts;

  /// 0 = log line, 1 = notice (pod started / stopped), 2 = problem (error / warning).
  final int kind;
  const LineMeta(this.src, this.ts, this.kind);
}

/// FNV-1a: a stable string hash (unlike `hashCode`, same on every run).
int stableHash(String s) {
  var h = 0x811c9dc5;
  for (var i = 0; i < s.length; i++) {
    h = ((h ^ s.codeUnitAt(i)) * 0x01000193) & 0xffffffff;
  }
  return h;
}

/// The logs of many pods (a workload's selector, or a hand-picked list) in
/// one tab: the backend merges them in timestamp order and follows the pod
/// set; lines are labelled by [LogSource].
class AggregateLogStream extends LogSession {
  final ApiClient api;
  @override
  final String namespace;

  /// Label selector to follow, or null for the fixed [podNames].
  final String? selector;
  final List<String> podNames;

  /// Shown in the tab, e.g. `deploy/web`; null for a hand-picked set.
  final String? title;

  bool _allContainers;
  bool get allContainers => _allContainers;
  bool _previous = false;

  /// Previous container instances (finite; the pod set is not followed).
  @override
  bool get previous => _previous;
  int tail = 200;

  /// Parallel to [lines]: the source and timestamp of each row.
  final LogBuffer<LineMeta> meta = LogBuffer<LineMeta>(kMaxLogLines);
  final List<LogSource> sources = [];
  final Map<String, Map<String, LogSource>> _byPod = {};
  final Set<String> _hiddenKeys = {};
  final List<int> _colorUse = List.filled(kLogSourceColors, 0);

  /// Pods that currently have a running stream, with their containers.
  final Map<String, Set<String>> _live = {};

  /// Width of the prefix in characters (the longest label).
  int prefixChars = 0;

  final List<String> _pendingText = [];
  final List<LineMeta> _pendingMeta = [];
  StreamSubscription<AggregateMessage>? _sub;
  Timer? _flushTimer;
  Timer? _settle;
  DateTime _connectedAt = DateTime.now();
  bool _disposed = false;
  List<int>? _rows;

  AggregateLogStream({
    required this.api,
    required this.namespace,
    this.selector,
    this.podNames = const [],
    this.title,
    bool allContainers = false,
    // ignore: prefer_initializing_formals
  }) : _allContainers = allContainers {
    assert((selector == null) != podNames.isEmpty, 'exactly one of selector or pods');
    _subscribe();
  }

  @override
  String get id => aggregateId(namespace, selector, podNames);

  @override
  String get pod => '';

  /// Pods with a running stream.
  int get podCount => _live.length;

  @override
  String get label {
    final n = podCount;
    final count = '$n pod${n == 1 ? '' : 's'}';
    return title == null ? count : '$title ($count)';
  }

  @override
  bool get isSubscribed => _sub != null;

  @override
  int get extraChars => prefixChars + 1 + (timestamps ? 31 : 0);

  /// Distinct pod names seen, sorted.
  List<String> get pods => (_byPod.keys.toList()..sort());

  bool get anyHidden => sources.any((s) => s.hidden);

  // --- options ---

  void setOptions({bool? follow, bool? previous, bool? timestamps, LogRange? range, bool? allContainers}) {
    final reconnect = (follow != null && follow != this.follow) ||
        (previous != null && previous != _previous) ||
        (range != null && range != (tail: tail, since: since)) ||
        (allContainers != null && allContainers != _allContainers);
    if (previous != null) _previous = previous;
    if (follow != null) this.follow = follow;
    if (timestamps != null) this.timestamps = timestamps;
    if (range != null) {
      tail = range.tail;
      since = range.since;
    }
    if (allContainers != null) _allContainers = allContainers;
    if (reconnect) _subscribe();
    notifyListeners();
  }

  @override
  void reconnect() {
    _subscribe();
    notifyListeners();
  }

  void setSourceHidden(LogSource s, bool hidden) {
    s.hidden = hidden;
    hidden ? _hiddenKeys.add(s.full) : _hiddenKeys.remove(s.full);
    _filtersChanged();
  }

  void setPodHidden(String pod, bool hidden) {
    for (final s in _byPod[pod]?.values ?? const <LogSource>[]) {
      s.hidden = hidden;
      hidden ? _hiddenKeys.add(s.full) : _hiddenKeys.remove(s.full);
    }
    _filtersChanged();
  }

  void showAllSources() {
    for (final s in sources) {
      s.hidden = false;
    }
    _hiddenKeys.clear();
    _filtersChanged();
  }

  void _filtersChanged() {
    resetMatches();
    invalidateRows();
    notifyListeners();
  }

  // --- rows ---

  @override
  void invalidateRows() {
    super.invalidateRows();
    _rows = null;
  }

  @override
  List<int>? get visibleRows {
    if (onlyMatching && query.isNotEmpty) return matching;
    if (!anyHidden) return null;
    return _rows ??= [
      for (var i = 0; i < meta.length; i++)
        if (!sources[meta[i].src].hidden) i,
    ];
  }

  @override
  bool lineMatches(int idx, String q) {
    final m = meta[idx];
    final src = sources[m.src];
    if (src.hidden) return false;
    if (regex) {
      final re = queryRegex;
      return re != null && ((m.kind == 0 && re.hasMatch(src.full)) || re.hasMatch(lines[idx]));
    }
    return (m.kind == 0 && src.lowerFull.contains(q)) || lines[idx].toLowerCase().contains(q);
  }

  @override
  String get downloadBase => '${(title ?? namespace).replaceAll(RegExp(r'[\\/:*?"<>|\s]+'), '-')}-logs';

  @override
  String copyText() => exportText(all: true);

  @override
  String exportText({bool all = false}) {
    final rows = all ? null : visibleRows;
    final b = StringBuffer();
    for (var n = 0; n < (rows?.length ?? lines.length); n++) {
      final i = rows == null ? n : rows[n];
      final m = meta[i];
      if (sources[m.src].hidden) continue;
      if (b.isNotEmpty) b.write('\n');
      if (m.kind == 0) b.write('${sources[m.src].full} ');
      if (timestamps && m.ts.isNotEmpty) b.write('${m.ts} ');
      b.write(lines[i]);
    }
    return b.toString();
  }

  @override
  void clear() {
    meta.clear();
    super.clear();
  }

  // --- sources ---

  LogSource _source(String pod, String container) {
    final byContainer = _byPod.putIfAbsent(pod, () => {});
    final existing = byContainer[container];
    if (existing != null) return existing;
    final h = stableHash('$pod/$container') % kLogSourceColors;
    var color = h;
    // Prefer a colour no other source uses (still derived from the hash).
    if (sources.length < kLogSourceColors) {
      for (var i = 0; i < kLogSourceColors; i++) {
        final c = (h + i) % kLogSourceColors;
        if (_colorUse[c] == 0) {
          color = c;
          break;
        }
      }
    }
    _colorUse[color]++;
    final s = LogSource(sources.length, pod, container, color)..hidden = _hiddenKeys.contains('$pod/$container');
    sources.add(s);
    byContainer[container] = s;
    _relabel();
    return s;
  }

  /// The pod name without the prefix its siblings share, cut at a dash, so
  /// `web-6fd47b8fcb-4v4m9` reads `4v4m9`.
  String _short(String pod, String prefix) {
    final s = pod.startsWith(prefix) ? pod.substring(prefix.length) : pod;
    return s.isEmpty ? pod : s;
  }

  void _relabel() {
    final names = _byPod.keys.toList();
    var prefix = names.first;
    for (final n in names.skip(1)) {
      var i = 0;
      while (i < prefix.length && i < n.length && prefix[i] == n[i]) {
        i++;
      }
      prefix = prefix.substring(0, i);
    }
    final cut = prefix.lastIndexOf('-');
    prefix = cut < 0 ? '' : prefix.substring(0, cut + 1);
    var longest = 0;
    for (final s in sources) {
      var l = _short(s.pod, prefix);
      if (_allContainers) l = '$l/${s.container}';
      if (l.length > kMaxSourceLabel) l = '…${l.substring(l.length - kMaxSourceLabel + 1)}';
      s.label = l;
      if (l.length > longest) longest = l.length;
    }
    prefixChars = longest;
  }

  // --- streaming ---

  void _cancel() {
    _sub?.cancel();
    _sub = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    _settle?.cancel();
    _settle = null;
  }

  void _subscribe() {
    _cancel();
    lines.clear();
    meta.clear();
    _pendingText.clear();
    _pendingMeta.clear();
    sources.clear();
    _byPod.clear();
    _live.clear();
    _colorUse.fillRange(0, kLogSourceColors, 0);
    prefixChars = 0;
    dropped = 0;
    maxLen = 0;
    invalidateRows();
    resetMatches();
    error = null;
    phase = LogPhase.connecting;
    _connectedAt = DateTime.now();
    // A quiet workload sends nothing at first: don't spin "Connecting" forever.
    _settle = Timer(const Duration(seconds: 2), () {
      if (_disposed || phase != LogPhase.connecting) return;
      phase = LogPhase.streaming;
      notifyListeners();
    });
    _sub = api
        .aggregateLogs(
          namespace: namespace,
          selector: selector,
          pods: selector == null ? podNames : null,
          container: _allContainers ? '*' : null,
          tailLines: tail,
          sinceSeconds: since,
          follow: follow && !_previous,
          previous: _previous,
        )
        .listen(_onMessage, onError: (Object e) => _finish(LogPhase.error, '$e'), onDone: () => _finish(LogPhase.eof));
  }

  void _notice(LogSource src, String text, {int kind = 1}) {
    _pendingText.add(text);
    _pendingMeta.add(LineMeta(src.index, '', kind));
  }

  void _onMessage(AggregateMessage m) {
    if (phase == LogPhase.connecting) phase = LogPhase.streaming;
    for (final l in m.lines) {
      final src = _byPod[l.pod]?[l.container] ?? _source(l.pod, l.container);
      _pendingText.add(l.line);
      _pendingMeta.add(LineMeta(src.index, l.ts, 0));
    }
    final pod = m.pod;
    final container = m.container ?? '';
    if (m.event != null && pod != null) {
      final src = _source(pod, container);
      final settled = DateTime.now().difference(_connectedAt) > const Duration(seconds: 2);
      if (m.event == 'added') {
        final fresh = !_live.containsKey(pod);
        _live.putIfAbsent(pod, () => {}).add(container);
        if (fresh && settled) _notice(src, '— $pod started —');
      } else {
        final cs = _live[pod];
        if (cs != null && cs.remove(container) && cs.isEmpty) {
          _live.remove(pod);
          _notice(src, '— $pod stopped —');
        }
      }
    }
    if (m.error != null) {
      final src = pod == null ? null : _source(pod, container);
      if (src != null) {
        _notice(src, '! ${src.full}: ${m.error}', kind: 2);
      } else if (sources.isNotEmpty) {
        _notice(sources.first, '! ${m.error}', kind: 2);
      } else {
        error = m.error;
      }
    }
    if (m.warning != null && sources.isNotEmpty) _notice(sources.first, '! ${m.warning}', kind: 2);
    _flushTimer ??= Timer(const Duration(milliseconds: 50), _flush);
  }

  void _finish(LogPhase p, [String? err]) {
    if (_disposed) return;
    _flush();
    phase = p;
    error = err ?? error;
    _sub = null;
    notifyListeners();
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_disposed) return;
    if (_pendingText.isNotEmpty) {
      for (var i = 0; i < _pendingText.length; i++) {
        if (_pendingMeta[i].kind == 0 && _pendingText[i].length > maxLen) maxLen = _pendingText[i].length;
      }
      dropped += lines.append(_pendingText);
      meta.append(_pendingMeta);
      _pendingText.clear();
      _pendingMeta.clear();
      invalidateRows();
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel();
    super.dispose();
  }
}

String aggregateId(String namespace, String? selector, List<String> pods) => 'agg/$namespace/${selector ?? ([...pods]..sort()).join(',')}';
