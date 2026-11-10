import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../panels/pod/pod_logic.dart';
import '../util/k8s.dart';
import 'dock_tab.dart';
import 'aggregate_log_stream.dart';
import 'log_session.dart';
import 'namespace_scope.dart';

export 'aggregate_log_stream.dart';
export 'dock_tab.dart';
export 'log_session.dart';

/// One (pod, container) log stream. Owns its subscription and buffer, so it
/// keeps streaming while its tab is hidden or the dock is collapsed. The
/// [LogDock] disposes it (cancelling the subscription) when the tab closes.
class LogStream extends LogSession {
  final ApiClient api;
  @override
  final String namespace;
  @override
  final String pod;
  String _container;
  String get container => _container;

  /// Last known pod object (container list, statuses). Refreshed while
  /// waiting for a container to start.
  Json podObject;

  // Changing any option resubscribes.
  @override
  bool previous;
  int tail = 500;

  final List<String> _pending = [];

  StreamSubscription<LogMessage>? _sub;
  Timer? _flushTimer;
  Timer? _startPoll;
  bool _disposed = false;

  LogStream({required this.api, required this.namespace, required this.pod, required String container, required this.podObject, this.previous = false})
    // ignore: prefer_initializing_formals
    : _container = container {
    _subscribe();
  }

  @override
  String get id => logStreamId(namespace, pod, _container);
  @override
  String get label => '$pod/$_container';
  @override
  String get downloadBase => '$pod-$_container';

  @override
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

  @override
  Future<List<String>?> fetchFull() async {
    final c = current;
    if (c == null) return null;
    final out = <String>[];
    // The same range and options, read to the end rather than followed.
    await for (final m in api.logs(namespace: namespace, pod: pod, container: c.name, tailLines: tail, sinceSeconds: since, previous: previous, follow: false, timestamps: timestamps)) {
      if (m.error != null) throw StateError(m.error!);
      if (m.line != null) out.add(m.line!);
      if (m.eof) break;
    }
    return out;
  }

  /// Change subscription options and reconnect.
  void setOptions({bool? follow, bool? previous, bool? timestamps, LogRange? range}) {
    if (follow != null) this.follow = follow;
    if (previous != null) this.previous = previous;
    if (timestamps != null) this.timestamps = timestamps;
    if (range != null) {
      tail = range.tail;
      since = range.since;
    }
    _subscribe();
    notifyListeners();
  }

  /// Only the [LogDock] calls this (the tab's identity changes). Keeps the
  /// previous-instance mode: if the new container has no previous instance
  /// the API says so, rather than silently showing current logs instead.
  void _setContainer(String name) {
    _container = name;
    _subscribe();
    notifyListeners();
  }

  @override
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
    invalidateRows();
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
    // A terminated instance has nothing to follow.
    _sub = api
        .logs(namespace: namespace, pod: pod, container: c.name, tailLines: tail, sinceSeconds: since, previous: previous, follow: follow && !previous, timestamps: timestamps)
        .listen(_onMessage, onError: (Object e) => _finish(LogPhase.error, '$e'), onDone: () => _finish(LogPhase.eof));
  }

  /// The dock has no live pod watch; poll the pod while the container is
  /// still waiting, then connect once it has started.
  void _pollUntilStarted() {
    _startPoll = Timer.periodic(const Duration(seconds: 3), (_) async {
      try {
        final o = await api.object(
          const ResourceRef(resource: 'pods'),
          namespace: namespace,
          name: pod,
        );
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
    _refreshPod();
  }

  /// A stream usually ends because the container stopped: refresh the pod so
  /// restart counts (and with them [canPrevious]) aren't those from when the
  /// tab was opened.
  Future<void> _refreshPod() async {
    try {
      final o = await api.object(
        const ResourceRef(resource: 'pods'),
        namespace: namespace,
        name: pod,
      );
      if (_disposed) return;
      podObject = o;
      notifyListeners();
    } catch (_) {
      // Keep the last known pod.
    }
  }

  void _flush() {
    _flushTimer?.cancel();
    _flushTimer = null;
    if (_disposed || _pending.isEmpty) return;
    for (final l in _pending) {
      if (l.length > maxLen) maxLen = l.length;
    }
    dropped += lines.append(_pending);
    _pending.clear();
    invalidateRows();
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

/// Fixed panes at the start of the dock strip, before the closable tabs.
enum DockPane { issues, alerts, forwards }

/// The bottom dock: a permanent bar along the main column with its fixed
/// panes (Alerts, Forwards) first, then open tabs (log streams and terminal sessions), the active
/// one, and the panel's height / collapsed state. Not persisted across launches.
class LogDock extends ChangeNotifier {
  final ApiClient api;
  LogDock(this.api);

  /// Newest line at the top (an app setting in settings.json; new tabs start
  /// with it and changing it applies to every open one).
  bool newestFirst = false;

  /// Colour JSON / logfmt lines (an app setting, on by default).
  bool colourSyntax = true;
  Future<void> _prefSaves = Future.value();

  Future<void> loadPrefs() async {
    try {
      newestFirst = await api.getLogNewestFirst();
      colourSyntax = await api.getLogColourSyntax();
      for (final t in _tabs.whereType<LogSession>()) {
        t.setView(newestFirst: newestFirst);
      }
      notifyListeners();
    } catch (e) {
      debugPrint('log preferences: $e');
    }
  }

  void setColourSyntax(bool v) {
    colourSyntax = v;
    notifyListeners();
    _prefSaves = _prefSaves.then((_) => api.putLogColourSyntax(v)).catchError((Object e) => debugPrint('save log preferences: $e'));
  }

  void setNewestFirst(bool v) {
    newestFirst = v;
    for (final t in _tabs.whereType<LogSession>()) {
      t.setView(newestFirst: v);
    }
    notifyListeners();
    _prefSaves = _prefSaves.then((_) => api.putLogNewestFirst(v)).catchError((Object e) => debugPrint('save log preferences: $e'));
  }

  static const double minHeight = 120;
  static const double defaultHeight = 280;

  final List<DockTab> _tabs = [];
  List<DockTab> get tabs => List.unmodifiable(_tabs);

  String? _activeId;

  /// The visible tab of any kind (null while a fixed pane is showing).
  DockTab? get activeTab => pane != null ? null : _selectedTab;

  DockTab? get _selectedTab {
    for (final t in _tabs) {
      if (t.id == _activeId) return t;
    }
    return _tabs.isEmpty ? null : _tabs.last;
  }

  /// The visible tab if it is a log stream (null when a terminal is shown).
  LogStream? get active {
    final t = activeTab;
    return t is LogStream ? t : null;
  }

  /// The fixed pane showing instead of a log or terminal tab, if any.
  DockPane? pane;

  bool get alertsOpen => pane == DockPane.alerts;

  /// Bumped when a port-forward starts, so the Forwards tab can pulse once
  /// (and refresh its badge) without taking the panel over.
  final ValueNotifier<int> forwardsPulse = ValueNotifier(0);

  void notifyForwardStarted() => forwardsPulse.value++;

  /// Collapsed to its tab strip (the bar itself always stays).
  bool collapsed = true;

  double height = defaultHeight;

  LogStream? find(String namespace, String pod, String container) {
    final id = logStreamId(namespace, pod, container);
    for (final t in _tabs) {
      if (t is LogStream && t.id == id) return t;
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
      s = LogStream(api: api, namespace: ns, pod: name, container: c, podObject: podObject, previous: previous)..newestFirst = newestFirst;
      _tabs.add(s);
    } else {
      s.podObject = podObject;
      // "View logs" and "Previous instance" both reuse the tab: switch it to
      // the instance asked for.
      if (previous != s.previous) s.setOptions(previous: previous);
    }
    if (focus || _activeId == null) _activeId = s.id;
    if (focus) pane = null;
    collapsed = false;
    notifyListeners();
    return s;
  }

  /// Opens (or focuses, if already open) one tab merging the logs of every
  /// pod matching [selector] / [selectors] (unioned) and [podRegex], or of
  /// exactly [pods]; the tab follows pods as they come and go. [namespace]
  /// (or [scope], several namespaces; empty = all) says where to look.
  /// [title] is e.g. `deploy/web`.
  AggregateLogStream openAggregate(
    String namespace, {
    NamespaceScope? scope,
    String? selector,
    List<String> selectors = const [],
    List<String> pods = const [],
    String? podRegex,
    String? containerRegex,
    String? title,
    bool? allContainers,
    int? tail,
    int? since,
    bool focus = true,
  }) {
    final sc = scope ?? NamespaceScope.single(namespace);
    final sels = [?selector, ...selectors];
    final id = aggregateId(sc, sels, pods, podRegex, containerRegex);
    var s = _tabs.whereType<AggregateLogStream>().where((t) => t.id == id).firstOrNull;
    if (s == null) {
      s = AggregateLogStream(
        api: api,
        scope: sc,
        selectors: sels,
        podNames: pods,
        podRegex: podRegex,
        containerRegex: containerRegex,
        title: title,
        allContainers: allContainers ?? false,
        tail: tail,
        since: since,
      )..newestFirst = newestFirst;
      _tabs.add(s);
    } else if (allContainers != null && allContainers != s.allContainers) {
      s.setOptions(allContainers: allContainers);
    } else if (s.phase == LogPhase.error || s.phase == LogPhase.eof) {
      s.reconnect();
    }
    if (focus || _activeId == null) _activeId = s.id;
    if (focus) pane = null;
    collapsed = false;
    notifyListeners();
    return s;
  }

  /// Adds a tab of any kind (e.g. a terminal), focuses it and expands the dock.
  void add(DockTab tab, {bool focus = true}) {
    if (!_tabs.contains(tab)) _tabs.add(tab);
    if (focus || _activeId == null) _activeId = tab.id;
    if (focus) pane = null;
    collapsed = false;
    notifyListeners();
  }

  void activate(DockTab s) {
    _activeId = s.id;
    pane = null;
    if (collapsed) collapsed = false;
    notifyListeners();
  }

  /// Shows (and expands to) a fixed pane.
  void showPane(DockPane p) {
    pane = p;
    collapsed = false;
    notifyListeners();
  }

  /// A fixed pane's tab: opens it, or collapses the dock if it's showing.
  void togglePane(DockPane p) {
    if (pane == p && !collapsed) {
      collapsed = true;
      notifyListeners();
    } else {
      showPane(p);
    }
  }

  /// Switches the stream's container. If that stream is already open in
  /// another tab, focuses it instead.
  void switchContainer(LogStream s, String container) {
    if (container == s.container) return;
    final existing = find(s.namespace, s.pod, container);
    if (existing != null) return activate(existing);
    final wasActive = _selectedTab == s;
    s._setContainer(container);
    if (wasActive) _activeId = s.id;
    notifyListeners();
  }

  void close(DockTab s) {
    final i = _tabs.indexOf(s);
    if (i < 0) return;
    _tabs.removeAt(i);
    if (_activeId == s.id) _activeId = _tabs.isEmpty ? null : _tabs[i.clamp(0, _tabs.length - 1)].id;
    s.dispose();
    if (_tabs.isEmpty && pane == null) collapsed = true;
    notifyListeners();
  }

  void closeOthers(DockTab keep) {
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
    if (pane == null) collapsed = true;
    notifyListeners();
  }

  /// ⌘J: toggle the dock between expanded and its tab strip. With nothing
  /// open it expands to the Alerts pane.
  void toggle() {
    collapsed = !collapsed;
    if (!collapsed && _tabs.isEmpty) pane ??= DockPane.alerts;
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
    forwardsPulse.dispose();
    super.dispose();
  }
}
