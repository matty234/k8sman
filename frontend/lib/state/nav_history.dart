import '../api/models.dart';
import 'app_state.dart';

/// Where the user is: the page, the kind's table, the namespace scope, the
/// open saved view and the object open in the inspector.
class NavLocation {
  final MainView view;
  final ResourceType? type;
  final NamespaceScope scope;
  final String? viewId;
  final DetailTarget? detail;
  const NavLocation(this.view, this.type, this.scope, this.viewId, this.detail);

  /// The same place ignoring the inspector.
  bool sameBase(NavLocation o) =>
      view == o.view &&
      type == o.type &&
      scope == o.scope &&
      viewId == o.viewId;

  @override
  bool operator ==(Object other) =>
      other is NavLocation && sameBase(other) && detail == other.detail;

  @override
  int get hashCode => Object.hash(view, type, scope, viewId, detail);
}

/// Browser-style back / forward list of [NavLocation]s.
class NavHistory {
  static const maxEntries = 100;
  final List<NavLocation> _entries = [];
  int _at = -1;
  DateTime? _lastPush;

  bool get canGoBack => _at > 0;
  bool get canGoForward => _at >= 0 && _at < _entries.length - 1;
  NavLocation? get current => _at < 0 ? null : _entries[_at];

  void clear() {
    _entries.clear();
    _at = -1;
    _lastPush = null;
  }

  /// Records [l] after the current entry (dropping any forward entries).
  /// With [replace], or when only the inspector target changed within
  /// [quick] of the last push (arrow-key row moves), it replaces the current
  /// entry instead.
  void record(
    NavLocation l,
    DateTime now, {
    bool replace = false,
    Duration quick = const Duration(milliseconds: 600),
  }) {
    final cur = current;
    if (cur == l) return;
    final rapid =
        cur != null &&
        cur.sameBase(l) &&
        cur.detail != null &&
        l.detail != null &&
        _lastPush != null &&
        now.difference(_lastPush!) < quick;
    if (cur != null && (replace || rapid)) {
      _entries[_at] = l;
      return;
    }
    _entries.removeRange(_at + 1, _entries.length);
    _entries.add(l);
    if (_entries.length > maxEntries) _entries.removeAt(0);
    _at = _entries.length - 1;
    _lastPush = now;
  }

  NavLocation? back() => canGoBack ? _entries[--_at] : null;
  NavLocation? forward() => canGoForward ? _entries[++_at] : null;
}
