import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../panels/pod/pod_logic.dart';
import '../util/k8s.dart';

/// Maximum lines kept in memory per stream; older lines are dropped.
const int kMaxLogLines = 10000;

enum LogPhase { connecting, streaming, eof, error, notStarted }

/// One (pod, container) log stream. Owns its subscription and buffer, so it
/// keeps streaming while its tab is hidden or the dock is collapsed. The
/// [LogDock] disposes it (cancelling the subscription) when the tab closes.
class LogStream extends ChangeNotifier {
  final ApiClient api;
  final String namespace;
  final String pod;
  String _container;
  String get container => _container;

  /// Last known pod object (container list, statuses). Refreshed while
  /// waiting for a container to start.
  Json podObject;

  // Options; changing any of these resubscribes.
  bool follow = true;
  bool previous;
  bool timestamps = false;
  int tail = 500;

  // View options (kept here so they survive tab switches and collapse).
  bool wrap = false;
  bool onlyMatching = false;
  String query = '';

  final List<String> lines = [];
  final List<String> _pending = [];
  int dropped = 0;
  int maxLen = 0;
  LogPhase phase = LogPhase.connecting;
  String? error;

  StreamSubscription<LogMessage>? _sub;
  Timer? _flushTimer;
  Timer? _startPoll;
  List<int>? _filtered;
  bool _disposed = false;

  LogStream({required this.api, required this.namespace, required this.pod, required String container, required this.podObject, this.previous = false})
      // ignore: prefer_initializing_formals
      : _container = container {
    _subscribe();
  }

  String get id => logStreamId(namespace, pod, _container);
  String get label => '$pod/$_container';

  /// True while the subscription is open (useful for tests).
  bool get isSubscribed => _sub != null;

  List<PodContainer> get containers => podContainers(podObject);
  PodContainer? get current {
    for (final c in containers) {
      if (c.name == _container) return c;
    }
    return null;
  }

  bool get canPrevious {
    final c = current;
    return (c?.restarts ?? 0) > 0 || (c?.lastTerminated.isNotEmpty ?? false);
  }

  /// Indices of lines matching [query] (cached until lines/query change).
  List<int> get matching {
    if (_filtered != null) return _filtered!;
    final q = query.toLowerCase();
    return _filtered = [
      for (var i = 0; i < lines.length; i++)
        if (q.isNotEmpty && lines[i].toLowerCase().contains(q)) i,
    ];
  }

  void setQuery(String q) {
    query = q;
    _filtered = null;
    notifyListeners();
  }

  void setView({bool? wrap, bool? onlyMatching}) {
    if (wrap != null) this.wrap = wrap;
    if (onlyMatching != null) this.onlyMatching = onlyMatching;
    notifyListeners();
  }

  /// Change subscription options and reconnect.
  void setOptions({bool? follow, bool? previous, bool? timestamps, int? tail}) {
    if (follow != null) this.follow = follow;
    if (previous != null) this.previous = previous;
    if (timestamps != null) this.timestamps = timestamps;
    if (tail != null) this.tail = tail;
    _subscribe();
    notifyListeners();
  }

  /// Only the [LogDock] calls this (the tab's identity changes).
  void _setContainer(String name) {
    _container = name;
    if (previous && !canPrevious) previous = false;
    _subscribe();
    notifyListeners();
  }

  void clear() {
    dropped += lines.length;
    lines.clear();
    _filtered = null;
    maxLen = 0;
    notifyListeners();
  }

  void reconnect() {
    _subscribe();
    notifyListeners();
  }

  void _cancel() {
    _sub?.cancel();
    _sub = null;
    _flushTimer?.cancel();
    _flushTimer = null;
    _startPoll?.cancel();
    _startPoll = null;
  }

  void _subscribe() {
    _cancel();
    lines.clear();
    _pending.clear();
    dropped = 0;
    maxLen = 0;
    _filtered = null;
    error = null;
    final c = current;
    if (c == null) {
      phase = LogPhase.error;
      error = 'Container $_container not found in pod $pod';
      return;
    }
    if (!c.everStarted && !previous) {
      phase = LogPhase.notStarted;
      _pollUntilStarted();
      return;
    }
    phase = LogPhase.connecting;
    _sub = api
        .logs(namespace: namespace, pod: pod, container: c.name, tailLines: tail, previous: previous, follow: follow, timestamps: timestamps)
        .listen(_onMessage, onError: (Object e) => _finish(LogPhase.error, '$e'), onDone: () => _finish(LogPhase.eof));
  }

  /// The dock has no live pod watch; poll the pod while the container is
  /// still waiting, then connect once it has started.
  void _pollUntilStarted() {
    _startPoll = Timer.periodic(const Duration(seconds: 3), (_) async {
      try {
        final o = await api.object(const ResourceRef(resource: 'pods'), namespace: namespace, name: pod);
        if (_disposed || phase != LogPhase.notStarted) return;
        podObject = o;
        if (current?.everStarted ?? false) _subscribe();
        notifyListeners();
      } catch (_) {
        // Keep polling; the pod may not be visible yet.
      }
    });
  }

  void _onMessage(LogMessage m) {
    if (m.error != null) return _finish(LogPhase.error, m.error);
    if (m.eof) return _finish(LogPhase.eof);
    final line = m.line;
    if (line == null) return;
    _pending.add(line.endsWith('\n') ? line.substring(0, line.length - (line.endsWith('\r\n') ? 2 : 1)) : line);
    _flushTimer ??= Timer(const Duration(milliseconds: 50), _flush);
  }

  void _finish(LogPhase p, [String? err]) {
    if (_disposed) return;
    if (phase == LogPhase.error || (phase == LogPhase.eof && p == LogPhase.eof)) return;
    _flush();
    phase = p;
    error = err;
    _sub = null;
    notifyListeners();
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_disposed || _pending.isEmpty) return;
    for (final l in _pending) {
      if (l.length > maxLen) maxLen = l.length;
    }
    lines.addAll(_pending);
    _pending.clear();
    if (lines.length > kMaxLogLines) {
      final n = lines.length - kMaxLogLines;
      lines.removeRange(0, n);
      dropped += n;
    }
    _filtered = null;
    if (phase == LogPhase.connecting) phase = LogPhase.streaming;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _cancel();
    super.dispose();
  }
}

String logStreamId(String namespace, String pod, String container) => '$namespace/$pod/$container';

/// Picks the container a "Logs" action should open: the first troubled
/// regular container that has run, else the first regular one.
String? defaultLogContainer(Json pod) {
  final cs = podContainers(pod);
  final regular = cs.where((c) => c.kind == ContainerKind.regular).toList();
  final troubled = regular.where((c) => c.hasProblem && c.everStarted);
  return (troubled.isNotEmpty ? troubled.first : (regular.isNotEmpty ? regular.first : (cs.isNotEmpty ? cs.first : null)))?.name;
}

/// The bottom log dock: open streams (one tab each), the active tab, and the
/// panel's height / collapsed state. Not persisted across launches.
class LogDock extends ChangeNotifier {
  final ApiClient api;
  LogDock(this.api);

  static const double minHeight = 120;
  static const double defaultHeight = 280;

  final List<LogStream> _tabs = [];
  List<LogStream> get tabs => List.unmodifiable(_tabs);

  String? _activeId;
  LogStream? get active {
    for (final t in _tabs) {
      if (t.id == _activeId) return t;
    }
    return _tabs.isEmpty ? null : _tabs.last;
  }

  /// Whether the dock is on screen at all.
  bool shown = false;

  /// Collapsed to its tab strip.
  bool collapsed = false;

  double height = defaultHeight;

  LogStream? find(String namespace, String pod, String container) {
    final id = logStreamId(namespace, pod, container);
    for (final t in _tabs) {
      if (t.id == id) return t;
    }
    return null;
  }

  /// Opens (or focuses, if already open) the stream for [container] of [podObject],
  /// and expands the dock.
  LogStream open(Json podObject, {String? container, bool previous = false, bool focus = true}) {
    final ns = dig<String>(podObject, ['metadata', 'namespace']) ?? '';
    final name = dig<String>(podObject, ['metadata', 'name']) ?? '';
    final c = container ?? defaultLogContainer(podObject) ?? '';
    var s = find(ns, name, c);
    if (s == null) {
      s = LogStream(api: api, namespace: ns, pod: name, container: c, podObject: podObject, previous: previous);
      _tabs.add(s);
    } else {
      s.podObject = podObject;
      if (previous && !s.previous) s.setOptions(previous: true);
    }
    if (focus || _activeId == null) _activeId = s.id;
    shown = true;
    collapsed = false;
    notifyListeners();
    return s;
  }

  void activate(LogStream s) {
    _activeId = s.id;
    if (collapsed) collapsed = false;
    notifyListeners();
  }

  /// Switches the stream's container. If that stream is already open in
  /// another tab, focuses it instead.
  void switchContainer(LogStream s, String container) {
    if (container == s.container) return;
    final existing = find(s.namespace, s.pod, container);
    if (existing != null) return activate(existing);
    final wasActive = active == s;
    s._setContainer(container);
    if (wasActive) _activeId = s.id;
    notifyListeners();
  }

  void close(LogStream s) {
    final i = _tabs.indexOf(s);
    if (i < 0) return;
    _tabs.removeAt(i);
    if (_activeId == s.id) _activeId = _tabs.isEmpty ? null : _tabs[i.clamp(0, _tabs.length - 1)].id;
    s.dispose();
    if (_tabs.isEmpty) shown = false;
    notifyListeners();
  }

  void closeOthers(LogStream keep) {
    for (final t in [..._tabs]) {
      if (t != keep) {
        _tabs.remove(t);
        t.dispose();
      }
    }
    _activeId = keep.id;
    notifyListeners();
  }

  void closeAll() {
    for (final t in _tabs) {
      t.dispose();
    }
    _tabs.clear();
    _activeId = null;
    shown = false;
    notifyListeners();
  }

  /// ⌘J: show the dock, or toggle it between expanded and its tab strip.
  /// With no tabs it toggles between hidden and an empty panel.
  void toggle() {
    if (!shown) {
      shown = true;
      collapsed = false;
    } else if (_tabs.isEmpty) {
      shown = false;
    } else {
      collapsed = !collapsed;
    }
    notifyListeners();
  }

  void setCollapsed(bool v) {
    collapsed = v;
    notifyListeners();
  }

  void setHeight(double h) {
    height = h;
    notifyListeners();
  }

  @override
  void dispose() {
    for (final t in _tabs) {
      t.dispose();
    }
    super.dispose();
  }
}
