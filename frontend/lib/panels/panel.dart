import 'package:flutter/material.dart';

import '../actions/actions.dart';
import '../api/client.dart';
import '../api/models.dart';
import '../state/app_state.dart';
import '../util/k8s.dart';

/// Everything a panel needs to render one object.
class PanelContext {
  /// The live object (re-delivered on every watch update).
  final Json object;
  final ResourceType type;
  final ApiClient api;
  final AppState app;

  const PanelContext({required this.object, required this.type, required this.api, required this.app});

  String get name => dig<String>(object, ['metadata', 'name']) ?? '';
  String? get namespace => dig<String>(object, ['metadata', 'namespace']);
  String get uid => dig<String>(object, ['metadata', 'uid']) ?? '';
  Json get spec => asMap(object['spec']);
  Json get status => asMap(object['status']);
  Json get metadata => asMap(object['metadata']);
}

/// An extra tab in the detail sidebar beside Overview / YAML / Events.
class PanelTab {
  final String label;

  /// Identity for remembering the open tab (default: [label]); a plugin
  /// tab's is `plugin:<plugin>:<tab id>`, so retitling it keeps it.
  final String? id;
  final IconData? icon;
  final Widget Function(BuildContext context, PanelContext ctx) builder;

  /// A small widget after the label (e.g. a count); it may draw nothing.
  final Widget Function(BuildContext context, PanelContext ctx)? badge;

  /// The tab's role for plugins: a plugin tab whose `into` names it
  /// (`security`) is drawn inside this tab rather than as a tab of its own.
  final String? slot;

  String get key => id ?? label;
  const PanelTab({required this.label, this.id, this.icon, required this.builder, this.badge, this.slot});
}

/// Renders kind-specific detail sections. The shell renders a quiet owner
/// line first (see [ownerInHeader]), then [buildSections] in order, then
/// the shared Metadata section, collapsed.
///
/// Sections are rebuilt whenever the object changes (live watch), so any
/// stateful child must be keyed stably (e.g. `ValueKey(ctx.uid)`) and must
/// not refetch on every rebuild — cache futures in State keyed by uid.
abstract class ResourcePanel {
  const ResourcePanel();

  /// `group/Kind` keys this panel handles, e.g. `{'/Pod'}`, `{'apps/Deployment'}`.
  Set<String> get kinds;

  List<Widget> buildSections(BuildContext context, PanelContext ctx);

  /// True when the panel already lists the object's children prominently
  /// (a Deployment's ReplicaSets and Pods), so the shell skips its generic
  /// "Owns" section.
  bool get showsOwned => false;

  /// True when the panel's status header shows the object's owner (with
  /// `OwnerLine` / `ownerFact` from `ui/inspector/`), so the
  /// shell skips its quiet "Owned by" line at the top of the Overview.
  bool get ownerInHeader => false;

  /// Optional extra tabs (e.g. Logs for pods).
  List<PanelTab> tabs(PanelContext ctx) => const [];

  /// Extra header actions beyond [standardActions] (scale/restart/delete/…,
  /// which the sidebar already shows for the relevant kinds). For inline
  /// controls inside sections use `ScaleControl` / `ActionButton` from
  /// `lib/actions/actions.dart`.
  List<ResourceAction> actions(PanelContext ctx) => const [];
}
