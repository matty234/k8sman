import 'dart:collection';

import 'dock_tab.dart';
import 'log_buffer.dart';

/// Maximum lines kept in memory per session; older lines are dropped.
const int kMaxLogLines = 10000;

/// How much history to load: the last [tail] lines (-1 = all), limited to
/// the last [since] seconds when set. Records compare by value.
typedef LogRange = ({int tail, int? since});

enum LogPhase { connecting, streaming, eof, error, notStarted }

/// What the log viewer shows and edits: a bounded line buffer with search
/// and view options. [LogStream] (one container) and [AggregateLogStream]
/// (many pods, merged) both extend it, so one viewer renders either.
abstract class LogSession extends DockTab {
  // Options; the subclass decides what changing them does.
  bool follow = true;
  bool get previous => false;
  bool timestamps = false;

  // View options (kept here so they survive tab switches and collapse).
  bool wrap = false;
  bool onlyMatching = false;
  String query = '';

  /// Treat [query] as a case-insensitive regular expression.
  bool regex = false;

  /// Show the newest line at the top (an app setting; the [LogDock] applies it).
  bool newestFirst = false;

  /// Only the last [since] seconds are loaded (null = the [tail] limit alone).
  int? since;

  RegExp? _re;
  String? _reError;
  String? _reSource;

  /// [query] compiled once per query change; null unless [regex] is on, the
  /// query is not empty and it is a valid pattern.
  RegExp? get queryRegex {
    if (!regex || query.isEmpty) return null;
    if (query != _reSource) {
      _reSource = query;
      try {
        _re = RegExp(query, caseSensitive: false);
        _reError = null;
      } on FormatException catch (e) {
        _re = null;
        _reError = e.message;
      }
    }
    return _re;
  }

  /// Whether the query is a regex that does not compile (it matches nothing).
  bool get regexInvalid => regex && query.isNotEmpty && queryRegex == null;

  /// The compile error of an invalid regex query.
  String? get regexError => regexInvalid ? _reError : null;

  /// The search term the line tests take: lower-cased unless it is a regex.
  String get needle => regex ? query : query.toLowerCase();

  /// The last [kMaxLogLines] lines, oldest first (a ring buffer: dropping
  /// the oldest costs nothing per flush).
  final LogBuffer<String> lines = LogBuffer<String>(kMaxLogLines);
  int dropped = 0;
  int maxLen = 0;
  LogPhase phase = LogPhase.connecting;
  String? error;

  /// True while the subscription is open (useful for tests).
  bool get isSubscribed;

  void reconnect();

  /// Extra characters shown beside each line (a source prefix, timestamps
  /// that are not part of the line text), for the horizontal extent.
  int get extraChars => 0;

  /// Whether line [idx] matches the lower-cased search [q].
  bool lineMatches(int idx, String q) {
    if (regex) return queryRegex?.hasMatch(lines[idx]) ?? false;
    return lines[idx].toLowerCase().contains(q);
  }

  /// The line indices to show, or null for all of them.
  List<int>? get visibleRows => onlyMatching && query.isNotEmpty ? matching : null;

  /// Text for "Copy all".
  String copyText() => lines.join('\n');

  /// The buffer is full, so older lines of the chosen range were dropped.
  bool get truncated => lines.length >= kMaxLogLines;

  /// Every line of the chosen range, fetched again without the buffer's
  /// cap (for downloads), or null where a session can't.
  Future<List<String>?> fetchFull() async => null;

  /// Text to save to a file: the rows being shown (only-matching), else
  /// every buffered line, oldest first.
  String exportText({bool all = false}) {
    final rows = all ? null : visibleRows;
    if (rows == null) return lines.join('\n');
    return [for (final i in rows) lines[i]].join('\n');
  }

  /// Default file name for "Download", without the extension.
  String get downloadBase;

  List<int>? _filtered;

  /// Drops cached row sets; call whenever lines, the query or filters change.
  void invalidateRows() => _filtered = null;

  // Matches are kept as line sequence numbers ([LogBuffer.firstSeq]-based)
  // for [_matchQuery], scanned up to [_matchedTo]: new lines are searched as
  // they arrive instead of re-lowercasing the whole buffer on every flush.
  final Queue<int> _matchSeqs = Queue();
  String? _matchQuery;
  bool _matchRegex = false;
  int _matchedTo = 0;

  /// Forget incremental match state (a match criterion other than the query
  /// changed).
  void resetMatches() {
    _matchQuery = null;
    _filtered = null;
  }

  /// Indices of lines matching [query] (cached until lines/query change).
  List<int> get matching {
    if (_filtered != null) return _filtered!;
    final q = needle;
    if (q.isEmpty) return _filtered = const [];
    if (regex != _matchRegex || q != _matchQuery || _matchedTo < lines.firstSeq) {
      _matchQuery = q;
      _matchRegex = regex;
      _matchSeqs.clear();
      _matchedTo = lines.firstSeq;
    }
    while (_matchSeqs.isNotEmpty && _matchSeqs.first < lines.firstSeq) {
      _matchSeqs.removeFirst();
    }
    final first = lines.firstSeq;
    for (var seq = _matchedTo; seq < lines.nextSeq; seq++) {
      if (lineMatches(seq - first, q)) _matchSeqs.add(seq);
    }
    _matchedTo = lines.nextSeq;
    return _filtered = List.unmodifiable([for (final s in _matchSeqs) s - first]);
  }

  void setQuery(String q) {
    query = q;
    invalidateRows();
    notifyListeners();
  }

  void setView({bool? wrap, bool? onlyMatching, bool? regex, bool? newestFirst}) {
    if (wrap != null) this.wrap = wrap;
    if (onlyMatching != null) this.onlyMatching = onlyMatching;
    if (regex != null && regex != this.regex) {
      this.regex = regex;
      invalidateRows();
    }
    if (newestFirst != null) this.newestFirst = newestFirst;
    notifyListeners();
  }

  void clear() {
    dropped += lines.length;
    lines.clear();
    invalidateRows();
    maxLen = 0;
    notifyListeners();
  }
}
