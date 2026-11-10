import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../ui/overview/overview_api.dart';
import '../ui/widgets/namespace_picker.dart' show PageScope;
import 'app_state.dart';
import 'log_dock.dart';
import 'poller.dart';
import 'startup_gate.dart';

/// The Kubernetes-derived issues list, fetched once for everyone: the dock's
/// Issues tab and its badge read it instead of each polling `/api/overview`.
///
/// Scoped like the Overview page (its namespace picker). Polls every 30s,
/// every 15s while the Issues pane is showing; re-fetches at once when the
/// cluster context or the scope changes. The Overview page pushes its own
/// fresh results in through [accept].
class IssuesFeed extends ChangeNotifier {
  final ApiClient api;
  final AppState? app;
  final LogDock? dock;
  final OverviewApi _source;

  static const idle = Duration(seconds: 30);
  static const visible = Duration(seconds: 15);

  IssuesFeed(this.api, {this.app, this.dock, OverviewApi? source}) : _source = source ?? OverviewApi(api);

  OverviewData? _data;
  Object? _error;
  bool _loading = false;
  Poll? _poll;
  Timer? _quick;
  int _quickCount = 0;
  int _seq = 0;
  DateTime? _at;
  String? _ctx;
  NamespaceScope _scope = NamespaceScope.all;
  bool _disposed = false;

  OverviewData? get data => _data;
  List<OverviewIssue> get issues => _data?.issues ?? const [];
  bool get loading => _loading;
  Object? get error => _error;

  /// Some sources hadn't answered yet, so an empty list isn't "nothing wrong".
  bool get partial => _data?.loadingSections.isNotEmpty ?? false;

  int count(IssueSeverity s) => issues.where((i) => i.severity == s).length;

  /// Starts polling once the first table has painted.
  void start() {
    _ctx = app?.currentContext;
    _scope = PageScope.of('overview');
    app?.addListener(_onApp);
    PageScope.changes.addListener(_onScope);
    StartupGate.ready.then((_) {
      if (_disposed) return;
      _poll = Poll(interval: visible, onTick: _tick);
      refresh();
    });
  }

  Future<bool> _tick() async {
    final showing = dock?.pane == DockPane.issues && !(dock?.collapsed ?? true);
    final due = showing ? visible : idle;
    final at = _at;
    if (at != null && DateTime.now().difference(at) < due - const Duration(seconds: 1)) return _error == null;
    return refresh();
  }

  void _onApp() {
    final c = app?.currentContext;
    if (c == _ctx) return;
    _ctx = c;
    _reset();
  }

  void _onScope() {
    final s = PageScope.of('overview');
    if (s == _scope) return;
    _scope = s;
    _reset();
  }

  void _reset() {
    _data = null;
    _error = null;
    _at = null;
    _quickCount = 0;
    notifyListeners();
    refresh();
  }

  /// Fetches now. False when it failed (the poll backs off).
  Future<bool> refresh() async {
    if (_disposed) return true;
    final seq = ++_seq;
    _quick?.cancel();
    _loading = true;
    notifyListeners();
    try {
      final data = await _source.fetch(scope: _scope);
      if (_disposed || seq != _seq) return true;
      _set(data);
      return true;
    } catch (e) {
      if (_disposed || seq != _seq) return true;
      _error = e;
      _loading = false;
      notifyListeners();
      return false;
    }
  }

  /// A result somebody else fetched for [scope] (the Overview page).
  void accept(OverviewData data, NamespaceScope scope, String? context) {
    if (_disposed || scope != _scope || context != _ctx) return;
    _seq++; // an older fetch in flight is now stale
    _set(data);
  }

  void _set(OverviewData data) {
    _data = data;
    _error = null;
    _loading = false;
    _at = DateTime.now();
    notifyListeners();
    // The backend answers early with what it has: look again soon.
    if (data.pending.isNotEmpty && _quickCount < 3) {
      _quickCount++;
      _quick = Timer(Duration(milliseconds: 1500 * _quickCount), refresh);
    } else if (data.pending.isEmpty) {
      _quickCount = 0;
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _quick?.cancel();
    _poll?.dispose();
    app?.removeListener(_onApp);
    PageScope.changes.removeListener(_onScope);
    super.dispose();
  }
}
