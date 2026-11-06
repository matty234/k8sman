import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';

import '../api/models.dart';
import 'namespace_scope.dart';

/// The context a view is bound to: (kubeconfig path, context name). The
/// API server URL lets a view be re-pointed when the context is renamed.
@immutable
class ViewContext {
  /// '' = the default loading rules ($KUBECONFIG / ~/.kube/config).
  final String kubeconfig;
  final String name;
  final String? server;
  const ViewContext({this.kubeconfig = '', required this.name, this.server});

  factory ViewContext.fromJson(Json j) => ViewContext(
        kubeconfig: (j['kubeconfig'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        server: (j['server'] as String?)?.isNotEmpty == true ? j['server'] as String : null,
      );

  Json toJson() => {'kubeconfig': kubeconfig, 'name': name, 'server': ?server};

  @override
  bool operator ==(Object other) => other is ViewContext && other.kubeconfig == kubeconfig && other.name == name && other.server == server;
  @override
  int get hashCode => Object.hash(kubeconfig, name, server);
}

/// A saved table: a kind, a namespace scope, a filter, a sort and its own
/// columns, on one context or on any context (docs/VIEWS.md).
@immutable
class SavedView {
  /// The record version this build reads and writes.
  static const currentVersion = 1;

  final String id;
  final String name;

  /// null = applies to any context.
  final ViewContext? context;
  final String group;
  final String kind;

  /// Sorted; empty = all namespaces.
  final List<String> namespaces;
  final String filter;
  final String? sortColumn;
  final bool sortDescending;

  /// The view's own column set and order (null = the kind's columns).
  final List<ColumnDef>? columns;

  const SavedView({
    required this.id,
    required this.name,
    this.context,
    required this.group,
    required this.kind,
    this.namespaces = const [],
    this.filter = '',
    this.sortColumn,
    this.sortDescending = false,
    this.columns,
  });

  /// `group/Kind`, as [ResourceType.gk].
  String get gk => '$group/$kind';

  NamespaceScope get scope => NamespaceScope.of(namespaces);

  bool get anyContext => context == null;

  /// Null for records written by a newer version of the app (they stay in
  /// settings.json untouched) and for malformed ones.
  static SavedView? fromJson(Json j) {
    final v = j['version'];
    if (v is! num || v.toInt() != currentVersion) return null;
    final kind = j['kind'];
    if (kind is! Map || '${kind['kind'] ?? ''}'.isEmpty || '${j['id'] ?? ''}'.isEmpty) return null;
    final sort = j['sort'];
    final cols = j['columns'];
    return SavedView(
      id: '${j['id']}',
      name: '${j['name'] ?? ''}',
      context: j['context'] is Map ? ViewContext.fromJson(Map<String, dynamic>.from(j['context'] as Map)) : null,
      group: '${kind['group'] ?? ''}',
      kind: '${kind['kind']}',
      namespaces: NamespaceScope.of([for (final n in (j['namespaces'] as List? ?? const [])) '$n']).namespaces,
      filter: (j['filter'] as String?) ?? '',
      sortColumn: sort is Map && '${sort['column'] ?? ''}'.isNotEmpty ? '${sort['column']}' : null,
      sortDescending: sort is Map && sort['descending'] == true,
      columns: cols is List ? [for (final c in cols) ColumnDef.fromJson(Map<String, dynamic>.from(c as Map))] : null,
    );
  }

  Json toJson() => {
        'version': currentVersion,
        'id': id,
        'name': name,
        'context': context?.toJson(),
        'kind': {'group': group, 'kind': kind},
        'namespaces': namespaces,
        if (filter.isNotEmpty) 'filter': filter,
        if (sortColumn != null) 'sort': {'column': sortColumn, if (sortDescending) 'descending': true},
        if (columns != null) 'columns': [for (final c in columns!) c.toJson()],
      };

  SavedView copyWith({
    String? id,
    String? name,
    ViewContext? Function()? context,
    List<String>? namespaces,
    String? filter,
    String? Function()? sortColumn,
    bool? sortDescending,
    List<ColumnDef>? Function()? columns,
  }) =>
      SavedView(
        id: id ?? this.id,
        name: name ?? this.name,
        context: context == null ? this.context : context(),
        group: group,
        kind: kind,
        namespaces: namespaces ?? this.namespaces,
        filter: filter ?? this.filter,
        sortColumn: sortColumn == null ? this.sortColumn : sortColumn(),
        sortDescending: sortDescending ?? this.sortDescending,
        columns: columns == null ? this.columns : columns(),
      );

  /// A fresh random id (16 hex digits).
  static String newId() {
    final r = Random.secure();
    return [for (var i = 0; i < 8; i++) r.nextInt(256).toRadixString(16).padLeft(2, '0')].join();
  }

  @override
  bool operator ==(Object other) => other is SavedView && jsonEncode(other.toJson()) == jsonEncode(toJson());
  @override
  int get hashCode => jsonEncode(toJson()).hashCode;
}

/// Column lists compare by name, query and type.
bool sameColumns(List<ColumnDef>? a, List<ColumnDef>? b) {
  if (a == null || b == null) return a == b;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i].name != b[i].name || a[i].query != b[i].query || a[i].type != b[i].type) return false;
  }
  return true;
}

/// An open view's table state. While it is open, filter, sort and column
/// changes land here instead of the kind's remembered preferences, so
/// opening a view never overwrites them. [modified] drives the header's
/// dot and its Update view / Revert buttons.
class ViewSession {
  /// The view as saved (replaced by Update view).
  SavedView view;
  String filter;
  String? sortColumn;
  bool sortDescending;
  List<ColumnDef>? columns;

  /// Called when [modified] may have changed.
  final VoidCallback onChanged;

  ViewSession(this.view, {required this.onChanged})
      : filter = view.filter,
        sortColumn = view.sortColumn,
        sortDescending = view.sortDescending,
        columns = view.columns;

  bool get modified =>
      filter.trim() != view.filter.trim() ||
      sortColumn != view.sortColumn ||
      (sortColumn != null && sortDescending != view.sortDescending) ||
      !sameColumns(columns, view.columns);

  void setFilter(String f) {
    final was = modified;
    filter = f;
    if (modified != was) onChanged();
  }

  void setSort(String? column, bool descending) {
    sortColumn = column;
    sortDescending = descending;
    onChanged();
  }

  /// Back to the view as saved.
  void revert() {
    filter = view.filter;
    sortColumn = view.sortColumn;
    sortDescending = view.sortDescending;
    columns = view.columns;
  }

  /// The view with this session's state (for Update view / Save as new).
  SavedView get current => view.copyWith(
        filter: filter.trim(),
        sortColumn: () => sortColumn,
        sortDescending: sortDescending,
        columns: () => columns,
      );
}
