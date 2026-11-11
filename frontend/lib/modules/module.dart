/// The module API: how an integration (Argo CD, Helm, GPUs, …) plugs into
/// the app. Modules are compiled in and listed in modules.dart; there is
/// no dynamic loading. Core features (tables, logs, terminals,
/// port-forwards, nodes, security, access, the editor) are not modules.
library;

import 'package:flutter/material.dart';

import '../api/client.dart';
import '../panels/panel.dart';
import '../ui/pages.dart';

export '../panels/panel.dart' show PanelContext, PanelTab, ResourcePanel;
export '../ui/pages.dart' show AppPage;

/// A section of the sidebar's kinds list ("Argo CD", "Gateway API", …).
@immutable
class NavGroup {
  final String title;

  /// Kinds in display order, as `group/Kind`.
  final List<String> kinds;
  const NavGroup(this.title, this.kinds);
}

/// Where a module stands on the current cluster, from [AppModule.detect].
enum ModuleState {
  /// Being checked.
  checking,

  /// What it integrates with isn't on this cluster.
  notInstalled,

  /// Found and working.
  connected,

  /// Found and working, with something to look at (e.g. a plugin's status
  /// count of severity warning).
  warning,

  /// Found, but not working (unreachable, forbidden, …).
  error,
}

@immutable
class ModuleStatus {
  final ModuleState state;

  /// One line for Settings ▸ Integrations, e.g. "relay v1.18 · 13 nodes".
  final String? message;
  const ModuleStatus(this.state, [this.message]);

  static const checking = ModuleStatus(ModuleState.checking);
}

/// A module's user setting: on and off are explicit; auto (the default of
/// modules with [AppModule.autoByDefault]) is on where [AppModule.detect]
/// finds the integration and off elsewhere.
enum ModuleMode { on, off, auto }

/// One built-in integration. Override only what the module has.
abstract class AppModule {
  const AppModule();

  /// Stable id: matches the backend module (internal/server/module.go) and
  /// is what settings save when the module is turned off.
  String get id;

  /// Display name (Settings ▸ Integrations).
  String get name;

  /// One line on what the module adds, under its name in Settings (and
  /// matched by the settings search).
  String get description => '';

  /// Ids of modules this one needs (Add-ons installs through Helm): it is
  /// off while any of them is.
  List<String> get requires => const [];

  /// Whether the module starts in [ModuleMode.auto]: active only on a
  /// cluster where [detect] finds the integration, until the user turns it
  /// on or off. Needs [detect]. The backend's AutoModule is the same
  /// switch for its routes and background work.
  bool get autoByDefault => false;

  /// The quiet note on the Installed row while the module is on auto.
  String get autoNote => 'Auto: on when found';

  /// Pages in the sidebar, the palette (`:` commands too) and the main area.
  List<AppPage> get pages => const [];

  /// Inspector panels for the module's kinds.
  List<ResourcePanel> get panels => const [];

  /// Sections of the sidebar's kinds list. Without them the kinds land
  /// under Custom Resources like any CRD.
  List<NavGroup> get navGroups => const [];

  /// Sidebar glyphs for the module's kinds (`group/Kind` → icon).
  Map<String, IconData> get kindIcons => const {};

  /// Asks the backend how the module stands on the current cluster: its
  /// CRDs or service found, and whether it works (see [ModuleStatus]). Run
  /// once per kube context, on first use, and cached: read it through
  /// [moduleStatuses] (modules.dart), which Settings ▸ Integrations shows.
  /// Null = nothing to detect.
  Future<ModuleStatus> Function(ApiClient api)? get detect => null;

  /// Inspector tabs the module adds to objects of any kind, including
  /// kinds it doesn't own (e.g. a Flows tab on Pods). Called on every
  /// rebuild of the inspector: return quickly, and nothing for kinds it
  /// doesn't handle. They follow the kind's own [ResourcePanel.tabs].
  List<PanelTab> inspectorTabs(PanelContext ctx) => const [];

  /// The module's settings form, shown inline under the module's row in
  /// Settings ▸ Integrations (no title or Close button: the row has the
  /// name). Settings are saved per kube context with
  /// [ApiClient.getModuleSettings] / [ApiClient.putModuleSettings]; the
  /// backend module validates them (`Configurable`).
  WidgetBuilder? get settingsBuilder => null;
}
