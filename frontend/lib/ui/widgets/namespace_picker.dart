import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../keys.dart';
import '../theme.dart';
import 'common.dart';
import 'picker_kit.dart';

/// A searchable namespace popover: "All namespaces", starred namespaces
/// (Favourites), recently used scopes, then every namespace with a checkbox
/// and a star. A multi-namespace selection also shows as removable chips
/// under the search field.
///
/// Clicking a namespace (or Enter) shows only that namespace; its checkbox
/// (or ⇧Enter) adds it to or removes it from the set, leaving the popover
/// open. Selected namespaces the cluster doesn't have (e.g. from a saved
/// view or pin) are listed first, struck through.
///
/// By default it is the toolbar filter and drives
/// [AppState.namespaceScope]. Use [NamespacePicker.scope] for a page's own
/// scope (see [PageScope]) instead.
class NamespacePicker extends StatelessWidget {
  /// Button height; the toolbar uses 26.
  final double height;

  /// The selected scope when [onChanged] is set.
  final NamespaceScope? value;
  final ValueChanged<NamespaceScope>? onChanged;
  const NamespacePicker({super.key, this.height = 26}) : value = null, onChanged = null;

  /// A page-scope picker (independent of [AppState.namespaceScope]).
  const NamespacePicker.scope({super.key, required NamespaceScope this.value, required ValueChanged<NamespaceScope> this.onChanged, this.height = 26});

  @override
  Widget build(BuildContext context) {
    final app = context.watch<AppState>();
    final theme = Theme.of(context);
    final scoped = onChanged != null;
    final scope = scoped ? value! : app.namespaceScope;
    final set = onChanged ?? app.setNamespaceScope;
    final button = Builder(
      builder: (ctx) => Hoverable(
        cursor: SystemMouseCursors.basic,
        onTap: () => showNamespacePopover(ctx, app: app, value: scope, onChanged: set),
        builder: (h) => Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: theme.inputDecorationTheme.fillColor?.withValues(alpha: h ? 0.14 : null),
            borderRadius: BorderRadius.circular(6),
          ),
          child: LayoutBuilder(
            // Squeezed (e.g. a page header at 360px): just the folder icon.
            builder: (context, box) => box.maxWidth < 60
                ? Center(child: Icon(scope.isMulti ? Icons.folder_copy_outlined : Icons.folder_outlined, size: 14, color: theme.hintColor))
                : Row(children: [
                    Icon(scope.isMulti ? Icons.folder_copy_outlined : Icons.folder_outlined, size: 14, color: theme.hintColor),
                    const SizedBox(width: 6),
                    Expanded(child: Text(scope.isMulti ? '${scope.namespaces.length} namespaces' : scope.label, overflow: TextOverflow.ellipsis, maxLines: 1, style: theme.textTheme.bodyMedium)),
                    Icon(Icons.unfold_more, size: 14, color: theme.hintColor),
                  ]),
          ),
        ),
      ),
    );
    return Tooltip(
      key: ValueKey(scoped ? 'page-scope-picker' : 'namespace-picker'),
      message: scope.isMulti ? scope.namespaces.join('\n') : (scoped ? 'Scope' : 'Namespace'),
      waitDuration: const Duration(milliseconds: 600),
      child: button,
    );
  }
}

/// Opens the namespace popover under [anchorContext]'s widget. Each change
/// is applied at once through [onChanged].
Future<void> showNamespacePopover(
  BuildContext anchorContext, {
  required AppState app,
  required NamespaceScope value,
  required ValueChanged<NamespaceScope> onChanged,
  double width = 280,
}) {
  final box = anchorContext.findRenderObject() as RenderBox?;
  final nav = Navigator.of(anchorContext);
  final overlay = nav.overlay?.context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null) return Future.value();
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  return showGeneralDialog<void>(
    context: anchorContext,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => _NamespacePopover(
      anchor: anchor,
      overlaySize: overlay.size,
      width: math.max(width, anchor.width),
      namespaces: app.namespaces,
      listed: app.namespacesListed,
      remembered: app.rememberedNamespaces,
      kubeNamespace: app.kubeconfigNamespace,
      onRemember: app.rememberNamespace,
      onForget: app.forgetNamespace,
      favourites: app.favouriteNamespaces,
      onFavourite: app.toggleFavouriteNamespace,
      fallback: app.defaultNamespaceScope,
      recents: [for (final r in app.recentNamespaces) if (r != value) r],
      value: value,
      onChanged: onChanged,
    ),
  );
}

final _dns1123 = RegExp(r'^[a-z0-9]([-a-z0-9]*[a-z0-9])?$');

/// One row of the popover.
sealed class _Row {
  const _Row();
}

class _AllRow extends _Row {
  const _AllRow();
}

class _RecentRow extends _Row {
  final NamespaceScope scope;
  const _RecentRow(this.scope);
}

class _NsRow extends _Row {
  final String name;

  /// Selected but not in the cluster's list.
  final bool missing;

  /// Added by the user (remembered), not in the cluster's list: can be removed.
  final bool custom;

  /// "Use namespace “name”": the typed text, not in the list yet.
  final bool add;
  const _NsRow(this.name, {this.missing = false, this.custom = false, this.add = false});
}

class _NamespacePopover extends StatefulWidget {
  final Rect anchor;
  final Size overlaySize;
  final double width;
  final List<String> namespaces;
  final bool listed;
  final List<String> remembered;
  final String? kubeNamespace;
  final Future<void> Function(String) onRemember;
  final Future<void> Function(String) onForget;
  final List<String> favourites;
  final Future<void> Function(String) onFavourite;

  /// Where removing the last chip (or Clear) goes.
  final NamespaceScope fallback;
  final List<NamespaceScope> recents;
  final NamespaceScope value;
  final ValueChanged<NamespaceScope> onChanged;
  const _NamespacePopover({
    required this.anchor,
    required this.overlaySize,
    required this.width,
    required this.namespaces,
    required this.listed,
    required this.remembered,
    required this.kubeNamespace,
    required this.onRemember,
    required this.onForget,
    required this.favourites,
    required this.onFavourite,
    required this.fallback,
    required this.recents,
    required this.value,
    required this.onChanged,
  });

  @override
  State<_NamespacePopover> createState() => _NamespacePopoverState();
}

class _NamespacePopoverState extends State<_NamespacePopover> {
  static const _rowHeight = 26.0;
  final _query = TextEditingController();
  final _scroll = ScrollController();
  late NamespaceScope _value = widget.value;
  late final Set<String> _remembered = {...widget.remembered};
  late final Set<String> _favs = {...widget.favourites};
  late List<_NsRow> _allNamespaces = _buildAll();
  late List<_NsRow> _matches = _allNamespaces;
  // The highlighted row. A notifier, so moving it rebuilds only the rows that
  // gain or lose it, not the whole popover (hover fires on every scroll frame).
  final _activeRow = ValueNotifier<int>(0);
  int get _active => _activeRow.value;
  set _active(int i) => _activeRow.value = i;
  late List<_Row> _header = _buildHeader();
  int _favCount = 0;
  bool _done = false;

  String get _q => _query.text.trim().toLowerCase();

  /// Selected namespaces the cluster doesn't list come first, then the
  /// listed, remembered and kubeconfig namespaces merged.
  List<_NsRow> _buildAll() {
    final kube = widget.kubeNamespace;
    final known = {...widget.namespaces, ..._remembered, ?kube};
    // The cluster's order, then the extras (remembered, kubeconfig) sorted.
    final extras = [for (final n in known) if (!widget.namespaces.contains(n)) n]..sort();
    // Without a list, a selected namespace is as good as any other.
    final selected = widget.value.namespaces.where((s) => !known.contains(s));
    return [
      if (widget.listed) for (final s in selected) _NsRow(s, missing: true),
      for (final n in [...widget.namespaces, ...extras, if (!widget.listed) ...selected])
        _NsRow(n, custom: _remembered.contains(n) && !widget.namespaces.contains(n) && n != kube),
    ];
  }

  /// The rows matching the search, plus "Use namespace" for a valid new name.
  List<_NsRow> _filter() {
    final q = _q;
    if (q.isEmpty) return _allNamespaces;
    final found = [for (final r in _allNamespaces) if (r.name.toLowerCase().contains(q)) r];
    // Offered when namespaces can't be listed, or nothing else matches.
    final offer = (!widget.listed || found.isEmpty) && _dns1123.hasMatch(q) && !_allNamespaces.any((r) => r.name == q);
    return [...found, if (offer) _NsRow(q, add: true)];
  }

  /// Starred namespaces, by name; hidden while searching (the list below
  /// shows them, starred).
  List<_NsRow> get _favRows {
    if (_q.isNotEmpty) return const [];
    final known = {...widget.namespaces, ..._remembered, ?widget.kubeNamespace};
    return [for (final n in _favs.toList()..sort()) _NsRow(n, missing: widget.listed && !known.contains(n))];
  }

  /// The rows above the list; recomputed only when the search, stars or
  /// remembered namespaces change, not on every build.
  List<_Row> _buildHeader() {
    final favs = _favRows;
    _favCount = favs.length;
    return [const _AllRow(), ...favs, if (_q.isEmpty) ...[for (final r in widget.recents) _RecentRow(r)]];
  }

  int get _count => _header.length + _matches.length;

  _Row _at(int i) {
    final h = _header;
    return i < h.length ? h[i] : _matches[i - h.length];
  }

  @override
  void initState() {
    super.initState();
    // Start on the current choice: All, or the first selected namespace.
    final first = widget.value.namespaces.firstOrNull;
    final j = first == null ? -1 : _matches.indexWhere((r) => r.name == first);
    _active = j < 0 ? 0 : _header.length + j;
    if (j >= 0) WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
  }

  @override
  void dispose() {
    _query.dispose();
    _scroll.dispose();
    _activeRow.dispose();
    super.dispose();
  }

  void _onChanged(String _) {
    final q = _q;
    setState(() {
      _matches = _filter();
      _header = _buildHeader();
      // While searching, Enter takes the first match.
      _active = q.isNotEmpty && _matches.isNotEmpty ? _header.length : 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _reveal() => PickerKeys.reveal(_scroll, _active - _header.length, _rowHeight);

  /// Picks row [i] alone and closes.
  void _pick([int? i]) {
    if (_done) return;
    final idx = i ?? _active;
    if (idx < 0 || idx >= _count) return;
    _done = true;
    final scope = switch (_at(idx)) {
      _AllRow() => NamespaceScope.all,
      _RecentRow(:final scope) => scope,
      _NsRow(:final name, :final add) => () {
          if (add) widget.onRemember(name);
          return NamespaceScope.single(name);
        }(),
    };
    Navigator.of(context).pop();
    if (scope != widget.value) widget.onChanged(scope);
  }

  /// Adds row [i]'s namespace to the set or removes it; stays open.
  void _toggle([int? i]) {
    final idx = i ?? _active;
    if (idx < 0 || idx >= _count) return;
    final row = _at(idx);
    if (row is! _NsRow) return _pick(idx);
    if (row.add) {
      // Remember it, and show it as an ordinary row from now on.
      widget.onRemember(row.name);
      _remembered.add(row.name);
      _header = _buildHeader();
      _allNamespaces = _buildAll();
      _matches = _filter();
    }
    setState(() {
      _value = _value.toggle(row.name);
      _active = idx;
    });
    widget.onChanged(_value);
  }

  void _star(String name) {
    widget.onFavourite(name);
    setState(() {
      _favs.contains(name) ? _favs.remove(name) : _favs.add(name);
      _header = _buildHeader();
      _active = _active.clamp(0, math.max(0, _count - 1));
    });
  }

  /// Takes [name] out of the selection; the last one goes to the fallback.
  void _unselect(String name) {
    final next = _value.remove(name);
    setState(() => _value = next.isAll ? widget.fallback : next);
    widget.onChanged(_value);
  }

  void _clear() {
    setState(() => _value = widget.fallback);
    widget.onChanged(_value);
  }

  void _forget(String name) {
    widget.onForget(name);
    setState(() {
      _remembered.remove(name);
      _header = _buildHeader();
      _allNamespaces = _buildAll();
      _matches = _filter();
      _active = _active.clamp(0, math.max(0, _count - 1));
    });
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) => PickerKeys.handle(
        e,
        count: _count,
        active: _active,
        page: 10,
        onActive: (i) {
          setState(() => _active = i);
          _reveal();
        },
        onEnter: () => HardwareKeyboard.instance.isShiftPressed ? _toggle() : _pick(),
        onEscape: () {
          if (!_done) {
            _done = true;
            Navigator.of(context).pop();
          }
        },
      );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final header = _header;
    final favCount = _favCount;
    final selectedNs = _value.namespaces.toSet();
    final recentCount = header.length - 1 - favCount;
    final listHeight = math.min(_matches.length * _rowHeight + 8, 320.0);
    final place = popoverPlacement(widget.anchor, widget.overlaySize, widget.width);

    Widget row(int i) {
      final r = _at(i);
      return _PickerRow(
        key: ValueKey('picker-option-$i'),
        row: r,
        query: r is _NsRow ? _q : '',
        selected: r is _AllRow ? _value.isAll : r is _NsRow && selectedNs.contains(r.name),
        index: i,
        activeRow: _activeRow,
        // ⌘-click (Ctrl-click) or ⇧-click adds or removes, like a Finder list.
        onTap: () => primaryModifierPressed || HardwareKeyboard.instance.isShiftPressed ? _toggle(i) : _pick(i),
        onToggle: () => _toggle(i),
        onHover: () => _active = i,
        onRemove: r is _NsRow && r.custom ? () => _forget(r.name) : null,
        starred: r is _NsRow && !r.add && _favs.contains(r.name),
        onStar: r is _NsRow && !r.add ? () => _star(r.name) : null,
      );
    }

    final sep = Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 4), color: colors.separator);
    final small = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    return Stack(children: [
      Positioned(
        left: place.left,
        top: place.top,
        width: place.width,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: place.maxHeight),
          child: Material(
            type: MaterialType.card,
            elevation: 8,
            color: theme.popupMenuTheme.color ?? theme.colorScheme.surfaceContainerHigh,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: BorderSide(color: colors.separator, width: 0.5)),
            clipBehavior: Clip.antiAlias,
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 6, 4),
                child: SizedBox(
                  height: 26,
                  child: Focus(
                    onKeyEvent: _onKey,
                    canRequestFocus: false,
                    skipTraversal: true,
                    child: TextField(
                      key: const ValueKey('picker-search'),
                      controller: _query,
                      autofocus: true,
                      onChanged: _onChanged,
                      style: theme.textTheme.bodyMedium,
                      decoration: const InputDecoration(prefixIcon: Icon(Icons.search, size: 15), hintText: 'Search namespaces'),
                    ),
                  ),
                ),
              ),
              if (_value.isMulti)
                _SelectionChips(namespaces: _value.namespaces, onRemove: _unselect, onClear: _clear),
              if (!widget.listed)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                  child: Text("You can't list namespaces here; type one to add it.", key: const ValueKey('picker-unlisted-hint'), style: small),
                ),
              for (var i = 0; i < header.length; i++) ...[
                if (i == 1 && favCount > 0) ...[sep, Padding(padding: const EdgeInsets.fromLTRB(14, 2, 12, 2), child: Text('Favourites', style: small))],
                if (i == 1 + favCount && recentCount > 0) ...[sep, Padding(padding: const EdgeInsets.fromLTRB(14, 2, 12, 2), child: Text('Recent', style: small))],
                Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: SizedBox(height: _rowHeight, child: row(i))),
              ],
              if (_matches.isNotEmpty) sep,
              if (_matches.isEmpty && _q.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 6, 12, 10),
                  child: Text('No matches', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
                )
              else
                Flexible(
                  child: SizedBox(
                    height: listHeight,
                    child: Scrollbar(
                      controller: _scroll,
                      child: ListView.builder(
                        controller: _scroll,
                        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
                        itemExtent: _rowHeight,
                        itemCount: _matches.length,
                        itemBuilder: (_, j) => row(header.length + j),
                      ),
                    ),
                  ),
                ),
              Container(height: 1, color: colors.separator),
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 5, 12, 6),
                child: Text(
                  _value.isMulti
                      ? '${_value.namespaces.length} namespaces · ${useCtrlShortcuts ? 'Ctrl' : '⌘'}-click or ⇧↩ adds or removes'
                      : 'Click shows one · ${useCtrlShortcuts ? 'Ctrl' : '⌘'}-click or ⇧↩ adds more',
                  style: small,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ]),
          ),
        ),
      ),
    ]);
  }
}

/// Tests: how many picker rows have been built.
@visibleForTesting
int debugRowBuilds = 0;

class _PickerRow extends StatefulWidget {
  final _Row row;
  final String query;
  final bool selected;

  /// This row's position, and the notifier holding the highlighted position.
  final int index;
  final ValueNotifier<int> activeRow;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onHover;
  final VoidCallback? onRemove;
  final bool starred;
  final VoidCallback? onStar;
  const _PickerRow({
    super.key,
    required this.row,
    required this.query,
    required this.selected,
    required this.index,
    required this.activeRow,
    required this.onTap,
    required this.onToggle,
    required this.onHover,
    this.onRemove,
    this.starred = false,
    this.onStar,
  });

  @override
  State<_PickerRow> createState() => _PickerRowState();
}

class _PickerRowState extends State<_PickerRow> {
  late bool active = widget.activeRow.value == widget.index;

  @override
  void initState() {
    super.initState();
    widget.activeRow.addListener(_sync);
  }

  @override
  void didUpdateWidget(_PickerRow old) {
    super.didUpdateWidget(old);
    if (old.activeRow != widget.activeRow) {
      old.activeRow.removeListener(_sync);
      widget.activeRow.addListener(_sync);
    }
    active = widget.activeRow.value == widget.index;
  }

  @override
  void dispose() {
    widget.activeRow.removeListener(_sync);
    super.dispose();
  }

  void _sync() {
    final now = widget.activeRow.value == widget.index;
    if (now != active) setState(() => active = now);
  }

  _Row get row => widget.row;
  String get query => widget.query;
  VoidCallback get onTap => widget.onTap;
  VoidCallback get onToggle => widget.onToggle;
  VoidCallback get onHover => widget.onHover;
  VoidCallback? get onRemove => widget.onRemove;
  bool get starred => widget.starred;
  VoidCallback? get onStar => widget.onStar;

  @override
  Widget build(BuildContext context) {
    debugRowBuilds++;
    final theme = Theme.of(context);
    final fg = active ? theme.colorScheme.onPrimary : null;
    final base = theme.textTheme.bodyMedium!.copyWith(color: fg);
    final selected = widget.selected;
    final (String label, bool missing) = switch (row) {
      _AllRow() => ('All namespaces', false),
      _RecentRow(:final scope) => (scope.label, false),
      _NsRow(:final name, :final missing, :final add) => (add ? 'Use namespace “$name”' : name, missing),
    };
    final spans = highlightSpans(label, query, highlight: TextStyle(fontWeight: FontWeight.w700, color: active ? null : theme.colorScheme.primary));
    final style = missing ? base.copyWith(decoration: TextDecoration.lineThrough, color: fg ?? theme.hintColor) : base;
    final Widget lead = switch (row) {
      _NsRow(add: true) => SizedBox(width: 22, child: Icon(Icons.add, size: 14, color: active ? fg : theme.colorScheme.primary)),
      _NsRow() => GestureDetector(
          key: const ValueKey('picker-checkbox'),
          behavior: HitTestBehavior.opaque,
          onTap: onToggle,
          child: SizedBox(
            width: 22,
            child: Icon(
              selected ? Icons.check_box : Icons.check_box_outline_blank,
              size: 15,
              color: active ? theme.colorScheme.onPrimary : (selected ? theme.colorScheme.primary : theme.hintColor),
            ),
          ),
        ),
      _RecentRow() => SizedBox(width: 22, child: Icon(Icons.history, size: 13, color: active ? fg : theme.hintColor)),
      _AllRow() => SizedBox(width: 22, child: selected ? Icon(Icons.check, size: 14, color: active ? fg : theme.colorScheme.primary) : null),
    };
    return PickerRowShell(
      active: active,
      onTap: onTap,
      onHover: onHover,
      padding: const EdgeInsets.only(left: 2, right: 6),
      child: Row(children: [
        lead,
        Flexible(child: Text.rich(TextSpan(children: spans), maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
        if (missing) ...[
          const SizedBox(width: 8),
          Text('not found', style: theme.textTheme.bodySmall?.copyWith(color: active ? fg : theme.hintColor)),
        ],
        if (onStar != null && (starred || active)) ...[
          const SizedBox(width: 4),
          Tooltip(
            message: starred ? 'Remove from favourites' : 'Add to favourites',
            child: GestureDetector(
              key: const ValueKey('picker-star'),
              behavior: HitTestBehavior.opaque,
              onTap: onStar,
              child: Padding(
                padding: const EdgeInsets.all(3),
                child: Icon(
                  starred ? Icons.star : Icons.star_border,
                  size: 14,
                  color: starred ? (active ? fg : Colors.amber.shade600) : (active ? fg : theme.hintColor),
                ),
              ),
            ),
          ),
        ],
        if (onRemove != null) ...[
          const SizedBox(width: 8),
          Text('added by you', style: theme.textTheme.bodySmall?.copyWith(color: active ? fg : theme.hintColor)),
          const SizedBox(width: 2),
          Tooltip(
            message: 'Remove from remembered namespaces',
            child: GestureDetector(
              key: const ValueKey('picker-remove'),
              behavior: HitTestBehavior.opaque,
              onTap: onRemove,
              child: Padding(padding: const EdgeInsets.all(3), child: Icon(Icons.close, size: 13, color: active ? fg : theme.hintColor)),
            ),
          ),
        ],
      ]),
    );
  }
}

/// The selected namespaces as chips, each removable, plus Clear.
class _SelectionChips extends StatelessWidget {
  final List<String> namespaces;
  final ValueChanged<String> onRemove;
  final VoidCallback onClear;
  const _SelectionChips({required this.namespaces, required this.onRemove, required this.onClear});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 6, 4),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Expanded(
          // 40 selected namespaces scroll rather than push the list away.
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 58),
            child: SingleChildScrollView(
              child: Wrap(spacing: 4, runSpacing: 4, children: [
                for (final n in namespaces)
                  Container(
                    key: ValueKey('picker-chip-$n'),
                    padding: const EdgeInsets.only(left: 6),
                    decoration: BoxDecoration(color: primary.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(10)),
                    child: Row(mainAxisSize: MainAxisSize.min, children: [
                      Flexible(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 140), child: Text(n, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.labelSmall))),
                      Tooltip(
                        message: 'Remove $n from the selection',
                        child: GestureDetector(
                          key: ValueKey('picker-chip-remove-$n'),
                          behavior: HitTestBehavior.opaque,
                          onTap: () => onRemove(n),
                          child: Padding(padding: const EdgeInsets.all(3), child: Icon(Icons.close, size: 12, color: theme.hintColor)),
                        ),
                      ),
                    ]),
                  ),
              ]),
            ),
          ),
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: 'Clear the selection',
          child: GestureDetector(
            key: const ValueKey('picker-clear'),
            behavior: HitTestBehavior.opaque,
            onTap: onClear,
            child: Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text('Clear', style: theme.textTheme.labelSmall?.copyWith(color: primary))),
          ),
        ),
      ]),
    );
  }
}

/// Each page's own namespace scope, independent of the table's
/// [AppState.namespaceScope] and remembered for the session.
class PageScope {
  PageScope._();
  static final _scopes = <String, NamespaceScope>{};

  static NamespaceScope of(String page) => _scopes[page] ?? NamespaceScope.all;
  static void set(String page, NamespaceScope scope) => _scopes[page] = scope;

  /// Tests: forget every page's scope.
  @visibleForTesting
  static void reset() => _scopes.clear();
}

/// The page-scope picker sized for the [PageHeader] subtitle slot.
class PageScopePicker extends StatelessWidget {
  final NamespaceScope value;
  final ValueChanged<NamespaceScope> onChanged;
  const PageScopePicker({super.key, required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) => SizedBox(width: 200, child: NamespacePicker.scope(value: value, onChanged: onChanged));
}
