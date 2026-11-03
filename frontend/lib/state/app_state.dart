import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';

/// What the main area shows.
enum MainView { overview, nodes, metrics, resources, portForwards }

/// An object shown in the detail sidebar.
class DetailTarget {
  final ResourceType type;
  final String name;
  final String? namespace;
  const DetailTarget({required this.type, required this.name, this.namespace});

  @override
  bool operator ==(Object other) =>
      other is DetailTarget && other.type == type && other.name == name && other.namespace == namespace;
  @override
  int get hashCode => Object.hash(type, name, namespace);
}

/// Global UI state: connection, context, discovered types, namespace filter,
/// selected resource type and the detail sidebar's navigation stack.
class AppState extends ChangeNotifier {
  final ApiClient api;
  AppState(this.api);

  bool loading = true;
  String? error;

  /// Backend started with --read-only: hide mutating UI.
  bool readOnly = false;

  String currentContext = '';
  List<ContextInfo> contexts = const [];
  List<ResourceType> types = const [];
  List<String> namespaces = const [];

  /// null = all namespaces.
  String? namespace;

  ResourceType? selectedType;

  MainView view = MainView.resources;

  void showView(MainView v) {
    if (v != view && detail != null) inspectorCollapsed = true;
    view = v;
    notifyListeners();
  }

  /// The inspector is open but collapsed to a slim tab on the right edge
  /// (set when the user moves to another kind or view, so the new table
  /// gets the width back).
  bool inspectorCollapsed = false;

  void collapseInspector() {
    if (detail == null || inspectorCollapsed) return;
    inspectorCollapsed = true;
    notifyListeners();
  }

  void expandInspector() {
    if (!inspectorCollapsed) return;
    inspectorCollapsed = false;
    notifyListeners();
  }

  /// ⌘I: collapse / expand the open inspector.
  void toggleInspector() => inspectorCollapsed ? expandInspector() : collapseInspector();

  final List<DetailTarget> _detailStack = [];
  DetailTarget? get detail => _detailStack.isEmpty ? null : _detailStack.last;
  bool get canGoBack => _detailStack.length > 1;

  /// Bumped when column config changes so tables re-subscribe.
  int columnsVersion = 0;

  Future<void> init() async {
    loading = true;
    error = null;
    notifyListeners();
    try {
      readOnly = await api.health().then((h) => h['readOnly'] == true, onError: (_) => false);
      final ctx = await api.contexts();
      currentContext = ctx.current;
      contexts = ctx.contexts;
      types = await api.resources();
      final ns = await api.namespaces();
      namespaces = ns.namespaces;
      namespace ??= ns.defaultNamespace?.isNotEmpty == true ? ns.defaultNamespace : null;
      selectedType ??= typeFor('', 'Pod');
    } catch (e) {
      error = '$e';
    }
    loading = false;
    notifyListeners();
  }

  Future<void> switchContext(String name) async {
    try {
      await api.switchContext(name);
      _detailStack.clear();
      namespace = null;
      selectedType = null;
      await init();
    } catch (e) {
      error = '$e';
      notifyListeners();
    }
  }

  Future<void> refreshTypes() async {
    types = await api.resources(refresh: true);
    notifyListeners();
  }

  /// Look up a discovered type by API group and Kind (core group = '').
  ResourceType? typeFor(String group, String kind) {
    for (final t in types) {
      if (t.group == group && t.kind == kind) return t;
    }
    return null;
  }

  ResourceType? typeForResource(String group, String resource) {
    for (final t in types) {
      if (t.group == group && t.resource == resource) return t;
    }
    return null;
  }

  void selectType(ResourceType t) {
    if (detail != null && (t != selectedType || view != MainView.resources)) inspectorCollapsed = true;
    selectedType = t;
    view = MainView.resources;
    notifyListeners();
  }

  void setNamespace(String? ns) {
    namespace = ns;
    notifyListeners();
  }

  /// Open an object from the table: replaces the sidebar stack.
  void openDetail(DetailTarget t) {
    _detailStack
      ..clear()
      ..add(t);
    inspectorCollapsed = false;
    notifyListeners();
  }

  /// Follow a reference from inside the sidebar (pushes onto the stack so the
  /// user can go back). Returns false if the kind isn't served by the cluster.
  bool openRef(ObjectRef ref) {
    final t = typeFor(ref.group, ref.kind);
    if (t == null) return false;
    final target = DetailTarget(type: t, name: ref.name, namespace: t.namespaced ? ref.namespace : null);
    if (detail == target) return true;
    _detailStack.add(target);
    notifyListeners();
    return true;
  }

  void back() {
    if (_detailStack.length > 1) {
      _detailStack.removeLast();
      notifyListeners();
    }
  }

  void closeDetail() {
    _detailStack.clear();
    inspectorCollapsed = false;
    notifyListeners();
  }

  void columnsChanged() {
    columnsVersion++;
    notifyListeners();
  }
}
