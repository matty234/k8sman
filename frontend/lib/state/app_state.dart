import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'cluster_error.dart';

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

/// The steps of connecting to a context, in order.
enum ConnectStep {
  /// Is anything answering at the API server address? (~10 s at most)
  reaching,

  /// Getting credentials: an exec plugin may be waiting for a browser login.
  signingIn,

  /// API discovery: which kinds the cluster serves.
  discovering,

  /// Listing namespaces.
  namespaces,
}

/// What the connecting screen shows while [AppState.init] runs.
class ConnectProgress {
  final String context;

  /// API server URL, when the backend reports it.
  final String? server;

  /// Exec plugin / auth provider name (e.g. kubelogin), null for static
  /// credentials.
  final String? auth;
  final DateTime started;
  final ConnectStep step;
  const ConnectProgress({required this.context, this.server, this.auth, required this.started, this.step = ConnectStep.reaching});

  ConnectProgress at(ConnectStep s) => ConnectProgress(context: context, server: server, auth: auth, started: started, step: s);
}

/// The working context to go back to when a switch is cancelled or fails.
class _Previous {
  final String context;

  /// Kubeconfig file it came from, when a kubeconfig switch replaced it.
  final String? kubeconfig;
  final bool readOnly;
  final List<ContextInfo> contexts;
  final List<ResourceType> types;
  final List<String> namespaces;
  final String? namespace;
  final ResourceType? selectedType;
  final MainView view;
  final List<DetailTarget> detail;
  final bool inspectorCollapsed;
  const _Previous({
    required this.context,
    this.kubeconfig,
    required this.readOnly,
    required this.contexts,
    required this.types,
    required this.namespaces,
    required this.namespace,
    required this.selectedType,
    required this.view,
    required this.detail,
    required this.inspectorCollapsed,
  });
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

  /// Set while [init] runs: the connecting screen's context, server and step.
  ConnectProgress? connecting;

  /// Bumped by every connect, switch and cancel: a connect whose generation
  /// is no longer current drops its results, so a cancelled or superseded
  /// connect to a dead cluster can't overwrite state when it finally ends.
  int _gen = 0;

  /// Completed to abort the in-flight connection probe.
  Completer<void>? _abort;

  /// The working context before the current switch; restored by
  /// [backToPrevious].
  _Previous? _previous;

  /// Name of the context Cancel / "Back to …" returns to, if any.
  String? get previousContext => _previous?.context;

  /// Abandon the in-flight connect, if any; returns the new generation.
  int _supersede() {
    final a = _abort;
    _abort = null;
    if (a != null && !a.isCompleted) a.complete();
    return ++_gen;
  }

  ContextInfo? _info(String name) => contexts.where((c) => c.name == name).firstOrNull;

  Future<void> init() async {
    final gen = _supersede();
    final abort = _abort = Completer<void>();
    // Keep the clock of a switch that just started (see switchContext).
    final started = (loading && connecting?.context == currentContext ? connecting?.started : null) ?? clock.now();
    bool stale() => gen != _gen;
    loading = true;
    error = null;
    errorCause = null;
    if (currentContext.isNotEmpty) {
      final info = _info(currentContext);
      connecting = ConnectProgress(context: currentContext, server: info?.server, auth: info?.auth, started: started);
    }
    notifyListeners();
    void step(ConnectStep s) {
      final c = connecting;
      if (c == null || stale()) return;
      connecting = c.at(s);
      notifyListeners();
    }

    try {
      final ro = await api.health().then((h) => h['readOnly'] == true, onError: (_) => false);
      if (stale()) return;
      readOnly = ro;
      final ctx = await api.contexts();
      if (stale()) return;
      currentContext = ctx.current;
      contexts = ctx.contexts;
      final info = _info(currentContext);
      connecting = ConnectProgress(context: currentContext, server: info?.server, auth: info?.auth, started: started);
      notifyListeners();
      // Backends that report the server also serve the probes.
      if (info?.server != null) {
        await _probe('reach', abort.future);
        if (stale()) return;
        step(ConnectStep.signingIn);
        await _probe('auth', abort.future);
        if (stale()) return;
      }
      step(ConnectStep.discovering);
      final t = await api.resources();
      if (stale()) return;
      types = t;
      step(ConnectStep.namespaces);
      final ns = await api.namespaces();
      if (stale()) return;
      namespaces = ns.namespaces;
      namespace ??= ns.defaultNamespace?.isNotEmpty == true ? ns.defaultNamespace : null;
      selectedType ??= typeFor('', 'Pod');
      _previous = null;
    } catch (e) {
      if (stale()) return;
      error = '$e';
      errorCause = e;
    }
    if (stale()) return;
    _abort = null;
    loading = false;
    connecting = null;
    notifyListeners();
  }

  /// Runs one probe step. Only cluster-side failures stop the connect: a
  /// backend without the endpoint answers 404.
  Future<void> _probe(String step, Future<void> abort) async {
    try {
      await api.probe(step, abortTrigger: abort);
    } on ApiException catch (e) {
      if (e.status == 404 || e.status == 405 || (e.status == 400 && e.reason == null)) return;
      rethrow;
    }
  }

  /// Remember the working context so Cancel can return to it. From a failed
  /// state (no kinds) the context remembered before it is kept.
  void _rememberPrevious({String? kubeconfig}) {
    if (types.isEmpty || error != null || currentContext.isEmpty) return;
    _previous = _Previous(
      context: currentContext,
      kubeconfig: kubeconfig,
      readOnly: readOnly,
      contexts: contexts,
      types: types,
      namespaces: namespaces,
      namespace: namespace,
      selectedType: selectedType,
      view: view,
      detail: List.of(_detailStack),
      inspectorCollapsed: inspectorCollapsed,
    );
  }

  Future<void> switchContext(String name) async {
    final gen = _supersede();
    _rememberPrevious();
    // Show the connecting screen right away.
    final info = _info(name);
    loading = true;
    connecting = ConnectProgress(context: name, server: info?.server, auth: info?.auth, started: clock.now());
    _detailStack.clear();
    namespace = null;
    selectedType = null;
    // Drop the old cluster's kinds so a failure shows the error screen.
    types = const [];
    error = null;
    errorCause = null;
    notifyListeners();
    try {
      await api.switchContext(name);
      if (gen != _gen) return;
      currentContext = name;
      await init();
    } catch (e) {
      if (gen != _gen) return;
      error = '$e';
      errorCause = e;
      loading = false;
      connecting = null;
      notifyListeners();
    }
  }

  /// Cancel on the connecting screen: abandon the connect and go back to the
  /// previous context or, with none (first launch), show the error screen
  /// with the context and kubeconfig pickers.
  Future<void> cancelConnect() async {
    final name = connecting?.context ?? currentContext;
    _supersede();
    if (_previous != null) return backToPrevious();
    loading = false;
    connecting = null;
    error = 'Connecting to $name was cancelled.';
    errorCause = ClusterError(ClusterErrorKind.cancelled, error!, host: _info(name)?.server);
    notifyListeners();
  }

  /// Switch back to the context that worked before the last switch,
  /// restoring its kinds, namespace, selection and inspector.
  Future<void> backToPrevious() async {
    final p = _previous;
    if (p == null) return;
    final gen = _supersede();
    try {
      if (p.kubeconfig != null && p.kubeconfig != kubeconfigs.current) {
        kubeconfigs = await api.switchKubeconfig(p.kubeconfig!);
        if (gen != _gen) return;
      }
      await api.switchContext(p.context);
    } catch (e) {
      if (gen != _gen) return;
      // The backend couldn't switch back (e.g. the context was removed).
      _previous = null;
      loading = false;
      connecting = null;
      error = '$e';
      errorCause = e;
      notifyListeners();
      return;
    }
    if (gen != _gen) return;
    _previous = null;
    currentContext = p.context;
    readOnly = p.readOnly;
    contexts = p.contexts;
    types = p.types;
    namespaces = p.namespaces;
    namespace = p.namespace;
    selectedType = p.selectedType;
    view = p.view;
    _detailStack
      ..clear()
      ..addAll(p.detail);
    inspectorCollapsed = p.inspectorCollapsed;
    error = null;
    errorCause = null;
    loading = false;
    connecting = null;
    switchingKubeconfig = false;
    notifyListeners();
    // Open tables re-subscribe against the restored context.
    columnsChanged();
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
    final from = kubeconfigs.current;
    switchingKubeconfig = true;
    notifyListeners();
    try {
      kubeconfigs = await api.switchKubeconfig(path);
      _supersede();
      // Cancel can return to the previous file only when it was an explicit
      // one ('' = default loading rules, which the backend can't switch to).
      if (from.isNotEmpty) _rememberPrevious(kubeconfig: from);
      if (from.isEmpty || _previous?.kubeconfig == null) _previous = null;
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
