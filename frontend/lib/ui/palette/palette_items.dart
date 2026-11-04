import 'package:flutter/widgets.dart';

import 'fuzzy.dart';

/// The result groups, in their default order (also the tie-break order when
/// two groups' best matches score the same).
enum PaletteGroup {
  pages('Pages'),
  kinds('Resource Kinds'),
  objects('Objects'),
  namespaces('Namespaces'),
  contexts('Contexts'),
  actions('Actions');

  final String label;
  const PaletteGroup(this.label);
}

/// One palette result.
class PaletteItem {
  final PaletteGroup group;
  final String title;

  /// Muted text after the title (API group, namespace, cluster, …).
  final String? detail;

  /// Small right-aligned label: the kind for objects, "Page", "Namespace", …
  final String typeLabel;

  /// Leading icon.
  final Widget Function(Color color) icon;

  /// Other names it answers to (plural resource name, short names, …).
  final List<String> aliases;

  /// Short names: an exact match counts as an exact title match.
  final List<String> exactAliases;

  /// The current selection (shown with a check, e.g. the active namespace).
  final bool current;

  /// Optional shortcut hint shown on the right (e.g. "⌘J").
  final String? shortcut;

  final VoidCallback run;

  PaletteItem({
    required this.group,
    required this.title,
    required this.typeLabel,
    required this.icon,
    required this.run,
    this.detail,
    this.aliases = const [],
    this.exactAliases = const [],
    this.current = false,
    this.shortcut,
  })  : _lower = title.toLowerCase(),
        _aliasesLower = [for (final a in aliases) a.toLowerCase()],
        _exactLower = [for (final a in exactAliases) a.toLowerCase()];

  final String _lower;
  final List<String> _aliasesLower;
  final List<String> _exactLower;

  /// Best score for lower-cased [q] over the title and aliases, or null.
  int? score(String q) {
    if (_exactLower.contains(q)) return fuzzyMatch(q, q)!.score;
    var best = fuzzyMatch(q, title, lower: _lower)?.score;
    for (var i = 0; i < aliases.length; i++) {
      final s = fuzzyMatch(q, aliases[i], lower: _aliasesLower[i])?.score;
      // An alias match ranks a little below the same match on the title.
      if (s != null && (best == null || s - 8 > best)) best = s - 8;
    }
    return best;
  }

  /// Title character indices matching [q], for highlighting.
  List<int> highlight(String q) => q.isEmpty ? const [] : fuzzyMatch(q, title, lower: _lower, positions: true)?.positions ?? const [];
}

/// A group of ranked results.
class PaletteSection {
  final PaletteGroup group;
  final List<PaletteItem> items;
  const PaletteSection(this.group, this.items);
}

/// Most results each group shows while searching, and with no query.
const _searchCaps = {
  PaletteGroup.pages: 5,
  PaletteGroup.kinds: 8,
  PaletteGroup.objects: 12,
  PaletteGroup.namespaces: 6,
  PaletteGroup.contexts: 6,
  PaletteGroup.actions: 5,
};
const _browseCaps = {
  PaletteGroup.pages: 20,
  PaletteGroup.kinds: 0,
  PaletteGroup.objects: 0,
  PaletteGroup.namespaces: 6,
  PaletteGroup.contexts: 6,
  PaletteGroup.actions: 10,
};

/// Nudges the whole-group order towards places over objects when best
/// matches are close (typing "dep" should lead with the Deployment kind).
const _groupBias = {PaletteGroup.pages: 12, PaletteGroup.kinds: 10, PaletteGroup.actions: 4};

/// Ranks [items] for [query]. With no query: the groups in default order,
/// capped (objects and kinds only appear once you type). Otherwise each
/// group's matches best first, and groups ordered by their best match.
List<PaletteSection> rankPalette(String query, List<PaletteItem> items) {
  final q = query.trim().toLowerCase();
  final byGroup = <PaletteGroup, List<(int, int, PaletteItem)>>{};
  for (var i = 0; i < items.length; i++) {
    final it = items[i];
    final s = q.isEmpty ? 0 : it.score(q);
    if (s == null) continue;
    byGroup.putIfAbsent(it.group, () => []).add((s, i, it));
  }
  final caps = q.isEmpty ? _browseCaps : _searchCaps;
  final sections = <(int, PaletteSection)>[];
  for (final g in PaletteGroup.values) {
    final list = byGroup[g];
    final cap = caps[g] ?? 0;
    if (list == null || cap == 0) continue;
    // Best score first; equal scores keep source order (stable).
    list.sort((a, b) => a.$1 != b.$1 ? b.$1 - a.$1 : a.$2 - b.$2);
    sections.add((list.first.$1 + (_groupBias[g] ?? 0), PaletteSection(g, [for (final e in list.take(cap)) e.$3])));
  }
  if (q.isNotEmpty) {
    sections.sort((a, b) => a.$1 != b.$1 ? b.$1 - a.$1 : a.$2.group.index - b.$2.group.index);
  }
  return [for (final s in sections) s.$2];
}
