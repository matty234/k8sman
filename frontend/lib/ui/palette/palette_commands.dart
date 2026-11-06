import 'package:flutter/material.dart';

import '../../modules/modules.dart';
import '../../state/app_state.dart';
import '../resource_nav.dart';
import 'palette_items.dart';

Widget Function(Color) _icon(IconData i) => (c) => Icon(i, size: 15, color: c);

/// What `:` command mode shows for the text after the colon.
class CommandResults {
  final List<PaletteSection> sections;

  /// What to highlight in the titles.
  final String highlight;
  const CommandResults(this.sections, this.highlight);
}

/// Resolves k9s-style commands: `:po`, `:deploy`, `:ns [name]`,
/// `:ctx [name]`, `:pf`, `:alerts`, … ([text] is what follows the colon).
CommandResults rankCommand(String text, AppState app) {
  final lower = text.trimLeft().toLowerCase();
  final space = lower.indexOf(RegExp(r'\s'));
  final cmd = space < 0 ? lower : lower.substring(0, space);
  final arg = space < 0 ? '' : lower.substring(space).trim();

  // "ns" alone is the Namespace kind (k9s); "ns <name>" picks a namespace.
  if (space >= 0 && (cmd == 'ns' || cmd == 'namespace' || cmd == 'namespaces')) {
    final items = [
      PaletteItem(
        group: PaletteGroup.namespaces,
        title: 'All namespaces',
        typeLabel: 'Namespace',
        icon: _icon(Icons.folder_copy_outlined),
        current: app.namespace == null,
        run: () => app.setNamespace(null),
      ),
      for (final ns in app.namespaces)
        PaletteItem(
          group: PaletteGroup.namespaces,
          title: ns,
          typeLabel: 'Namespace',
          icon: _icon(Icons.folder_outlined),
          current: app.namespace == ns,
          run: () => app.setNamespace(ns),
        ),
    ];
    final all = arg == 'all' || arg == '-a';
    return CommandResults([PaletteSection(PaletteGroup.namespaces, _filter(all ? '' : arg, items, first: all ? items.first : null))], arg);
  }
  if (cmd == 'ctx' || cmd == 'context' || cmd == 'contexts') {
    final items = [
      for (final c in app.contexts)
        PaletteItem(
          group: PaletteGroup.contexts,
          title: c.name,
          detail: c.cluster != c.name ? c.cluster : null,
          typeLabel: 'Context',
          icon: _icon(Icons.cloud_outlined),
          current: c.name == app.currentContext,
          run: () => c.name == app.currentContext ? null : app.switchContext(c.name),
        ),
    ];
    return CommandResults([PaletteSection(PaletteGroup.contexts, _filter(arg, items))], arg);
  }

  // Kinds: exact short name, plural or kind first, then fuzzy.
  final scored = <(bool, int, PaletteItem)>[];
  if (cmd.isNotEmpty) {
    for (final t in app.types) {
      if (t.gk == 'events.k8s.io/Event') continue;
      final item = PaletteItem(
        group: PaletteGroup.kinds,
        title: t.kind,
        detail: t.group.isEmpty ? t.version : t.group,
        typeLabel: t.custom ? 'Custom Kind' : 'Kind',
        icon: (c) => kindIconWidget(t, size: 15, color: c),
        aliases: [t.resource, ...t.shortNames],
        current: app.view == MainView.resources && app.selectedType == t,
        run: () => app.selectType(t),
      );
      final s = item.score(cmd);
      if (s != null) scored.add(([t.kind, t.resource, ...t.shortNames].any((n) => n.toLowerCase() == cmd), s, item));
    }
    scored.sort((a, b) => a.$1 != b.$1 ? (a.$1 ? -1 : 1) : b.$2 - a.$2);
  }
  final kinds = [for (final k in scored.take(8)) k.$3];

  // Pages, unless a kind has the name (`:nodes` is the Node kind).
  final pages = <(bool, int, PaletteItem)>[];
  if (!scored.any((k) => k.$1)) {
    // `:name` goes to a page by its commands.
    for (final p in enabledPages(app)) {
      final item = PaletteItem(
        group: PaletteGroup.pages,
        title: p.label,
        typeLabel: 'Page',
        icon: _icon(p.icon),
        aliases: p.commands,
        exactAliases: p.commands,
        current: app.view == p.view,
        run: () => app.showView(p.view),
      );
      final s = cmd.isEmpty ? 0 : item.score(cmd);
      if (s != null) pages.add((p.commands.contains(cmd), s, item));
    }
    pages.sort((a, b) => a.$1 != b.$1 ? (a.$1 ? -1 : 1) : b.$2 - a.$2);
  }
  final pageItems = [for (final p in pages.take(5)) p.$3];
  final pageFirst = pages.isNotEmpty && pages.first.$1;
  return CommandResults([
    if (pageFirst) PaletteSection(PaletteGroup.pages, pageItems),
    if (kinds.isNotEmpty) PaletteSection(PaletteGroup.kinds, kinds),
    if (!pageFirst && pageItems.isNotEmpty) PaletteSection(PaletteGroup.pages, pageItems),
  ], cmd);
}

/// [items] fuzzy-matching [q] best first (all of them for an empty [q]),
/// with [first] (if any) leading.
List<PaletteItem> _filter(String q, List<PaletteItem> items, {PaletteItem? first}) {
  if (q.isEmpty) return first == null ? items : [first, ...items.where((i) => i != first)];
  final scored = [
    for (final i in items)
      if (i.score(q) case final s?) (s, i)
  ]..sort((a, b) => b.$1 - a.$1);
  return [for (final s in scored) s.$2];
}
