import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../metrics/quantity.dart';
import 'cluster_error.dart';
import 'startup_gate.dart';
import 'table_query.dart';

/// Keeps a live table for one resource type + namespace via /api/watch,
/// reconnecting with backoff. Also owns client-side filter and sort state.
class TableController extends ChangeNotifier {
  final ApiClient api;
  final ResourceType type;
  final String? namespace;

  /// Sort per resource kind (column name, ascending), shared across this
  /// kind's tables so the sort survives navigating away and back, or
  /// switching namespace. Usually AppState.tableSorts.
  final Map<String, (String, bool)>? sortMemory;

  TableController({required this.api, required this.type, this.namespace, this.sortMemory}) {
    final remembered = sortMemory?[type.gk];
    if (remembered != null) {
      _pendingSort = remembered.$1;
      sortAscending = remembered.$2;
    }
    _connect();
  }

  /// A remembered sort column, applied once the columns are known.
  String? _pendingSort;

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
      StartupGate.firstContentShown();
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
    // A BATCH frame applies its events in order and notifies once.
    final prune = m.type == 'BATCH' ? m.events.fold(false, (p, e) => _apply(e) || p) : _apply(m);
    if (prune) _pruneSelection();
    notifyListeners();
  }

  /// Applies one frame; true when the selection may need pruning.
  bool _apply(WatchMessage m) {
    switch (m.type) {
      case 'SNAPSHOT':
        final t = m.table!;
        columns = t.columns;
        _applyPendingSort();
        isDefaultColumns = t.isDefaultColumns;
        columnErrors = t.columnErrors;
        _rows
          ..clear()
          ..addEntries(t.rows.map((r) => MapEntry(r.uid, r)));
        _rowsChanged();
        loaded = true;
        StartupGate.firstContentShown();
        _clearFailure();
        _attempt = 0;
        return true;
      case 'ADDED' || 'MODIFIED':
        final r = m.row;
        if (r == null) return false;
        _rows[r.uid] = r;
        _rowsChanged();
        return false;
      case 'DELETED':
        final r = m.row;
        if (r == null || _rows.remove(r.uid) == null) return false;
        _rowsChanged();
        return true;
      case 'ERROR':
        _setFailure(ClusterError.fromWatch(m));
    }
    return false;
  }

  /// Base and cap of the reconnect backoff.
  static const _backoffBase = Duration(milliseconds: 500);
  static const _backoffCap = Duration(seconds: 16);
  static final _random = math.Random();

  void _onDisconnect(ClusterError? err) {
    if (_disposed) return;
    // A clean close after an ERROR frame keeps that (more specific) error.
    if (err != null) _setFailure(err);
    notifyListeners();
    final delay = reconnectDelay(_attempt, _random);
    _attempt++;
    _retry?.cancel();
    _retry = Timer(delay, _connect);
  }

  /// Exponential backoff (500 ms doubling to 16 s) with "equal jitter": a
  /// random delay in [d/2, d], so many tables (and windows) that lost the
  /// backend together don't reconnect in lockstep.
  static Duration reconnectDelay(int attempt, math.Random random) {
    final d = math.min(_backoffBase.inMilliseconds * (1 << attempt.clamp(0, 5)), _backoffCap.inMilliseconds);
    return Duration(milliseconds: d ~/ 2 + random.nextInt(d ~/ 2 + 1));
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
  List<TableRowData> get selectedRows => selection.isEmpty ? const [] : [for (final r in rows) if (selection.contains(r.uid)) r];

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
    _pendingSort = null;
    if (col < columns.length) sortMemory?[type.gk] = (columns[col].name, sortAscending);
    notifyListeners();
  }

  void _applyPendingSort() {
    final name = _pendingSort;
    if (name == null) return;
    final i = columns.indexWhere((c) => c.name == name);
    if (i >= 0) {
      sortColumn = i;
      _pendingSort = null;
    }
  }

  /// Every row, unfiltered (for filter suggestions).
  Iterable<TableRowData> get allRows => _rows.values;

  int get totalCount => _rows.length;

  /// Bumped whenever [_rows] changes; part of the [rows] memo key.
  int _rowsVersion = 0;
  void _rowsChanged() => _rowsVersion++;

  List<TableRowData>? _memo;
  (int, String, int?, bool, List<ColumnDef>)? _memoKey;

  /// Rows after filter + sort. See [TableQuery] for the filter language.
  ///
  /// Memoised: recomputed only when the rows, filter, sort or columns
  /// changed, so the many reads per build (selection helpers, key handling)
  /// are free. The returned list is read-only.
  List<TableRowData> get rows {
    final key = (_rowsVersion, filter, sortColumn, sortAscending, columns);
    final m = _memoKey;
    if (_memo != null && m != null && m.$1 == key.$1 && m.$2 == key.$2 && m.$3 == key.$3 && m.$4 == key.$4 && identical(m.$5, key.$5)) return _memo!;
    _memoKey = key;
    debugRowsComputations++;
    return _memo = UnmodifiableListView(_computeRows());
  }

  /// How many times [rows] was actually recomputed (benchmarks, tests).
  @visibleForTesting
  int debugRowsComputations = 0;

  List<TableRowData> _computeRows() {
    Iterable<TableRowData> r = _rows.values;
    if (filter.trim().isNotEmpty) {
      final q = TableQuery.parse(filter, columns);
      final now = DateTime.now();
      r = r.where((row) => q.matches(row, now: now));
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

  static String _cellText(dynamic v) => cellText(v);

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
