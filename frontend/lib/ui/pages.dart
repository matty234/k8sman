import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'access/access_view.dart';
import 'alerts/alerts_view.dart';
import 'nodes/nodes_view.dart';
import 'overview/overview_view.dart';
import 'portforward/portforward_view.dart';
import 'security/security_view.dart';

/// A page of the main area: its sidebar entry, palette entry and content.
/// Core pages are [corePages]; integration modules add their own (see
/// lib/modules/module.dart).
@immutable
class AppPage {
  final MainView view;
  final IconData icon;
  final String label;
  final WidgetBuilder builder;

  /// Names `:name` goes to the page by (command mode in the palette).
  final List<String> commands;

  /// False for pages that live in the bottom dock (Alerts, Port Forwards):
  /// they are in the palette but not in the sidebar.
  final bool inSidebar;

  /// The page this one follows in the default order (null = at the end).
  final MainView? after;

  /// Starts folded under "More" in the default sidebar layout.
  final bool underMore;

  /// Wraps the page's sidebar row, e.g. to show it only on clusters that
  /// have GPUs. [navNote] explains it in Customise Sidebar.
  final Widget Function(Widget navItem)? navGate;
  final String? navNote;

  const AppPage({
    required this.view,
    required this.icon,
    required this.label,
    required this.builder,
    this.commands = const [],
    this.inSidebar = true,
    this.after,
    this.underMore = false,
    this.navGate,
    this.navNote,
  });
}

/// The core pages, in order. (The resource tables, [MainView.resources],
/// are the shell's own.)
final corePages = <AppPage>[
  AppPage(view: MainView.overview, icon: Icons.space_dashboard_outlined, label: 'Overview', commands: const ['overview'], builder: (_) => const OverviewView()),
  AppPage(
      view: MainView.alerts, icon: Icons.notifications_none, label: 'Alerts', commands: const ['alerts'], inSidebar: false, builder: (_) => const AlertsView()),
  AppPage(view: MainView.nodes, icon: Icons.dns_outlined, label: 'Nodes', commands: const ['nodes'], builder: (_) => const NodesView()),
  AppPage(view: MainView.security, icon: Icons.shield_outlined, label: 'Security', commands: const ['security'], builder: (_) => const SecurityView()),
  AppPage(view: MainView.access, icon: Icons.manage_accounts_outlined, label: 'Access', commands: const ['access', 'rbac'], builder: (_) => const AccessView()),
  AppPage(
    view: MainView.portForwards,
    icon: Icons.swap_horiz,
    label: 'Port Forwards',
    commands: const ['pf', 'forwards', 'portforwards', 'port-forwards'],
    inSidebar: false,
    builder: (_) => const PortForwardView(),
  ),
];
