import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../../state/app_state.dart';
import '../theme.dart';
import 'common.dart';

/// A searchable namespace popover: "All namespaces", recently used scopes,
/// then every namespace with a checkbox.
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
                    Expanded(child: Text(scope.label, overflow: TextOverflow.ellipsis, maxLines: 1, style: theme.textTheme.bodyMedium)),
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
      recents: [for (final r in app.recentNamespaces) if (r != value) r],
      value: value,
      onChanged: onChanged,
    ),
  );
}

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
  const _NsRow(this.name, {this.missing = false});
}

class _NamespacePopover extends StatefulWidget {
  final Rect anchor;
  final Size overlaySize;
  final double width;
  final List<String> namespaces;
  final bool listed;
  final List<NamespaceScope> recents;
  final NamespaceScope value;
  final ValueChanged<NamespaceScope> onChanged;
  const _NamespacePopover({
    required this.anchor,
    required this.overlaySize,
    required this.width,
    required this.namespaces,
    required this.listed,
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
  late List<_NsRow> _matches = _allNamespaces;
  int _active = 0;
  bool _done = false;

  String get _q => _query.text.trim().toLowerCase();

  /// Selected namespaces the cluster doesn't list come first.
  late final List<_NsRow> _allNamespaces = [
    if (widget.listed)
      for (final n in widget.value.namespaces)
        if (!widget.namespaces.contains(n)) _NsRow(n, missing: true),
    for (final n in widget.namespaces) _NsRow(n),
  ];

  List<_Row> get _header => [const _AllRow(), if (_q.isEmpty) ...[for (final r in widget.recents) _RecentRow(r)]];

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
    super.dispose();
  }

  void _onChanged(String _) {
    final q = _q;
    setState(() {
      _matches = q.isEmpty ? _allNamespaces : [for (final r in _allNamespaces) if (r.name.toLowerCase().contains(q)) r];
      // While searching, Enter takes the first match.
      _active = q.isNotEmpty && _matches.isNotEmpty ? _header.length : 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  void _move(int delta) {
    if (_count == 0) return;
    setState(() => _active = (_active + delta).clamp(0, _count - 1));
    _reveal();
  }

  void _reveal() {
    final i = _active - _header.length;
    if (i < 0 || !_scroll.hasClients) return;
    final top = i * _rowHeight;
    final view = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > _scroll.offset + view) {
      _scroll.jumpTo(math.min(top + _rowHeight - view, _scroll.position.maxScrollExtent));
    }
  }

  /// Picks row [i] alone and closes.
  void _pick([int? i]) {
    if (_done) return;
    final idx = i ?? _active;
    if (idx < 0 || idx >= _count) return;
    _done = true;
    final scope = switch (_at(idx)) {
      _AllRow() => NamespaceScope.all,
      _RecentRow(:final scope) => scope,
      _NsRow(:final name) => NamespaceScope.single(name),
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
    setState(() {
      _value = _value.toggle(row.name);
      _active = idx;
    });
    widget.onChanged(_value);
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1);
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
      case LogicalKeyboardKey.pageDown:
        _move(10);
      case LogicalKeyboardKey.pageUp:
        _move(-10);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        HardwareKeyboard.instance.isShiftPressed ? _toggle() : _pick();
      case LogicalKeyboardKey.escape:
        if (!_done) {
          _done = true;
          Navigator.of(context).pop();
        }
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colors = AppColors.of(context);
    final header = _header;
    final listHeight = math.min(_matches.length * _rowHeight + 8, 320.0);
    final width = math.min(widget.width, widget.overlaySize.width - 16);
    final double left = widget.anchor.left.clamp(8.0, math.max(8.0, widget.overlaySize.width - width - 8));
    final top = widget.anchor.bottom + 4;
    final maxHeight = math.max(120.0, widget.overlaySize.height - top - 8);

    Widget row(int i) {
      final r = _at(i);
      return _PickerRow(
        key: ValueKey('picker-option-$i'),
        row: r,
        query: r is _NsRow ? _q : '',
        value: _value,
        active: i == _active,
        onTap: () => _pick(i),
        onToggle: () => _toggle(i),
        onHover: () => setState(() => _active = i),
      );
    }

    final sep = Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 4), color: colors.separator);
    final small = theme.textTheme.labelSmall?.copyWith(color: theme.hintColor);
    return Stack(children: [
      Positioned(
        left: left,
        top: top,
        width: width,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxHeight),
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
              for (var i = 0; i < header.length; i++) ...[
                if (i == 1) ...[sep, Padding(padding: const EdgeInsets.fromLTRB(14, 2, 12, 2), child: Text('Recent', style: small))],
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
                  _value.isMulti ? '${_value.namespaces.length} namespaces · ☐ or ⇧↩ adds or removes' : 'Click shows one · ☐ or ⇧↩ adds more',
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

class _PickerRow extends StatelessWidget {
  final _Row row;
  final String query;
  final NamespaceScope value;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onToggle;
  final VoidCallback onHover;
  const _PickerRow({
    super.key,
    required this.row,
    required this.query,
    required this.value,
    required this.active,
    required this.onTap,
    required this.onToggle,
    required this.onHover,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final fg = active ? theme.colorScheme.onPrimary : null;
    final base = theme.textTheme.bodyMedium!.copyWith(color: fg);
    final (String label, bool selected, bool missing) = switch (row) {
      _AllRow() => ('All namespaces', value.isAll, false),
      _RecentRow(:final scope) => (scope.label, false, false),
      _NsRow(:final name, :final missing) => (name, value.namespaces.contains(name), missing),
    };
    final spans = <TextSpan>[];
    final i = query.isEmpty ? -1 : label.toLowerCase().indexOf(query);
    if (i < 0) {
      spans.add(TextSpan(text: label));
    } else {
      final hl = TextStyle(fontWeight: FontWeight.w700, color: active ? null : theme.colorScheme.primary);
      spans
        ..add(TextSpan(text: label.substring(0, i)))
        ..add(TextSpan(text: label.substring(i, i + query.length), style: hl))
        ..add(TextSpan(text: label.substring(i + query.length)));
    }
    final style = missing ? base.copyWith(decoration: TextDecoration.lineThrough, color: fg ?? theme.hintColor) : base;
    final Widget lead = switch (row) {
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
    return MouseRegion(
      onHover: (_) => active ? null : onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.only(left: 2, right: 6),
          decoration: BoxDecoration(color: active ? theme.colorScheme.primary : null, borderRadius: BorderRadius.circular(5)),
          child: Row(children: [
            lead,
            Flexible(child: Text.rich(TextSpan(children: spans), maxLines: 1, overflow: TextOverflow.ellipsis, style: style)),
            if (missing) ...[
              const SizedBox(width: 8),
              Text('not found', style: theme.textTheme.bodySmall?.copyWith(color: active ? fg : theme.hintColor)),
            ],
          ]),
        ),
      ),
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
