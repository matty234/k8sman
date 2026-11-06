/// The module API: how an integration (Argo CD, Helm, GPUs, …) plugs into
/// the app. Modules are compiled in and listed in modules.dart; there is
/// no dynamic loading. Core features (tables, logs, terminals,
/// port-forwards, nodes, security, access, the editor) are not modules.
library;

import 'package:flutter/material.dart';

import '../panels/panel.dart';
import '../state/app_state.dart';
import '../ui/pages.dart';

export '../panels/panel.dart' show ResourcePanel;
export '../ui/pages.dart' show AppPage;

/// A section of the sidebar's kinds list ("Argo CD", "Gateway API", …).
@immutable
class NavGroup {
  final String title;

  /// Kinds in display order, as `group/Kind`.
  final List<String> kinds;

  /// The section this one follows (null = at the end).
  final String? after;
  const NavGroup(this.title, this.kinds, {this.after});
}

/// One built-in integration. Override only what the module has.
abstract class AppModule {
  const AppModule();

  /// Stable id: matches the backend module (internal/server/module.go) and
  /// is what settings save when the module is turned off.
  String get id;

  /// Display name (Integrations settings).
  String get name;

  /// Ids of modules this one needs (Add-ons installs through Helm): it is
  /// off while any of them is.
  List<String> get requires => const [];

  /// Pages in the sidebar, the palette (`:` commands too) and the main area.
  List<AppPage> get pages => const [];

  /// Inspector panels for the module's kinds.
  List<ResourcePanel> get panels => const [];

  /// Sections of the sidebar's kinds list. Without them the kinds land
  /// under Custom Resources like any CRD.
  List<NavGroup> get navGroups => const [];

  /// Sidebar glyphs for the module's kinds (`group/Kind` → icon).
  Map<String, IconData> get kindIcons => const {};

  /// Whether the current cluster has what the module works with (e.g. its
  /// CRDs are served). Only informational: a module works the same either
  /// way, its panels and groups simply have nothing to show.
  bool isAvailable(AppState app) => true;
}
