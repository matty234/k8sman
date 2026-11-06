import 'dart:collection';

import 'dock_tab.dart';
import 'log_buffer.dart';

/// Maximum lines kept in memory per session; older lines are dropped.
const int kMaxLogLines = 10000;

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
  bool lineMatches(int idx, String q) => lines[idx].toLowerCase().contains(q);

  /// The line indices to show, or null for all of them.
  List<int>? get visibleRows => onlyMatching && query.isNotEmpty ? matching : null;

  /// Text for "Copy all".
  String copyText() => lines.join('\n');

  List<int>? _filtered;

  /// Drops cached row sets; call whenever lines, the query or filters change.
  void invalidateRows() => _filtered = null;

  // Matches are kept as line sequence numbers ([LogBuffer.firstSeq]-based)
  // for [_matchQuery], scanned up to [_matchedTo]: new lines are searched as
  // they arrive instead of re-lowercasing the whole buffer on every flush.
  final Queue<int> _matchSeqs = Queue();
  String? _matchQuery;
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
    final q = query.toLowerCase();
    if (q.isEmpty) return _filtered = const [];
    if (q != _matchQuery || _matchedTo < lines.firstSeq) {
      _matchQuery = q;
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

  void setView({bool? wrap, bool? onlyMatching}) {
    if (wrap != null) this.wrap = wrap;
    if (onlyMatching != null) this.onlyMatching = onlyMatching;
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
