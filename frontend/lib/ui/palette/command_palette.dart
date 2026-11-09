import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/app_state.dart';
import '../keys.dart';
import '../theme.dart';
import '../widgets/picker_kit.dart';
import 'palette_commands.dart';
import 'palette_items.dart';
import 'palette_sources.dart';

/// The open palette, so a second ⌘K (or the menu item) closes it.
_CommandPaletteState? _open;

/// ⌘K / ⌘P (Ctrl on Windows and Linux). A focused terminal keeps ⌘K for
/// "clear": it handles the key before it reaches the shell's shortcuts.
final commandPaletteShortcuts = [primaryShortcut(LogicalKeyboardKey.keyK), primaryShortcut(LogicalKeyboardKey.keyP)];

/// Opens the command palette over [context] (the shell's), or closes it if
/// it is already open. Picking a result closes the palette, then runs it.
/// With [command] it opens in `:` command mode (`:po`, `:ns kube-system`).
Future<void> showCommandPalette(BuildContext context, {bool command = false}) async {
  final open = _open;
  if (open != null) {
    open._close();
    return;
  }
  final app = context.read<AppState>();
  final table = visibleTable(context);
  final items = [
    ...paletteItems(context),
    if (table != null)
      for (final r in table.allRows) objectItem(app, table.type, r),
  ];
  final picked = await showGeneralDialog<PaletteItem>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Close command palette',
    barrierColor: Colors.black.withValues(alpha: 0.08),
    // Native: appears instantly.
    transitionDuration: Duration.zero,
    pageBuilder: (_, _, _) => CommandPalette(
      items: items,
      api: context.read<ApiClient>(),
      app: app,
      skip: table?.type,
      command: command,
      viewItem: (v) => viewPaletteItem(context, app, v),
      saveViewItem: table == null || app.view != MainView.resources ? null : (name) => saveViewPaletteItem(context, table, name),
    ),
  );
  picked?.run();
}

/// The palette overlay: a search field over ranked, grouped results.
class CommandPalette extends StatefulWidget {
  final List<PaletteItem> items;

  /// For the by-name object lookup across common kinds (null: none).
  final ApiClient? api;
  final AppState app;

  /// Kind whose objects [items] already has (the visible table's).
  final ResourceType? skip;

  /// Start in command mode (the query is `:`).
  final bool command;
  /// Builds a saved view's item for `:view` (with the shell's context, so
  /// opening it can still show dialogs once the palette has closed).
  final PaletteItem Function(SavedView v)? viewItem;

  /// Builds the item for `:view save <name>` (null: no table to save).
  final PaletteItem Function(String name)? saveViewItem;
  const CommandPalette({super.key, required this.items, required this.app, this.api, this.skip, this.command = false, this.viewItem, this.saveViewItem});

  @override
  State<CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<CommandPalette> {
  static const _rowHeight = 30.0;
  static const _headerHeight = 24.0;

  final _query = TextEditingController();
  final _scroll = ScrollController();
  late final List<PaletteItem> _items = List.of(widget.items);
  List<PaletteSection> _sections = const [];

  /// Results in display order (what ↑/↓ walk).
  List<PaletteItem> _flat = const [];
  int _active = 0;
  bool _loadingObjects = false;
  bool _done = false;

  String get _q => _query.text.trim().toLowerCase();

  /// `:` commands rather than the normal palette.
  bool get _command => _query.text.startsWith(':');
  String _highlight = '';

  @override
  void initState() {
    super.initState();
    _open = this;
    if (widget.command) _query.value = const TextEditingValue(text: ':', selection: TextSelection.collapsed(offset: 1));
    _rank();
    final api = widget.api;
    if (api != null) {
      _loadingObjects = true;
      PaletteObjectCache.load(api, widget.app, skip: widget.skip, onRows: (type, rows) {
        if (!mounted) return;
        _items.addAll([for (final r in rows) objectItem(widget.app, type, r)]);
        // Only re-rank when the new objects could show.
        if (_q.isNotEmpty) setState(_rank);
      }).whenComplete(() {
        if (mounted) setState(() => _loadingObjects = false);
      });
    }
  }

  @override
  void dispose() {
    if (_open == this) _open = null;
    _query.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _rank() {
    final active = _flat.elementAtOrNull(_active);
    if (_command) {
      final r = rankCommand(_query.text.substring(1), widget.app, viewItem: widget.viewItem, saveViewItem: widget.saveViewItem);
      _sections = r.sections;
      _highlight = r.highlight;
    } else {
      _sections = rankPalette(_q, _items);
      _highlight = _q;
    }
    _flat = [for (final s in _sections) ...s.items];
    // Keep the highlighted result if it is still there (objects arriving
    // mustn't move the selection under the user).
    final keep = active == null ? -1 : _flat.indexOf(active);
    _active = keep >= 0 && _q.isNotEmpty && !_command ? keep : 0;
  }

  void _onChanged(String _) {
    setState(() {
      _flat = const [];
      _rank();
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _close([PaletteItem? item]) {
    if (_done) return;
    _done = true;
    Navigator.of(context).pop(item);
  }

  /// Scroll so the active row (and its group header, at the top) shows.
  void _reveal() {
    if (!_scroll.hasClients) return;
    var top = 0.0, i = 0;
    for (final s in _sections) {
      top += _headerHeight;
      if (_active < i + s.items.length) {
        final rowTop = top + (_active - i) * _rowHeight;
        final view = _scroll.position.viewportDimension;
        final first = _active == i;
        if (rowTop - (first ? _headerHeight : 0) < _scroll.offset) {
          _scroll.jumpTo(math.max(0, rowTop - (first ? _headerHeight : 0)));
        } else if (rowTop + _rowHeight > _scroll.offset + view) {
          _scroll.jumpTo(math.min(rowTop + _rowHeight - view + 6, _scroll.position.maxScrollExtent));
        }
        return;
      }
      top += s.items.length * _rowHeight;
      i += s.items.length;
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (primaryModifierPressed && (k == LogicalKeyboardKey.keyK || k == LogicalKeyboardKey.keyP)) {
      _close();
      return KeyEventResult.handled;
    }
    return PickerKeys.handle(
      e,
      count: _flat.length,
      active: _active,
      page: 8,
      onActive: (i) {
        setState(() => _active = i);
        _reveal();
      },
      onEnter: () {
        if (_flat.isNotEmpty) _close(_flat[_active]);
      },
      onEscape: _close,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final size = MediaQuery.sizeOf(context);
    final width = math.min(640.0, size.width - 48);
    final top = math.max(titlebarHeight + 24, size.height * 0.14);
    final maxList = math.max(120.0, math.min(420.0, size.height - top - 140));
    final q = _highlight;

    final children = <Widget>[];
    var index = 0;
    for (final s in _sections) {
      children.add(SizedBox(
        height: _headerHeight,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
          child: Text(s.group.label, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
        ),
      ));
      for (final item in s.items) {
        final i = index++;
        children.add(_ResultRow(
          key: ValueKey('palette-result-$i'),
          item: item,
          query: q,
          active: i == _active,
          onTap: () => _close(item),
          onHover: () => setState(() => _active = i),
        ));
      }
    }
    final listHeight = math.min(maxList, _sections.length * _headerHeight + _flat.length * _rowHeight + 8);

    return Stack(children: [
      Positioned(
        left: (size.width - width) / 2,
        top: top,
        width: width,
        child: Material(
          type: MaterialType.card,
          elevation: 12,
          color: theme.popupMenuTheme.color ?? theme.colorScheme.surfaceContainerHigh,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: BorderSide(color: colors.separator, width: 0.5)),
          clipBehavior: Clip.antiAlias,
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Focus(
              onKeyEvent: _onKey,
              canRequestFocus: false,
              skipTraversal: true,
              child: TextField(
                key: const ValueKey('palette-search'),
                controller: _query,
                autofocus: true,
                onChanged: _onChanged,
                style: theme.textTheme.bodyLarge?.copyWith(fontSize: 16),
                cursorHeight: 18,
                decoration: InputDecoration(
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 13),
                  prefixIcon: const Icon(Icons.search, size: 18),
                  prefixIconConstraints: const BoxConstraints(minWidth: 40, minHeight: 44),
                  hintText: _command ? ':po  :deploy  :ns kube-system  :ctx prod' : 'Go to page, kind, namespace, context or object…  (: for commands)',
                  hintStyle: theme.textTheme.bodyLarge?.copyWith(fontSize: 16, color: colors.faint),
                ),
              ),
            ),
            Container(height: 1, color: colors.separator),
            if (_flat.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 14),
                child: Text(_loadingObjects && !_command ? 'Searching…' : 'No matches',
                    key: const ValueKey('palette-empty'), style: theme.textTheme.bodyMedium?.copyWith(color: theme.hintColor)),
              )
            else
              SizedBox(
                height: listHeight,
                child: Scrollbar(
                  controller: _scroll,
                  child: ListView(
                    controller: _scroll,
                    padding: const EdgeInsets.fromLTRB(6, 0, 6, 8),
                    children: children,
                  ),
                ),
              ),
            Container(height: 1, color: colors.separator),
            _Footer(loading: _loadingObjects && !_command, command: _command),
          ]),
        ),
      ),
    ]);
  }
}

class _Footer extends StatelessWidget {
  final bool loading;
  final bool command;
  const _Footer({required this.loading, required this.command});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor, fontWeight: FontWeight.w400);
    Widget key(String k, String label) => Padding(
          padding: const EdgeInsets.only(right: 14),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Text(k, style: style?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(width: 5),
            Text(label, style: style),
          ]),
        );
    return SizedBox(
      height: 28,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(children: [
          key('↑↓', 'navigate'),
          key('↩', 'open'),
          key('esc', 'close'),
          const Spacer(),
          if (command) Flexible(child: Text(':ns <name>  :ctx <name>  :pf  :alerts', maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
          if (loading)
            Text('Looking up objects…', style: style)
          else if (!command)
            key(':', 'commands'),
        ]),
      ),
    );
  }
}

class _ResultRow extends StatelessWidget {
  final PaletteItem item;
  final String query;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onHover;
  const _ResultRow({super.key, required this.item, required this.query, required this.active, required this.onTap, required this.onHover});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = active ? theme.colorScheme.onPrimary : theme.colorScheme.onSurface;
    final muted = active ? theme.colorScheme.onPrimary.withValues(alpha: 0.8) : theme.hintColor;
    final base = theme.textTheme.bodyMedium!.copyWith(color: fg);
    final hl = base.copyWith(fontWeight: FontWeight.w700, color: active ? null : theme.colorScheme.primary);
    final title = item.title;
    final marks = item.highlight(query).toSet();
    final spans = highlightSpans(title, query, highlight: hl, marks: marks);
    final small = theme.textTheme.labelSmall?.copyWith(color: muted, fontWeight: FontWeight.w400);
    return PickerRowShell(
      active: active,
      onTap: onTap,
      onHover: onHover,
      height: _CommandPaletteState._rowHeight,
      radius: 6,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(children: [
        SizedBox(width: 18, child: Center(child: item.icon(active ? fg : theme.colorScheme.primary))),
        const SizedBox(width: 9),
        Expanded(
          child: Row(children: [
            Flexible(flex: 3, child: Text.rich(TextSpan(children: spans), maxLines: 1, overflow: TextOverflow.ellipsis, style: base)),
            if (item.detail != null) ...[
              const SizedBox(width: 8),
              Flexible(
                flex: 2,
                child: Text(item.detail!, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: muted)),
              ),
            ],
            if (item.current) ...[
              const SizedBox(width: 6),
              Icon(Icons.check, size: 13, color: active ? fg : theme.colorScheme.primary),
            ],
          ]),
        ),
        const SizedBox(width: 10),
        if (item.shortcut != null) ...[
          Text(item.shortcut!, style: small),
          const SizedBox(width: 10),
        ],
        Text(item.typeLabel, style: small),
      ]),
    );
  }
}
