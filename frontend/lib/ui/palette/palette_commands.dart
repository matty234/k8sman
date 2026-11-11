import 'package:flutter/material.dart';

import '../../modules/modules.dart';
import '../../state/app_state.dart';
import '../resource_nav.dart';
import '../settings/settings_page.dart';
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
///
/// [viewItem] builds a saved view's item (it needs a BuildContext to open
/// views; see palette_sources.dart).
///
/// [saveViewItem] builds the `:view save <name>` item (null when no table
/// is open to save).
CommandResults rankCommand(
  String text,
  AppState app, {
  PaletteItem Function(SavedView v)? viewItem,
  PaletteItem Function(String name)? saveViewItem,
}) {
  final lower = text.trimLeft().toLowerCase();
  final space = lower.indexOf(RegExp(r'\s'));
  final cmd = space < 0 ? lower : lower.substring(0, space);
  final arg = space < 0 ? '' : lower.substring(space).trim();

  // "ns" alone is the Namespace kind (k9s); "ns <name>" picks a namespace,
  // "ns a,b" a set, "ns +a" / "ns -a" adds to or removes from the set.
  if (space >= 0 && (cmd == 'ns' || cmd == 'namespace' || cmd == 'namespaces')) {
    final set = _namespaceSetCommand(arg, app);
    if (set != null) return set;
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
  // `:view [name]`: saved views, fuzzy matched like :ctx. `:view save
  // <name>` saves the open table (the name keeps its case).
  if (cmd == 'view' || cmd == 'views') {
    final saveWord = RegExp(r'^save(\s+|$)', caseSensitive: false);
    if (saveWord.hasMatch(arg)) {
      final name = text.trimLeft().substring(space).trim().replaceFirst(saveWord, '').trim();
      return CommandResults([
        if (saveViewItem != null && name.isNotEmpty) PaletteSection(PaletteGroup.views, [saveViewItem(name)]),
      ], '');
    }
    final items = [if (viewItem != null) for (final v in app.savedViews) viewItem(v)];
    return CommandResults([PaletteSection(PaletteGroup.views, _filter(arg, items))], arg);
  }
  // `:settings [section]`: the Settings page, at a section.
  if (cmd == 'settings' || cmd == 'preferences' || cmd == 'prefs') {
    final named = SettingsSection.parse(arg);
    final items = [
      for (final s in settingsSections(app))
        PaletteItem(
          group: PaletteGroup.pages,
          title: 'Settings: ${s.title}',
          typeLabel: 'Settings',
          icon: _icon(s.icon),
          aliases: [s.name],
          run: () => showSettings(app, section: s),
        ),
    ];
    final first = named == null ? null : items.where((i) => i.title == 'Settings: ${named.title}').firstOrNull;
    return CommandResults([PaletteSection(PaletteGroup.pages, first != null ? [first, ...items.where((i) => i != first)] : _filter(arg, items))], arg);
  }
  // Add-ons live in Settings now: `:addons` opens that section.
  if ((cmd == 'addons' || cmd == 'add-ons') && settingsSections(app).contains(SettingsSection.addons)) {
    return CommandResults([
      PaletteSection(PaletteGroup.pages, [
        PaletteItem(
          group: PaletteGroup.pages,
          title: 'Add-ons',
          typeLabel: 'Settings',
          icon: _icon(SettingsSection.addons.icon),
          aliases: const ['addons', 'add-ons'],
          run: () => showSettings(app, section: SettingsSection.addons),
        ),
      ]),
    ], cmd);
  }
  // `:diagnostics`: Settings ▸ Diagnostics.
  if (cmd == 'diagnostics' || cmd == 'errors') {
    return CommandResults([
      PaletteSection(PaletteGroup.pages, [
        PaletteItem(
          group: PaletteGroup.pages,
          title: 'Diagnostics',
          typeLabel: 'Settings',
          icon: _icon(SettingsSection.diagnostics.icon),
          aliases: const ['diagnostics', 'errors'],
          run: () => showSettings(app, section: SettingsSection.diagnostics),
        ),
      ]),
    ], cmd);
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
  // Kinds with a page of their own (Node) are found as the page.
  final homes = kindHomes(app);
  if (cmd.isNotEmpty) {
    for (final t in app.types) {
      if (t.gk == 'events.k8s.io/Event' || homes.containsKey(t.gk)) continue;
      final item = PaletteItem(
        group: PaletteGroup.kinds,
        title: t.kind,
        detail: t.group.isEmpty ? t.version : t.group,
        typeLabel: t.custom ? 'Custom Kind' : 'Kind',
        icon: (c) => kindIconWidget(t, size: 15, color: c),
        aliases: [t.resource, ...t.shortNames, kindLabel(t)],
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
      if (p.view == MainView.settings) continue;
      final names = [...p.commands, ...pageKindNames(app, p).map((n) => n.toLowerCase())];
      final item = PaletteItem(
        group: PaletteGroup.pages,
        title: p.label,
        typeLabel: 'Page',
        icon: _icon(p.icon),
        aliases: names,
        exactAliases: names,
        current: app.view == p.view || app.activeHomePage == p.view,
        run: () => app.showView(p.view),
      );
      final s = cmd.isEmpty ? 0 : item.score(cmd);
      if (s != null) pages.add((names.contains(cmd), s, item));
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

/// `:ns a,b` (a set) and `:ns +a` / `:ns -a` (change the set), or null for
/// a plain `:ns <name>`.
CommandResults? _namespaceSetCommand(String arg, AppState app) {
  PaletteItem scopeItem(NamespaceScope s, {String? title}) => PaletteItem(
        group: PaletteGroup.namespaces,
        title: title ?? s.namespaces.join(', '),
        detail: [for (final n in s.namespaces) if (app.namespacesListed && !app.namespaces.contains(n)) n].isEmpty ? null : 'not found: ${[
          for (final n in s.namespaces)
            if (app.namespacesListed && !app.namespaces.contains(n)) n,
        ].join(', ')}',
        typeLabel: s.isMulti ? 'Namespaces' : 'Namespace',
        icon: _icon(s.isMulti ? Icons.folder_copy_outlined : Icons.folder_outlined),
        current: app.namespaceScope == s,
        run: () => app.setNamespaceScope(s),
      );
  if (arg.contains(',')) {
    final s = NamespaceScope.parse(arg);
    if (s.isAll) return null;
    return CommandResults([PaletteSection(PaletteGroup.namespaces, [scopeItem(s)])], '');
  }
  if (arg.startsWith('+') || arg.startsWith('-')) {
    final add = arg.startsWith('+');
    final q = arg.substring(1).trim();
    final candidates = add ? app.namespaces.where((n) => !app.namespaceScope.namespaces.contains(n)) : app.namespaceScope.namespaces;
    final items = [
      for (final n in candidates)
        scopeItem(add ? app.namespaceScope.add(n) : app.namespaceScope.remove(n), title: '${add ? 'Add' : 'Remove'} $n'),
    ];
    return CommandResults([PaletteSection(PaletteGroup.namespaces, _filter(q, items))], q);
  }
  return null;
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
