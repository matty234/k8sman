import 'dart:async';

import 'package:clock/clock.dart';
import 'package:flutter/foundation.dart';

import '../api/client.dart';
import '../api/models.dart';
import 'cluster_error.dart';
import 'context_appearance.dart';
import 'namespace_scope.dart';
import 'nav_history.dart';
import 'saved_views.dart';
import 'sidebar_config.dart';
import 'table_prefs.dart';

export 'namespace_scope.dart';
export 'saved_views.dart';
export 'sidebar_config.dart';

/// What the main area shows: a page, by id. The core pages are the
/// constants below; integration modules (lib/modules) declare their own,
/// e.g. `MainView('helm')`. The id is what the saved sidebar layout stores.
@immutable
class MainView {
  final String name;
  const MainView(this.name);

  /// The table of the selected kind.
  static const resources = MainView('resources');
  static const overview = MainView('overview');
  static const alerts = MainView('alerts');
  static const nodes = MainView('nodes');
  static const security = MainView('security');
  static const access = MainView('access');
  static const portForwards = MainView('portForwards');

  /// The Settings page (not in the sidebar's layout: the gear opens it).
  static const settings = MainView('settings');

  @override
  bool operator ==(Object other) => other is MainView && other.name == name;
  @override
  int get hashCode => name.hashCode;
  @override
  String toString() => 'MainView($name)';
}

/// A tab of the inspector a caller can ask for. [edit] is the YAML tab,
/// already in edit mode.
enum DetailTab { overview, yaml, edit }

/// An object shown in the detail sidebar.
class DetailTarget {
  final ResourceType type;
  final String name;
  final String? namespace;

  /// The object as the opener had it (a table row's), shown at once while
  /// the inspector's own watch connects. Not part of the identity.
  final Json? seed;
  const DetailTarget({required this.type, required this.name, this.namespace, this.seed});

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

/// What [AppState.openView] did.
enum ViewOpenResult {
  opened,

  /// The view's context isn't in the current kubeconfig (or its kubeconfig
  /// can't be switched to): the UI offers to re-point it. Nothing changed.
  missingContext,

  /// The switch to the view's context failed (the error screen shows why).
  failed,

  /// The cluster doesn't serve the view's kind.
  notServed,
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
  final NamespaceScope namespaceScope;
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
    required this.namespaceScope,
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

  /// The current context is read-only: hide mutating UI. See
  /// [readOnlyReason].
  bool readOnly = false;

  /// Why [readOnly]: `flag` (backend started with --read-only), `context`
  /// (the user locked this context) or `auto` (its name looks like
  /// production); '' when writable.
  String readOnlyReason = '';

  /// Read-only contexts → reason (as [readOnlyReason]).
  Map<String, String> readOnlyContexts = const {};

  /// The icon and colour the user picked per context (absent = default).
  Map<String, ContextAppearance> contextAppearance = const {};

  String _currentContext = '';

  /// The context the UI shows. The API client sends it with each request
  /// (see [ApiClient.context]).
  String get currentContext => _currentContext;
  set currentContext(String v) {
    _currentContext = v;
    api.context = v;
  }
  List<ContextInfo> contexts = const [];
  List<ResourceType> types = const [];
  List<String> namespaces = const [];

  /// False when the cluster's namespaces couldn't be listed (no
  /// cluster-wide `list namespaces`): [namespaces] is then only the
  /// context's default, and a missing namespace may simply be unlisted.
  bool namespacesListed = true;

  /// Namespaces the user typed in the picker for this context (saved in
  /// settings.json), in the order added. For users who can't list namespaces.
  List<String> rememberedNamespaces = const [];

  /// Namespaces the user starred for this context (saved in settings.json),
  /// sorted by name.
  List<String> favouriteNamespaces = const [];

  /// Stars [ns], or unstars it if it is starred.
  Future<void> toggleFavouriteNamespace(String ns) async {
    favouriteNamespaces = favouriteNamespaces.contains(ns)
        ? [for (final n in favouriteNamespaces) if (n != ns) n]
        : ([...favouriteNamespaces, ns]..sort());
    notifyListeners();
    try {
      await api.putFavouriteNamespaces(favouriteNamespaces, context: currentContext);
    } catch (_) {
      // Local convenience only; the star still applies for this session.
    }
  }

  /// The only namespaces this context shows (saved in settings.json; empty =
  /// every namespace). When set, [namespaces] is this list and "All
  /// namespaces" means all of these: the backend fans out over them.
  List<String> allowedNamespaces = const [];

  /// Where this context opens (Settings ▸ Clusters): `all` (the default),
  /// `kubeconfig` (the context's own namespace) or `namespaces`
  /// ([defaultNamespaces]).
  String defaultNamespaceMode = 'all';
  List<String> defaultNamespaces = const [];

  /// Whether the user picked a scope since connecting to this context; if
  /// not, a reconnect opens in [defaultNamespaceScope] again.
  bool _scopeChosen = false;
  bool get scopeChosen => _scopeChosen;

  /// "All namespaces", or with an allowlist "All allowed namespaces (n)".
  String get allNamespacesLabel => allowedNamespaces.isEmpty ? 'All namespaces' : 'All allowed namespaces (${allowedNamespaces.length})';

  /// The scope the app opens in, and falls back to when a selection is
  /// cleared: the Default namespace setting (all namespaces unless changed).
  /// Where namespaces can't be listed (and there's no allowlist), all
  /// namespaces would be refused: the kubeconfig's namespace, else a
  /// remembered one, else `default`.
  NamespaceScope get defaultNamespaceScope {
    final configured = switch (defaultNamespaceMode) {
      'kubeconfig' => NamespaceScope.single(kubeconfigNamespace),
      'namespaces' => NamespaceScope.of(defaultNamespaces),
      _ => NamespaceScope.all,
    };
    if (!configured.isAll || namespacesListed) return configured;
    return NamespaceScope.single(kubeconfigNamespace ?? rememberedNamespaces.firstOrNull ?? 'default');
  }

  /// Saves the Default namespace setting for the current context.
  Future<void> setDefaultNamespace(String mode, List<String> namespaces) async {
    await api.putDefaultNamespace(mode, namespaces, context: currentContext);
    defaultNamespaceMode = mode;
    defaultNamespaces = mode == 'namespaces' ? namespaces : const [];
    // Applies at once unless the user picked a scope this session (then it
    // waits for the next context switch). Not itself a choice.
    if (!_scopeChosen) _namespaceScope = defaultNamespaceScope;
    notifyListeners();
  }

  /// Re-lists the namespaces (they're otherwise listed once per connect),
  /// so ones created since (a Helm install, kubectl) show up. Quiet on
  /// failure; overlapping calls share one request.
  Future<void> refreshNamespaces() => _nsRefresh ??= () async {
        final ctx = currentContext;
        try {
          final ns = await api.namespaces();
          if (ctx != currentContext) return;
          if (!listEquals(ns.namespaces, namespaces) || ns.listed != namespacesListed) {
            namespaces = ns.namespaces;
            namespacesListed = ns.listed;
            notifyListeners();
          }
        } catch (_) {
        } finally {
          _nsRefresh = null;
        }
      }();
  Future<void>? _nsRefresh;

  /// Saves the current context's allowlist (empty removes it), then
  /// reloads its namespaces and reopens the tables in the new scope.
  Future<void> setAllowedNamespaces(List<String> allowed) async {
    await api.putAllowedNamespaces(allowed, context: currentContext);
    allowedNamespaces = [...allowed]..sort();
    try {
      final ns = await api.namespaces();
      namespaces = ns.namespaces;
      namespacesListed = ns.listed;
    } catch (_) {
      if (allowedNamespaces.isNotEmpty) namespaces = allowedNamespaces;
    }
    columnsChanged();
  }

  /// The kubeconfig context's own namespace, if it sets one.
  String? kubeconfigNamespace;

  /// Remembers [ns] for this context (no-op if already remembered).
  Future<void> rememberNamespace(String ns) async {
    if (rememberedNamespaces.contains(ns)) return;
    rememberedNamespaces = [...rememberedNamespaces, ns];
    notifyListeners();
    await _saveRemembered();
  }

  /// Forgets a remembered namespace.
  Future<void> forgetNamespace(String ns) async {
    if (!rememberedNamespaces.contains(ns)) return;
    rememberedNamespaces = [for (final n in rememberedNamespaces) if (n != ns) n];
    notifyListeners();
    await _saveRemembered();
  }

  Future<void> _saveRemembered() async {
    try {
      await api.putRememberedNamespaces(rememberedNamespaces, context: currentContext);
    } catch (_) {
      // Local convenience only; the choice still applies for this session.
    }
  }

  /// The namespaces tables show: all, one, or a set. Overview, Security,
  /// Alerts and Metrics keep their own scope (see PageScope). Setting it
  /// counts as the user's choice (see [_scopeChosen]).
  NamespaceScope get namespaceScope => _namespaceScope;
  set namespaceScope(NamespaceScope s) {
    _namespaceScope = s;
    _scopeChosen = true;
  }

  NamespaceScope _namespaceScope = NamespaceScope.all;

  /// Back to all namespaces for a new context, not yet chosen: the next
  /// connect opens in its Default namespace.
  void _resetScope() {
    _namespaceScope = NamespaceScope.all;
    _scopeChosen = false;
  }

  /// The selected namespace when exactly one is selected; null for all
  /// namespaces *and* for a set of several. For call sites that need one
  /// namespace (create dialogs, defaults); tables use [namespaceScope].
  String? get namespace => namespaceScope.single;

  /// Selects one namespace (null = all) without notifying (tests, setup).
  set namespace(String? ns) => namespaceScope = NamespaceScope.single(ns);

  ResourceType? selectedType;

  MainView view = MainView.resources;

  /// Opens a view that lives in the bottom dock (set by the shell): Alerts
  /// and Port Forwards are dock panes rather than pages, so [showView] of
  /// either opens the pane. Returns false for views that aren't in the dock.
  bool Function(MainView v)? showInDock;

  /// Shows page [v]. [focus] is handed to the page as [pageFocus] (e.g. the
  /// Helm page's `namespace/name` release to select). A page that is a
  /// kind's home opens in its last mode (see [setPageMode]).
  void showView(MainView v, {String? focus}) {
    if (focus != null) pageFocus = focus;
    if (showInDock?.call(v) ?? false) return;
    final kind = homeKindOf(v);
    if (kind != null && pageInTableMode(v)) {
      selectType(kind, asTable: true);
      return;
    }
    _seedHistory();
    if (v != view && detail != null) inspectorCollapsed = true;
    if (v != view) previousView = view;
    view = v;
    _recordNav();
    notifyListeners();
  }

  // ---- pages that are a kind's home ----

  /// The kinds pages are the home of (`group/Kind` → page), e.g. the Nodes
  /// page for Node. Set from the page registry (`kindHomes` in
  /// lib/modules/modules.dart) by main and the shell; null leaves every
  /// kind on its plain table.
  Map<String, MainView> Function(AppState app)? kindHomes;

  /// The page that is the home of [t], if any.
  MainView? homePageOf(ResourceType? t) => t == null ? null : kindHomes?.call(this)[t.gk];

  /// The kind page [v] is the home of (its Table mode shows that kind).
  ResourceType? homeKindOf(MainView v) {
    final homes = kindHomes?.call(this);
    if (homes == null) return null;
    for (final e in homes.entries) {
      if (e.value != v) continue;
      final i = e.key.indexOf('/');
      final t = typeFor(e.key.substring(0, i), e.key.substring(i + 1));
      if (t != null) return t;
    }
    return null;
  }

  /// Whether home page [v] was last left in its Table mode (remembered with
  /// its kind's table preferences, so across launches too).
  bool pageInTableMode(MainView v) {
    final t = homeKindOf(v);
    return t != null && tablePrefs.of(t.gk).mode == 'table';
  }

  /// The home page whose mode is showing: [view] itself, or, on the
  /// table of a kind that has a home page, that page (its Table mode).
  MainView? get activeHomePage => view == MainView.resources ? homePageOf(selectedType) : (homeKindOf(view) != null ? view : null);

  /// Switches home page [page] to its Table mode ([table]) or its own
  /// Overview, and remembers the choice. History replaces the current
  /// entry rather than adding one per switch.
  void setPageMode(MainView page, {required bool table}) {
    final t = homeKindOf(page);
    if (t == null) return;
    final p = tablePrefs.of(t.gk);
    final mode = table ? 'table' : '';
    if (p.mode != mode) {
      p.mode = mode;
      tablePrefs.changed(t.gk);
    }
    _seedHistory();
    if (table) {
      selectedType = t;
      view = MainView.resources;
    } else {
      _endViewSession();
      if (view != page) previousView = view;
      view = page;
    }
    _recordNav(replace: true);
    notifyListeners();
  }

  /// The page shown before the last [showView] changed it: where the
  /// Settings page's Back (and Esc) returns to.
  MainView previousView = MainView.resources;

  /// What the page shown by the last [showView] should select when it
  /// builds; the page clears it once used.
  String? pageFocus;

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

  /// Each resource kind's table sort, column widths and filter, saved in
  /// the backend's settings so tables come back as they were left.
  late final TablePrefsStore tablePrefs = TablePrefsStore(api);

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
      final h = await api.health().then((h) => h, onError: (_) => const <String, dynamic>{});
      if (stale()) return;
      readOnly = h['readOnly'] == true;
      readOnlyReason = readOnly ? (h['readOnlyReason'] as String? ?? 'flag') : '';
      final ctx = await api.contexts();
      if (stale()) return;
      currentContext = ctx.current;
      contexts = ctx.contexts;
      readOnlyContexts = ctx.readOnly;
      unawaited(_loadContextAppearance());
      await tablePrefs.load();
      if (stale()) return;
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
      namespacesListed = ns.listed;
      kubeconfigNamespace = ns.defaultNamespace?.isNotEmpty == true ? ns.defaultNamespace : null;
      try {
        rememberedNamespaces = await api.getRememberedNamespaces(context: currentContext);
      } catch (_) {
        rememberedNamespaces = const [];
      }
      try {
        favouriteNamespaces = [...await api.getFavouriteNamespaces(context: currentContext)]..sort();
      } catch (_) {
        favouriteNamespaces = const [];
      }
      try {
        allowedNamespaces = [...await api.getAllowedNamespaces(context: currentContext)]..sort();
      } catch (_) {
        allowedNamespaces = const [];
      }
      try {
        final d = await api.getDefaultNamespace(context: currentContext);
        defaultNamespaceMode = d.mode;
        defaultNamespaces = d.namespaces;
      } catch (_) {
        defaultNamespaceMode = 'all';
        defaultNamespaces = const [];
      }
      if (stale()) return;
      // Open in the Default namespace setting, unless the user picked a
      // scope in this context already (a reconnect keeps it).
      if (!_scopeChosen) _namespaceScope = defaultNamespaceScope;
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
      namespaceScope: namespaceScope,
      selectedType: selectedType,
      view: view,
      detail: List.of(_detailStack),
      inspectorCollapsed: inspectorCollapsed,
    );
  }

  Future<void> _loadContextAppearance() async {
    try {
      final all = await api.getContextAppearances();
      contextAppearance = {for (final e in all.entries) e.key: ContextAppearance(icon: e.value.icon, color: e.value.color)};
      notifyListeners();
    } catch (_) {
      // Older backend or no settings: the default badges.
    }
  }

  /// Saves [a] as [context]'s badge (default forgets it).
  Future<void> setContextAppearance(String context, ContextAppearance a) async {
    await api.putContextAppearance(context, a.icon, a.color);
    contextAppearance = {...contextAppearance};
    if (a.isDefault) {
      contextAppearance.remove(context);
    } else {
      contextAppearance[context] = a;
    }
    notifyListeners();
  }

  /// Locks (true) or unlocks (false) [context], or with null returns it to
  /// automatic (read-only when its name looks like production).
  Future<void> setContextReadOnly(String context, bool? locked) async {
    final r = await api.setContextReadOnly(context, locked);
    readOnlyContexts = {...readOnlyContexts}..remove(context);
    if (r.readOnly) readOnlyContexts[context] = r.reason;
    if (context == currentContext) {
      readOnly = r.readOnly;
      readOnlyReason = r.reason;
    }
    notifyListeners();
  }

  Future<void> switchContext(String name) async {
    final gen = _supersede();
    _rememberPrevious();
    // Show the connecting screen right away.
    final info = _info(name);
    loading = true;
    connecting = ConnectProgress(context: name, server: info?.server, auth: info?.auth, started: clock.now());
    _detailStack.clear();
    recentDetails.clear();
    history.clear();
    _resetScope();
    selectedType = null;
    _endViewSession();
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
      history.clear();
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
    _endViewSession();
    currentContext = p.context;
    readOnly = p.readOnly;
    readOnlyReason = p.readOnly ? (readOnlyContexts[p.context] ?? 'context') : '';
    contexts = p.contexts;
    types = p.types;
    namespaces = p.namespaces;
    namespaceScope = p.namespaceScope;
    selectedType = p.selectedType;
    view = p.view;
    history.clear();
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

  /// Shows [t]'s table. Ends an open view's session unless [keepSession]
  /// (used by [openView]). A kind with a home page (Node: the Nodes page)
  /// opens the page in its last mode instead, unless [asTable] asks for
  /// the table (its Table mode) or a view is being opened.
  void selectType(ResourceType t, {bool keepSession = false, bool asTable = false}) {
    final home = homePageOf(t);
    if (home != null && !keepSession && !asTable && !pageInTableMode(home)) {
      showView(home);
      return;
    }
    _seedHistory();
    if (!keepSession) _endViewSession();
    if (detail != null && (t != selectedType || view != MainView.resources)) inspectorCollapsed = true;
    selectedType = t;
    view = MainView.resources;
    _recordNav();
    notifyListeners();
  }

  /// Shows the table of kind ([group], [kind]) for [scope] (cluster-scoped
  /// kinds ignore it), with [filter] typed into its filter box as if by the
  /// user (remembered per kind, so it can be cleared). Ends an open view's
  /// session rather than touching the saved view. False if the kind isn't
  /// served.
  bool openTable(String group, String kind, {NamespaceScope? scope, String? filter}) {
    final t = typeFor(group, kind);
    if (t == null) return false;
    if (t.namespaced && scope != null) namespaceScope = scope;
    if (filter != null) {
      final p = tablePrefs.of(t.gk);
      if (p.filter != filter) {
        p.filter = filter;
        tablePrefs.changed(t.gk);
      }
    }
    // A filtered table is asked for: a home page's Table mode.
    selectType(t, asTable: filter != null);
    return true;
  }

  /// A term for a kind's table to add to its filter (an inspector label's
  /// "Filter by this label"), until that table takes it.
  ({String gk, String term})? _filterTerm;

  String? takeFilterTerm(String gk) {
    final r = _filterTerm;
    if (r == null || r.gk != gk) return null;
    _filterTerm = null;
    return r.term;
  }

  /// Shows [t]'s table with [term] added to its filter.
  void filterTable(ResourceType t, String term) {
    _filterTerm = (gk: t.gk, term: term);
    if (selectedType == t && view == MainView.resources) {
      notifyListeners();
    } else {
      selectType(t, asTable: true);
    }
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

  // ---- integrations ----

  /// Ids of the integration modules the user turned off (lib/modules):
  /// their pages, panels, palette entries and sidebar sections are hidden,
  /// and the backend turns off their routes and overview checks.
  /// Includes [supersededModules].
  Set<String> disabledModules = const {};
  Future<void> _moduleSaves = Future.value();

  /// Modules a bundled plugin replaces (e.g. External Secrets): off, and
  /// hidden in Settings ▸ Integrations, where the plugin has the row. The
  /// backend decides (settings.json's plugins.useModule brings one back).
  Set<String> supersededModules = const {};

  /// What the user turned off themselves (what [setDisabledModules] saves).
  Set<String> _userDisabledModules = const {};

  /// Loads [disabledModules] (an app setting, like the sidebar layout).
  /// Again after the module/plugin choice changes.
  Future<void> loadDisabledModules() async {
    try {
      final m = await api.getDisabledModules();
      _userDisabledModules = Set.unmodifiable(m.disabled);
      supersededModules = Set.unmodifiable(m.superseded);
      disabledModules = Set.unmodifiable({...m.disabled, ...m.superseded});
      notifyListeners();
    } catch (e) {
      debugPrint('integrations: $e');
    }
  }

  /// Applies [ids] now and saves them in the background. Superseded
  /// modules stay off whatever [ids] says; the user's own choice for them
  /// is kept as it was.
  void setDisabledModules(Set<String> ids) {
    final save = {...ids.difference(supersededModules), ..._userDisabledModules.intersection(supersededModules)};
    _userDisabledModules = Set.unmodifiable(save);
    disabledModules = Set.unmodifiable({...save, ...supersededModules});
    notifyListeners();
    _moduleSaves = _moduleSaves.then((_) => api.putDisabledModules(save)).catchError((Object e) => debugPrint('save integrations: $e'));
  }

  /// The discovered type a pin points at (null: not on this cluster).
  ResourceType? typeForPin(SidebarPin p) => typeFor(p.group, p.kind);

  /// Selects a pinned kind exactly as the kinds list does, switching to
  /// the pin's namespaces if it has some.
  void openPin(SidebarPin p) {
    final t = typeForPin(p);
    if (t == null) return;
    if (!p.scope.isAll && t.namespaced && namespaceScope != p.scope) setNamespaceScope(p.scope);
    selectType(t);
  }

  /// The pin showing the current selection: one scoped to the current
  /// namespaces wins over an unscoped pin of the same kind.
  SidebarPin? get selectedPin {
    final t = selectedType;
    if (view != MainView.resources || t == null || viewSession != null) return null;
    SidebarPin? any;
    for (final p in sidebar.pins) {
      if (p.gk != t.gk) continue;
      if (p.scope.isAll) {
        any ??= p;
      } else if (p.scope == namespaceScope) {
        return p;
      }
    }
    return any;
  }

  /// Namespace scopes chosen this session, most recent first (for the
  /// picker): single namespaces and sets.
  final List<NamespaceScope> recentNamespaces = [];

  /// Selects one namespace (null = all namespaces).
  void setNamespace(String? ns) => setNamespaceScope(NamespaceScope.single(ns));

  /// Selects a namespace scope for tables. Ends an open view's session
  /// (the view keeps its own namespaces).
  void setNamespaceScope(NamespaceScope scope) {
    _seedHistory();
    namespaceScope = scope;
    if (!scope.isAll) {
      recentNamespaces
        ..remove(scope)
        ..insert(0, scope);
      if (recentNamespaces.length > 5) recentNamespaces.removeLast();
    }
    _endViewSession();
    _recordNav(replace: true);
    notifyListeners();
  }

  /// Objects inspected on this context, most recent first (the inspector's
  /// history menu). Cleared when the context or kubeconfig changes.
  final List<DetailTarget> recentDetails = [];
  static const maxRecentDetails = 20;

  void _remember(DetailTarget t) {
    recentDetails
      ..remove(t)
      ..insert(0, t);
    if (recentDetails.length > maxRecentDetails) recentDetails.removeLast();
  }

  /// The inspector tab asked for by the last [openDetail], until the
  /// sidebar picks it up with [takeDetailTab].
  DetailTab? _requestedTab;

  DetailTab? takeDetailTab() {
    final t = _requestedTab;
    _requestedTab = null;
    return t;
  }

  /// Open an object from the table: replaces the sidebar stack. [tab]
  /// switches the inspector to that tab (else it keeps its own).
  void openDetail(DetailTarget t, {DetailTab? tab}) {
    _seedHistory();
    _detailStack
      ..clear()
      ..add(t);
    _remember(t);
    _requestedTab = tab;
    inspectorCollapsed = false;
    _recordNav();
    notifyListeners();
  }

  /// The inspector's kind breadcrumb: the table of [t]'s kind, scoped to its
  /// namespace if the table is scoped to another one, with the inspector
  /// collapsed so the table gets the width (its row stays selected).
  void showInList(DetailTarget t) {
    _seedHistory();
    if (t.namespace != null && !namespaceScope.contains(t.namespace)) setNamespace(t.namespace);
    selectedType = t.type;
    // A kind with a home page: the page, in its last mode.
    final home = homePageOf(t.type);
    view = home != null && !pageInTableMode(home) ? home : MainView.resources;
    if (detail != null) inspectorCollapsed = true;
    _recordNav();
    notifyListeners();
  }

  /// Follow a reference from inside the sidebar (pushes onto the stack so the
  /// user can go back). Returns false if the kind isn't served by the cluster.
  bool openRef(ObjectRef ref) {
    final t = typeFor(ref.group, ref.kind);
    if (t == null) return false;
    final target = DetailTarget(type: t, name: ref.name, namespace: t.namespaced ? ref.namespace : null);
    if (detail == target) return true;
    _seedHistory();
    _detailStack.add(target);
    _remember(target);
    _recordNav();
    notifyListeners();
    return true;
  }

  void back() {
    if (_detailStack.length > 1) {
      _detailStack.removeLast();
      _recordNav(replace: true);
      notifyListeners();
    }
  }

  void closeDetail() {
    _detailStack.clear();
    _requestedTab = null;
    inspectorCollapsed = false;
    _recordNav(replace: true);
    notifyListeners();
  }

  // ---- back / forward history ----

  final NavHistory history = NavHistory();
  bool _navigating = false;

  NavLocation get _location =>
      NavLocation(view, selectedType, namespaceScope, viewSession?.view.id, inspectorCollapsed ? null : detail);

  bool get _locatable => view != MainView.resources || selectedType != null;

  /// Called before a navigation changes anything, so the place the user
  /// leaves is the first entry.
  void _seedHistory() {
    if (!_navigating && history.current == null && _locatable) history.record(_location, clock.now());
  }

  void _recordNav({bool replace = false}) {
    if (!_navigating && _locatable) history.record(_location, clock.now(), replace: replace);
  }

  bool get canNavBack => history.canGoBack;
  bool get canNavForward => history.canGoForward;

  void navBack() => _go(history.back());
  void navForward() => _go(history.forward());

  /// Shows [l] without recording it.
  void _go(NavLocation? l) {
    if (l == null) return;
    _navigating = true;
    try {
      if (l.view != view) previousView = view;
      if (l.viewId != viewSession?.view.id) {
        final v = l.viewId == null ? null : savedViews.where((x) => x.id == l.viewId).firstOrNull;
        if (v != null) {
          // Same context here, so this runs synchronously.
          openView(v);
        } else {
          _endViewSession();
        }
      }
      view = l.view;
      if (l.type != null) selectedType = l.type;
      namespaceScope = l.scope;
      _detailStack.clear();
      if (l.detail != null) {
        _detailStack.add(l.detail!);
        inspectorCollapsed = false;
      }
    } finally {
      _navigating = false;
    }
    notifyListeners();
  }

  void columnsChanged() {
    columnsVersion++;
    notifyListeners();
  }

  // ---- saved views ----

  /// Saved views this build can read, in the user's order (records of a
  /// newer app version stay in settings.json untouched and aren't listed).
  List<SavedView> savedViews = const [];

  /// The id of the view opened at launch ('' = reconnect to the last
  /// context).
  String launchViewId = '';

  /// The open view's session, while a view is open (see [ViewSession]).
  ViewSession? viewSession;

  /// The open view, if any.
  SavedView? get activeView => viewSession?.view;

  /// Bumped when a view is opened or its session reset, so the table is
  /// rebuilt with the view's state.
  int viewRevision = 0;

  /// A problem to show once (e.g. the launch view couldn't be opened).
  String? viewNotice;

  void dismissViewNotice() {
    viewNotice = null;
    notifyListeners();
  }

  Future<void> loadViews() async {
    try {
      final r = await api.getViews();
      savedViews = [for (final j in r.views) ?SavedView.fromJson(j)];
      launchViewId = r.launchView;
      _kubeconfigKeys.addAll(r.kubeconfigKeys);
      notifyListeners();
    } catch (e) {
      debugPrint('saved views: $e');
    }
  }

  /// Whether [c] is the context the app is on: same name, same kubeconfig
  /// file (compared by [kubeconfigKey], not by how the path was spelled).
  bool isCurrentContext(ViewContext c) => c.name == currentContext && sameKubeconfig(c.kubeconfig);

  /// Whether [path] is the active kubeconfig file.
  bool sameKubeconfig(String path) => path == kubeconfigs.current || kubeconfigKey(path) == kubeconfigs.currentKey;

  /// Views for the sidebar: those that apply to any context and those
  /// bound to the current one. Views of other contexts are in the palette.
  List<SavedView> get viewsHere => [for (final v in savedViews) if (v.context == null || isCurrentContext(v.context!)) v];

  void _endViewSession() {
    if (viewSession == null) return;
    viewSession = null;
    viewRevision++;
  }

  /// Opens [v]: switches to its context first when it is bound to another
  /// one (through [switchContext], the normal path), then shows its kind
  /// in its namespaces with its filter, sort and columns as a view session.
  ///
  /// Never falls back to another context: a bound context that isn't in
  /// the kubeconfig returns [ViewOpenResult.missingContext] with nothing
  /// changed.
  Future<ViewOpenResult> openView(SavedView v) async {
    final c = v.context;
    if (c != null && !isCurrentContext(c)) {
      if (!sameKubeconfig(c.kubeconfig)) {
        // '' (the default loading rules) can't be switched to explicitly.
        if (c.kubeconfig.isEmpty) return ViewOpenResult.missingContext;
        final err = await switchKubeconfig(c.kubeconfig);
        if (err != null) return ViewOpenResult.missingContext;
      }
      if (!contexts.any((x) => x.name == c.name)) return ViewOpenResult.missingContext;
      if (currentContext != c.name) await switchContext(c.name);
      if (currentContext != c.name || error != null) return ViewOpenResult.failed;
    }
    final t = typeFor(v.group, v.kind);
    if (t == null) return ViewOpenResult.notServed;
    // Missing namespaces stay in the scope: they list nothing, and the
    // picker shows them struck through. The view itself isn't changed.
    if (t.namespaced) namespaceScope = v.scope;
    viewSession = ViewSession(v, onChanged: notifyListeners);
    viewRevision++;
    selectType(t, keepSession: true);
    return ViewOpenResult.opened;
  }

  /// Adds or replaces [v] and saves it.
  Future<void> saveView(SavedView v) async {
    await api.putView(v.toJson());
    final i = savedViews.indexWhere((x) => x.id == v.id);
    savedViews = i < 0 ? [...savedViews, v] : ([...savedViews]..[i] = v);
    if (viewSession?.view.id == v.id) viewSession!.view = v;
    notifyListeners();
  }

  /// Saves the open view's session as the view (Update view).
  Future<void> updateActiveView() async {
    final s = viewSession;
    if (s == null) return;
    await saveView(s.current);
  }

  /// Drops the open view's unsaved changes (Revert).
  void revertActiveView() {
    final s = viewSession;
    if (s == null) return;
    s.revert();
    viewRevision++;
    notifyListeners();
  }

  /// The open view's columns changed (column editor, header drag): the
  /// table re-subscribes with them.
  void viewColumnsChanged(List<ColumnDef>? columns) {
    final s = viewSession;
    if (s == null) return;
    s.columns = columns;
    viewRevision++;
    notifyListeners();
  }

  /// Deletes a view; returns it and its position for undo.
  Future<(SavedView, int)?> deleteView(String id) async {
    final i = savedViews.indexWhere((v) => v.id == id);
    if (i < 0) return null;
    final v = savedViews[i];
    await api.deleteView(id);
    savedViews = [...savedViews]..removeAt(i);
    if (launchViewId == id) launchViewId = '';
    if (viewSession?.view.id == id) _endViewSession();
    notifyListeners();
    return (v, i);
  }

  /// Puts a deleted view back where it was (undo).
  Future<void> restoreView(SavedView v, int index) async {
    await api.putView(v.toJson(), index: index);
    savedViews = [...savedViews.where((x) => x.id != v.id)]..insert(index.clamp(0, savedViews.length), v);
    notifyListeners();
  }

  /// Saves a new order of the views: [ids] first, in that order (views
  /// not listed keep their relative order after them).
  Future<void> setViewOrder(List<String> ids) async {
    final byId = {for (final v in savedViews) v.id: v};
    final list = [for (final id in ids) ?byId[id], for (final v in savedViews) if (!ids.contains(v.id)) v];
    final before = savedViews;
    savedViews = list;
    notifyListeners();
    try {
      await api.reorderViews([for (final x in list) x.id]);
    } catch (_) {
      savedViews = before;
      notifyListeners();
      rethrow;
    }
  }

  /// Opens [id] at launch ('' = reconnect to the last context).
  Future<void> setLaunchView(String id) async {
    await api.setLaunchView(id);
    launchViewId = id;
    notifyListeners();
  }

  // ---- kubeconfig selection and backend (re)connects ----

  /// The active kubeconfig and the files the user can switch to.
  KubeconfigList get kubeconfigs => _kubeconfigs;
  set kubeconfigs(KubeconfigList k) {
    _kubeconfigs = k;
    _kubeconfigKeys[k.current] = k.currentKey;
  }

  KubeconfigList _kubeconfigs = const KubeconfigList();

  /// Canonical keys of kubeconfig paths (resolved by the backend: `~`,
  /// symlinks, the default loading rules), from the views list and from
  /// every kubeconfig that was active.
  final Map<String, String> _kubeconfigKeys = {};

  /// The identity of a kubeconfig path as views compare it: the default
  /// ('') and an explicit `~/.kube/config` are the same file. Falls back
  /// to the path itself when the backend didn't resolve it.
  String kubeconfigKey(String path) => _kubeconfigKeys[path] ?? path;

  /// Set while a kubeconfig switch is in flight.
  bool switchingKubeconfig = false;

  bool _connectedOnce = false;

  /// Copy link copies the `k8sman://` form instead of the https one
  /// (Settings ▸ General; an app setting in settings.json).
  bool appLinks = false;
  Future<void> _linkSaves = Future.value();

  /// "Always open links for this cluster here": cluster fingerprint (a
  /// link's `c`) → local context name.
  Map<String, String> linkClusterMap = const {};

  Future<void> loadLinkPrefs() async {
    try {
      appLinks = await api.getAppLinks();
      linkClusterMap = await api.getLinkClusterMap();
      notifyListeners();
    } catch (e) {
      debugPrint('link preferences: $e');
    }
  }

  /// Remembers [context] for links to [fingerprint]; '' forgets it.
  void setLinkCluster(String fingerprint, String context) {
    linkClusterMap = {...linkClusterMap}..remove(fingerprint);
    if (context.isNotEmpty) linkClusterMap[fingerprint] = context;
    notifyListeners();
    _linkSaves = _linkSaves.then((_) => api.putLinkCluster(fingerprint, context)).catchError((Object e) => debugPrint('save link mapping: $e'));
  }

  void setAppLinks(bool v) {
    appLinks = v;
    notifyListeners();
    _linkSaves = _linkSaves.then((_) => api.putAppLinks(v)).catchError((Object e) => debugPrint('save link preferences: $e'));
  }

  /// Called when the backend becomes reachable (first launch, or a new port
  /// after the embedded backend restarted). Reloads everything and makes
  /// open tables re-subscribe.
  Future<void> backendConnected() async {
    try {
      await _backendConnected();
    } finally {
      if (!launched.isCompleted) launched.complete();
    }
  }

  /// Completes once the first [backendConnected] is done (the launch has
  /// picked its page), so a link that opened the app navigates after it.
  final Completer<void> launched = Completer<void>();

  Future<void> _backendConnected() async {
    final again = _connectedOnce;
    _connectedOnce = true;
    // Views load without a connection (the error screen lists them).
    await loadViews();
    await loadLinkPrefs();
    final launch = again ? null : savedViews.where((v) => v.id == launchViewId).firstOrNull;
    if (launch?.context != null) await _preselectContext(launch!.context!);
    await init();
    if (again) columnsChanged();
    await loadSidebar();
    await loadDisabledModules();
    await loadKubeconfigs();
    // With no launch view (or one that couldn't open) the first launch lands
    // on the Overview, unless the user hid it from the sidebar. Context
    // switches keep the current page: only the launch decides.
    void openOverviewAtLaunch() {
      if (again || error != null || sidebar.isHidden(MainView.overview)) return;
      view = MainView.overview;
      notifyListeners();
    }

    if (launch == null) openOverviewAtLaunch();
    if (launch != null && error == null) {
      final r = await openView(launch);
      if (r != ViewOpenResult.opened) {
        openOverviewAtLaunch();
        viewNotice = switch (r) {
          ViewOpenResult.missingContext => 'View “${launch.name}” wasn\'t opened at launch: context ${launch.context?.name} was not found.',
          ViewOpenResult.notServed => 'View “${launch.name}” wasn\'t opened at launch: ${currentContext.isEmpty ? 'the cluster' : currentContext} doesn\'t serve ${launch.kind}.',
          _ => 'View “${launch.name}” wasn\'t opened at launch.',
        };
        notifyListeners();
      }
    }
  }

  /// At launch, a view bound to a context connects straight to it (instead
  /// of first connecting to the last context). Only when the context exists;
  /// otherwise [openView] reports it.
  Future<void> _preselectContext(ViewContext c) async {
    try {
      final kc = await api.kubeconfigs();
      if (c.kubeconfig.isNotEmpty && c.kubeconfig != kc.current && kubeconfigKey(c.kubeconfig) != kc.currentKey) await api.switchKubeconfig(c.kubeconfig);
      final ctx = await api.contexts();
      if (ctx.current != c.name && ctx.contexts.any((x) => x.name == c.name)) await api.switchContext(c.name);
    } catch (e) {
      debugPrint('launch view: $e');
    }
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
    recentDetails.clear();
    history.clear();
    _resetScope();
    selectedType = null;
    _endViewSession();
    types = const [];
    await init();
    history.clear();
    switchingKubeconfig = false;
    columnsChanged();
    return null;
  }
}
