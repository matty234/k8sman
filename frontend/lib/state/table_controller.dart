import 'dart:async';

import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../metrics/quantity.dart';

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
  bool loading = true;
  String? error;

  String filter = '';
  int? sortColumn;
  bool sortAscending = true;

  StreamSubscription<WatchMessage>? _sub;
  Timer? _retry;
  int _attempt = 0;
  bool _disposed = false;

  void _connect() {
    _sub?.cancel();
    _sub = api.watch(type.ref, namespace: type.namespaced ? namespace : null).listen(
      _onMessage,
      onError: (Object e) => _onDisconnect('$e'),
      onDone: () => _onDisconnect(null),
    );
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
        loading = false;
        error = null;
        _attempt = 0;
      case 'ADDED' || 'MODIFIED':
        _rows[m.row!.uid] = m.row!;
      case 'DELETED':
        _rows.remove(m.row!.uid);
      case 'ERROR':
        error = m.error;
        loading = false;
    }
    notifyListeners();
  }

  void _onDisconnect(String? err) {
    if (_disposed) return;
    if (err != null) error = 'Disconnected: $err';
    notifyListeners();
    final delay = Duration(milliseconds: (500 * (1 << _attempt.clamp(0, 5))));
    _attempt++;
    _retry?.cancel();
    _retry = Timer(delay, _connect);
  }

  void setFilter(String f) {
    filter = f;
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
      list.sort((a, b) {
        var cmp = compare(a.cells.elementAtOrNull(sc), b.cells.elementAtOrNull(sc));
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
    final an = num.tryParse('$a'), bn = num.tryParse('$b');
    if (an != null && bn != null) return an.compareTo(bn);
    return _cellText(a).compareTo(_cellText(b));
  }

  @override
  void dispose() {
    _disposed = true;
    _retry?.cancel();
    _sub?.cancel();
    super.dispose();
  }
}
