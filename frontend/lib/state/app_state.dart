import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'sidebar_config.dart';

export 'sidebar_config.dart';

/// What the main area shows.
enum MainView { overview, alerts, nodes, gpus, metrics, resources, portForwards, helm, security, addons, access }

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

  /// What [error] came from (an [ApiException], a socket error, …), so the
  /// UI can tell an unreachable cluster from rejected credentials.
  Object? errorCause;

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

  /// `namespace/name` of a release the Helm page should select next time it
  /// builds (set by [showHelmRelease], consumed by the page).
  String? helmFocus;

  void showHelmRelease(String namespace, String name) {
    helmFocus = '$namespace/$name';
    if (this.namespace != null && this.namespace != namespace) this.namespace = null;
    showView(MainView.helm);
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
    errorCause = null;
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
      errorCause = e;
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
      // Drop the old cluster's kinds so a failure shows the error screen.
      types = const [];
      await init();
    } catch (e) {
      error = '$e';
      errorCause = e;
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

  // ---- sidebar layout ----

  /// Which pages the sidebar shows, in what order, and pinned kinds.
  SidebarConfig sidebar = SidebarConfig.defaults;
  Future<void> _sidebarSaves = Future.value();

  /// Loads the saved layout (once per backend connection: it is an app
  /// setting, not per cluster). Keeps the current one if that fails.
  Future<void> loadSidebar() async {
    try {
      sidebar = SidebarConfig.fromJson(await api.getSidebar());
      notifyListeners();
    } catch (e) {
      debugPrint('sidebar layout: $e');
    }
  }

  /// Applies [c] now and saves it (in order, in the background). The
  /// default layout is saved as "no customisation".
  void setSidebar(SidebarConfig c) {
    sidebar = c;
    notifyListeners();
    final json = c.isDefault ? null : c.toJson();
    _sidebarSaves = _sidebarSaves.then((_) => api.putSidebar(json)).catchError((Object e) => debugPrint('save sidebar layout: $e'));
  }

  /// The discovered type a pin points at (null: not on this cluster).
  ResourceType? typeForPin(SidebarPin p) => typeFor(p.group, p.kind);

  /// Selects a pinned kind exactly as the kinds list does, switching to
  /// the pin's namespace if it has one.
  void openPin(SidebarPin p) {
    final t = typeForPin(p);
    if (t == null) return;
    if (p.namespace != null && t.namespaced && namespace != p.namespace) setNamespace(p.namespace);
    selectType(t);
  }

  /// The pin showing the current selection: one scoped to the current
  /// namespace wins over an unscoped pin of the same kind.
  SidebarPin? get selectedPin {
    final t = selectedType;
    if (view != MainView.resources || t == null) return null;
    SidebarPin? any;
    for (final p in sidebar.pins) {
      if (p.gk != t.gk) continue;
      if (p.namespace == null) {
        any ??= p;
      } else if (p.namespace == namespace) {
        return p;
      }
    }
    return any;
  }

  /// Namespaces chosen this session, most recent first (for the picker).
  final List<String> recentNamespaces = [];

  void setNamespace(String? ns) {
    namespace = ns;
    if (ns != null) {
      recentNamespaces
        ..remove(ns)
        ..insert(0, ns);
      if (recentNamespaces.length > 5) recentNamespaces.removeLast();
    }
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

  // ---- kubeconfig selection and backend (re)connects ----

  /// The active kubeconfig and the files the user can switch to.
  KubeconfigList kubeconfigs = const KubeconfigList();

  /// Set while a kubeconfig switch is in flight.
  bool switchingKubeconfig = false;

  bool _connectedOnce = false;

  /// Called when the backend becomes reachable (first launch, or a new port
  /// after the embedded backend restarted). Reloads everything and makes
  /// open tables re-subscribe.
  Future<void> backendConnected() async {
    final again = _connectedOnce;
    _connectedOnce = true;
    await init();
    if (again) columnsChanged();
    await loadSidebar();
    await loadKubeconfigs();
  }

  Future<void> loadKubeconfigs() async {
    try {
      kubeconfigs = await api.kubeconfigs();
      notifyListeners();
    } catch (_) {
      // Older backends lack the endpoint; the picker just stays empty.
    }
  }

  /// Switch to another kubeconfig file and reload types and namespaces.
  /// Returns an error message, or null on success.
  Future<String?> switchKubeconfig(String path) async {
    switchingKubeconfig = true;
    notifyListeners();
    try {
      kubeconfigs = await api.switchKubeconfig(path);
    } on ApiException catch (e) {
      switchingKubeconfig = false;
      notifyListeners();
      return e.message;
    } catch (e) {
      switchingKubeconfig = false;
      notifyListeners();
      return '$e';
    }
    _detailStack.clear();
    namespace = null;
    selectedType = null;
    types = const [];
    await init();
    switchingKubeconfig = false;
    columnsChanged();
    return null;
  }
}
