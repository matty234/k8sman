import 'package:flutter/foundation.dart';

import 'app_state.dart';

/// A resource kind pinned to the top of the sidebar. Keyed by API group and
/// kind (not version), so a pin applies on every cluster that serves it.
@immutable
class SidebarPin {
  final String group;
  final String kind;

  /// Optional: clicking the pin also switches to this namespace.
  final String? namespace;
  const SidebarPin({required this.group, required this.kind, this.namespace});

  /// `group/Kind`, as [ResourceType.gk].
  String get gk => '$group/$kind';

  @override
  bool operator ==(Object other) => other is SidebarPin && other.group == group && other.kind == kind && other.namespace == namespace;
  @override
  int get hashCode => Object.hash(group, kind, namespace);
}

/// One entry of the sidebar's top section: a page ([view]) or a [pin].
@immutable
class SidebarEntry {
  final MainView? view;
  final SidebarPin? pin;

  /// Pages only: folded under "More" instead of shown.
  final bool hidden;

  const SidebarEntry.view(MainView this.view, {this.hidden = false}) : pin = null;
  const SidebarEntry.pin(SidebarPin this.pin)
      : view = null,
        hidden = false;

  SidebarEntry withHidden(bool h) => SidebarEntry.view(view!, hidden: h);

  Map<String, dynamic> toJson() => view != null
      ? {'view': view!.name, if (hidden) 'hidden': true}
      : {if (pin!.group.isNotEmpty) 'group': pin!.group, 'kind': pin!.kind, if (pin!.namespace != null) 'namespace': pin!.namespace};

  static SidebarEntry? fromJson(Map<String, dynamic> j) {
    final v = j['view'] as String?;
    if (v != null) {
      final view = MainView.values.where((m) => m.name == v && m != MainView.resources).firstOrNull;
      return view == null ? null : SidebarEntry.view(view, hidden: j['hidden'] == true);
    }
    final kind = j['kind'] as String?;
    if (kind == null || kind.isEmpty) return null;
    final ns = j['namespace'] as String?;
    return SidebarEntry.pin(SidebarPin(group: (j['group'] as String?) ?? '', kind: kind, namespace: ns?.isNotEmpty == true ? ns : null));
  }

  @override
  bool operator ==(Object other) => other is SidebarEntry && other.view == view && other.pin == pin && other.hidden == hidden;
  @override
  int get hashCode => Object.hash(view, pin, hidden);
}

/// The user's layout of the sidebar's top section: which pages show (the
/// rest fold under "More"), their order, and pinned kinds mixed in.
/// Persisted in the backend's settings.json (`/api/settings/sidebar`).
@immutable
class SidebarConfig {
  final List<SidebarEntry> entries;
  const SidebarConfig._(this.entries);

  /// Pages in the sidebar, in the default order. Less-used ones start
  /// under "More".
  static const pages = [
    MainView.overview,
    MainView.nodes,
    MainView.gpus,
    MainView.security,
    MainView.access,
    MainView.metrics,
    MainView.helm,
    MainView.addons,
  ];
  static const _underMoreByDefault = {MainView.metrics, MainView.helm, MainView.addons};

  static final SidebarConfig defaults = SidebarConfig._(List.unmodifiable([
    for (final p in pages) SidebarEntry.view(p, hidden: _underMoreByDefault.contains(p)),
  ]));

  /// Normalises [entries]: every page exactly once (pages missing from a
  /// saved layout, e.g. new in this version, are appended with their
  /// default visibility), duplicate pins dropped.
  factory SidebarConfig(Iterable<SidebarEntry> entries) {
    final out = <SidebarEntry>[];
    final seenViews = <MainView>{};
    final seenPins = <SidebarPin>{};
    for (final e in entries) {
      // Pages that left the sidebar (Alerts, Port Forwards: now in the dock) drop out.
      if (e.view != null && !pages.contains(e.view)) continue;
      if (e.view != null ? seenViews.add(e.view!) : seenPins.add(e.pin!)) out.add(e);
    }
    for (final p in pages) {
      if (!seenViews.contains(p)) out.add(SidebarEntry.view(p, hidden: _underMoreByDefault.contains(p)));
    }
    return SidebarConfig._(List.unmodifiable(out));
  }

  /// From `/api/settings/sidebar`'s `sidebar` value (null = defaults).
  factory SidebarConfig.fromJson(Map<String, dynamic>? j) {
    if (j == null) return defaults;
    return SidebarConfig([
      for (final i in (j['items'] as List? ?? const []))
        if (i is Map) ?SidebarEntry.fromJson(Map<String, dynamic>.from(i)),
    ]);
  }

  Map<String, dynamic> toJson() => {'items': [for (final e in entries) e.toJson()]};

  bool get isDefault => listEquals(entries, defaults.entries);

  List<SidebarPin> get pins => [for (final e in entries) ?e.pin];
  bool isPinned(SidebarPin p) => pins.contains(p);
  bool isHidden(MainView v) => entries.any((e) => e.view == v && e.hidden);

  SidebarConfig setHidden(MainView v, bool hidden) =>
      SidebarConfig([for (final e in entries) e.view == v ? e.withHidden(hidden) : e]);

  /// Pins go after the last visible entry (so they don't land under More).
  SidebarConfig pin(SidebarPin p) {
    if (isPinned(p)) return this;
    final at = entries.lastIndexWhere((e) => !e.hidden) + 1;
    return SidebarConfig([...entries]..insert(at, SidebarEntry.pin(p)));
  }

  SidebarConfig unpin(SidebarPin p) => SidebarConfig([for (final e in entries) if (e.pin != p) e]);
}
