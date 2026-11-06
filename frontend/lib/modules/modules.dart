/// The built-in integration modules and lookups over them. The shell, the
/// sidebar, the palette and the panel registry ask here instead of naming
/// integrations. See module.dart for the module API and
/// docs/DEVELOPMENT.md ("Adding an integration").
library;

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import '../ui/pages.dart';
import 'addons_module.dart';
import 'argocd_module.dart';
import 'argoworkflows_module.dart';
import 'gateway_module.dart';
import 'gpus_module.dart';
import 'helm_module.dart';
import 'metrics_module.dart';
import 'module.dart';
import 'prometheus_module.dart';

export 'module.dart';

/// Every built-in module. A page's or section's `after` must name a core
/// one or one from a module listed earlier.
const List<AppModule> builtInModules = [
  GpusModule(),
  MetricsModule(),
  HelmModule(),
  AddonsModule(),
  ArgoCdModule(),
  ArgoWorkflowsModule(),
  PrometheusModule(),
  GatewayModule(),
];

/// Whether module [id] is on: not turned off in [disabled], nor any module
/// it requires.
bool moduleEnabled(String id, Set<String> disabled) {
  if (disabled.contains(id)) return false;
  final m = builtInModules.where((m) => m.id == id).firstOrNull;
  return m == null || m.requires.every((r) => moduleEnabled(r, disabled));
}

/// The modules that are on (see [AppState.disabledModules]).
List<AppModule> enabledModules(AppState app) => [
      for (final m in builtInModules)
        if (moduleEnabled(m.id, app.disabledModules)) m,
    ];

/// [base] with each of [extra] inserted after the item [after] names (or
/// appended when it names nothing that's there).
List<T> placeAfter<T, K>(List<T> base, Iterable<T> extra, K Function(T) key, K? Function(T) after) {
  final out = [...base];
  for (final e in extra) {
    final a = after(e);
    final i = a == null ? -1 : out.indexWhere((o) => key(o) == a);
    out.insert(i < 0 ? out.length : i + 1, e);
  }
  return out;
}

/// Every page, core and modules', in the default order (the sidebar's and
/// the palette's).
final List<AppPage> allPages = placeAfter(corePages, [for (final m in builtInModules) ...m.pages], (p) => p.view, (p) => p.after);

final Map<MainView, (AppPage, AppModule?)> _pages = {
  for (final p in corePages) p.view: (p, null),
  for (final m in builtInModules)
    for (final p in m.pages) p.view: (p, m),
};

/// The page [v], or null for [MainView.resources] and unknown ids.
AppPage? pageFor(MainView v) => _pages[v]?.$1;

/// Whether page [v] is shown: core pages always, a module's while the
/// module is on.
bool pageEnabled(AppState app, MainView v) {
  final e = _pages[v];
  return e != null && (e.$2 == null || enabledModules(app).contains(e.$2));
}

/// [allPages] that are on, in order.
List<AppPage> enabledPages(AppState app) => [for (final p in allPages) if (pageEnabled(app, p.view)) p];

/// Sidebar glyphs the modules give their kinds.
final Map<String, IconData> moduleKindIcons = {for (final m in builtInModules) ...m.kindIcons};
