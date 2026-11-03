import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../metrics/quantity.dart';
import 'cluster_error.dart';

/// Keeps a live table for one resource type + namespace via /api/watch,
/// reconnecting with backoff. Also owns client-side filter and sort state.
class TableController extends ChangeNotifier {
  final ApiClient api;
  final ResourceType type;
  final String? namespace;

  TableController({required this.api, required this.type, this.namespace}) {
    _connect();
  }

  List<ColumnDef> columns = const [];
  bool isDefaultColumns = true;
  Map<int, String> columnErrors = const {};
  final Map<String, TableRowData> _rows = {};

  /// True until the first SNAPSHOT, or until a failure has lasted
  /// [failureDebounce] (so reconnects don't flash an error).
  bool get loading => !loaded && !failureShown;

  /// A SNAPSHOT has arrived at least once.
  bool loaded = false;

  /// The current list/watch failure, cleared by the next SNAPSHOT.
  ClusterError? failure;

  /// [failure] has persisted for [failureDebounce]: show it.
  bool failureShown = false;

  /// The failure message, for the inline banner over stale rows.
  String? get error => failureShown ? failure?.message : null;

  static Duration failureDebounce = const Duration(seconds: 1);

  String filter = '';
  int? sortColumn;
  bool sortAscending = true;

  StreamSubscription<WatchMessage>? _sub;
  Timer? _retry;
  Timer? _failureTimer;
  int _attempt = 0;
  bool _disposed = false;

  void _connect() {
    _sub?.cancel();
    _sub = api.watch(type.ref, namespace: type.namespaced ? namespace : null).listen(
      _onMessage,
      onError: (Object e) => _onDisconnect(ClusterError.fromException(e)),
      onDone: () => _onDisconnect(null),
    );
  }

  /// Reconnect now (the Retry button), keeping rows and the shown failure
  /// until the result is in.
  void retry() {
    if (_disposed) return;
    _attempt = 0;
    _retry?.cancel();
    _connect();
  }

  void _setFailure(ClusterError f) {
    failure = f;
    if (failureShown || _failureTimer != null) return;
    _failureTimer = Timer(failureDebounce, () {
      _failureTimer = null;
      if (_disposed || failure == null) return;
      failureShown = true;
      notifyListeners();
    });
  }

  void _clearFailure() {
    failure = null;
    failureShown = false;
    _failureTimer?.cancel();
    _failureTimer = null;
  }

  void _onMessage(WatchMessage m) {
    switch (m.type) {
      case 'SNAPSHOT':
        final t = m.table!;
        columns = t.columns;
        isDefaultColumns = t.isDefaultColumns;
        columnErrors = t.columnErrors;
        _rows
          ..clear()
          ..addEntries(t.rows.map((r) => MapEntry(r.uid, r)));
        loaded = true;
        _clearFailure();
        _attempt = 0;
        _pruneSelection();
      case 'ADDED' || 'MODIFIED':
        _rows[m.row!.uid] = m.row!;
      case 'DELETED':
        _rows.remove(m.row!.uid);
        _pruneSelection();
      case 'ERROR':
        _setFailure(ClusterError.fromWatch(m));
    }
    notifyListeners();
  }

  void _onDisconnect(ClusterError? err) {
    if (_disposed) return;
    // A clean close after an ERROR frame keeps that (more specific) error.
    if (err != null) _setFailure(err);
    notifyListeners();
    final delay = Duration(milliseconds: (500 * (1 << _attempt.clamp(0, 5))));
    _attempt++;
    _retry?.cancel();
    _retry = Timer(delay, _connect);
  }

  // ---- selection ----

  /// Selected rows by UID. A plain click selects one row (and opens it in
  /// the inspector); ⌘-click toggles, ⇧-click selects a range from [anchor].
  final Set<String> selection = {};

  /// Where ⇧-click / ⇧↑↓ ranges start.
  String? anchor;

  /// The row ⇧↑/⇧↓ last extended to (the moving end of the range).
  String? cursor;

  /// Selected rows in display order (visible rows only).
  List<TableRowData> get selectedRows => [for (final r in rows) if (selection.contains(r.uid)) r];

  bool isSelected(String uid) => selection.contains(uid);

  void selectOnly(String uid) {
    selection
      ..clear()
      ..add(uid);
    anchor = cursor = uid;
    notifyListeners();
  }

  void toggleSelected(String uid) {
    if (!selection.remove(uid)) selection.add(uid);
    anchor = cursor = uid;
    notifyListeners();
  }

  /// Select from [anchor] to [uid] in the current sorted/filtered order.
  void selectRange(String uid) {
    final visible = rows;
    final to = visible.indexWhere((r) => r.uid == uid);
    if (to < 0) return;
    var from = anchor == null ? -1 : visible.indexWhere((r) => r.uid == anchor);
    if (from < 0) {
      from = to;
      anchor = uid;
    }
    selection
      ..clear()
      ..addAll([for (var i = math.min(from, to); i <= math.max(from, to); i++) visible[i].uid]);
    cursor = uid;
    notifyListeners();
  }

  /// ⇧↑ / ⇧↓: move the range's moving end by [delta] rows.
  void extendSelection(int delta) {
    final visible = rows;
    if (visible.isEmpty) return;
    var at = cursor == null ? -1 : visible.indexWhere((r) => r.uid == cursor);
    if (at < 0) {
      selectOnly(visible[delta > 0 ? 0 : visible.length - 1].uid);
      return;
    }
    at = (at + delta).clamp(0, visible.length - 1);
    selectRange(visible[at].uid);
  }

  /// ⌘A: every visible (filtered) row.
  void selectAll() {
    final visible = rows;
    selection
      ..clear()
      ..addAll(visible.map((r) => r.uid));
    if (visible.isNotEmpty) {
      anchor = visible.first.uid;
      cursor = visible.last.uid;
    }
    notifyListeners();
  }

  void clearSelection() {
    if (selection.isEmpty) return;
    selection.clear();
    anchor = cursor = null;
    notifyListeners();
  }

  /// Deleted rows drop out; so do rows the filter hides (actions only ever
  /// apply to what's on screen).
  void _pruneSelection() {
    if (selection.isEmpty) return;
    final visible = {for (final r in rows) r.uid};
    selection.removeWhere((uid) => !visible.contains(uid));
    if (anchor != null && !visible.contains(anchor)) anchor = null;
    if (cursor != null && !visible.contains(cursor)) cursor = null;
  }

  void setFilter(String f) {
    filter = f;
    _pruneSelection();
    notifyListeners();
  }

  void sortBy(int col) {
    if (sortColumn == col) {
      sortAscending = !sortAscending;
    } else {
      sortColumn = col;
      sortAscending = true;
    }
    notifyListeners();
  }

  int get totalCount => _rows.length;

  /// Rows after filter + sort. Filter matches any cell (case-insensitive);
  /// a `key=value` filter matches only the named column.
  List<TableRowData> get rows {
    Iterable<TableRowData> r = _rows.values;
    final f = filter.trim().toLowerCase();
    if (f.isNotEmpty) {
      final eq = f.indexOf('=');
      int? colIdx;
      String needle = f;
      if (eq > 0) {
        final name = f.substring(0, eq).trim();
        final idx = columns.indexWhere((c) => c.name.toLowerCase() == name);
        if (idx >= 0) {
          colIdx = idx;
          needle = f.substring(eq + 1).trim();
        }
      }
      r = r.where((row) {
        if (colIdx != null) return _cellText(row.cells.elementAtOrNull(colIdx)).toLowerCase().contains(needle);
        return row.name.toLowerCase().contains(needle) || row.cells.any((c) => _cellText(c).toLowerCase().contains(needle));
      });
    }
    final list = r.toList();
    final sc = sortColumn;
    if (sc != null && sc < columns.length) {
      final isAge = columns[sc].type == 'age';
      final compare = columns[sc].type == 'quantity' ? compareQuantities : _compare;
      bool empty(dynamic v) => v == null || (v is String && v.isEmpty);
      list.sort((a, b) {
        final x = a.cells.elementAtOrNull(sc), y = b.cells.elementAtOrNull(sc);
        // Empty cells stay at the bottom in both directions.
        if (empty(x) || empty(y)) return empty(x) == empty(y) ? 0 : (empty(x) ? 1 : -1);
        var cmp = compare(x, y);
        if (isAge) cmp = -cmp; // newest timestamp = smallest age
        return sortAscending ? cmp : -cmp;
      });
    } else {
      list.sort((a, b) {
        final ns = (a.namespace ?? '').compareTo(b.namespace ?? '');
        return ns != 0 ? ns : a.name.compareTo(b.name);
      });
    }
    return list;
  }

  static String _cellText(dynamic v) => v == null ? '' : (v is List ? v.join(', ') : '$v');

  static int _compare(dynamic a, dynamic b) {
    if (a == null && b == null) return 0;
    if (a == null) return 1;
    if (b == null) return -1;
    if (a is num && b is num) return a.compareTo(b);
    // Numbers and Kubernetes quantities ("10Gi" > "2Gi", "500m" < "1")
    // compare by value, not as text.
    final an = parseQuantity(a), bn = parseQuantity(b);
    if (an != null && bn != null) return an.compareTo(bn);
    return _cellText(a).compareTo(_cellText(b));
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _failureTimer?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
