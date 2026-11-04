import 'dart:async';

import '../api/client.dart';
import '../api/models.dart';

/// How a resource kind's table was left: sort, column widths and filter.
class TablePrefs {
  String? sortColumn;
  bool sortDescending = false;

  /// Column name → the width the user dragged it to.
  final Map<String, double> widths = {};
  String filter = '';

  TablePrefs();

  factory TablePrefs.fromJson(Json j) {
    final p = TablePrefs()
      ..sortColumn = (j['sortColumn'] as String?)?.isNotEmpty == true ? j['sortColumn'] as String : null
      ..sortDescending = j['sortDescending'] == true
      ..filter = (j['filter'] as String?) ?? '';
    final w = j['widths'];
    if (w is Map) {
      for (final e in w.entries) {
        if (e.value is num) p.widths['${e.key}'] = (e.value as num).toDouble();
      }
    }
    return p;
  }

  bool get isEmpty => sortColumn == null && widths.isEmpty && filter.isEmpty;

  Json toJson() => {
    if (sortColumn != null) 'sortColumn': sortColumn,
    if (sortDescending) 'sortDescending': true,
    if (widths.isNotEmpty) 'widths': widths,
    if (filter.isNotEmpty) 'filter': filter,
  };
}

/// Table preferences per resource kind (keyed by `ResourceType.gk`), kept in
/// the backend's settings file so tables come back as they were left, across
/// navigation and launches. Changes made in one go (one event) are saved
/// together; column drags save once, at the end of the drag.
class TablePrefsStore {
  final ApiClient api;
  TablePrefsStore(this.api);

  final Map<String, TablePrefs> _prefs = {};

  /// Kinds changed this session (loading doesn't overwrite them).
  final Set<String> _changed = {};
  final Set<String> _unsaved = {};

  /// Loads the saved preferences (once per backend connection). Failures
  /// leave the in-memory ones (e.g. an older backend without the endpoint).
  Future<void> load() async {
    try {
      final saved = await api.getTablePrefs();
      for (final e in saved.entries) {
        // Don't clobber a table already changed this session.
        if (!_changed.contains(e.key)) _prefs[e.key] = TablePrefs.fromJson(e.value);
      }
    } catch (_) {}
  }

  TablePrefs of(String kind) => _prefs.putIfAbsent(kind, TablePrefs.new);

  /// Call after changing [of]`(kind)`.
  void changed(String kind) {
    _changed.add(kind);
    if (!_unsaved.add(kind) || _unsaved.length > 1) return;
    scheduleMicrotask(() {
      for (final k in _unsaved.toList()) {
        final p = _prefs[k];
        api.putTablePrefs(k, p == null || p.isEmpty ? null : p.toJson()).catchError((Object _) {});
      }
      _unsaved.clear();
    });
  }
}
