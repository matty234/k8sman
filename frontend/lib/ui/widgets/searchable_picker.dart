import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme.dart';
import 'common.dart';

/// One choice in a [SearchablePicker].
class PickerOption<T> {
  final T value;
  final String label;

  /// Optional muted text after the label (e.g. a context's cluster).
  final String? detail;
  const PickerOption(this.value, this.label, {this.detail});
}

/// Opens an instant popover under [anchorContext]'s widget: a search field
/// (autofocused), then [pinned] options (e.g. "All namespaces"), then
/// [recents] (hidden while searching), then [items] filtered by a
/// case-insensitive substring match with the match highlighted.
///
/// ↑/↓ move, Enter picks, Esc closes. Returns the picked option, or null.
/// [items] is rendered lazily, so thousands of entries stay smooth.
Future<PickerOption<T>?> showSearchablePicker<T>(
  BuildContext anchorContext, {
  required List<PickerOption<T>> items,
  List<PickerOption<T>> pinned = const [],
  List<PickerOption<T>> recents = const [],
  T? selected,
  String hint = 'Search',
  String recentsLabel = 'Recent',
  double width = 280,
  double maxListHeight = 320,
}) {
  final box = anchorContext.findRenderObject() as RenderBox?;
  final nav = Navigator.of(anchorContext);
  final overlay = nav.overlay?.context.findRenderObject() as RenderBox?;
  if (box == null || overlay == null) return Future.value();
  final anchor = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
  return showGeneralDialog<PickerOption<T>>(
    context: anchorContext,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.transparent,
    // Native popovers appear instantly.
    transitionDuration: Duration.zero,
    pageBuilder: (context, _, _) => _PickerPopover<T>(
      anchor: anchor,
      overlaySize: overlay.size,
      items: items,
      pinned: pinned,
      recents: recents,
      selected: selected,
      hint: hint,
      recentsLabel: recentsLabel,
      width: math.max(width, anchor.width),
      maxListHeight: maxListHeight,
    ),
  );
}

/// A control that opens [showSearchablePicker]. [builder] draws the button
/// given its hover state.
class SearchablePicker<T> extends StatelessWidget {
  final List<PickerOption<T>> Function() items;
  final List<PickerOption<T>> Function()? pinned;
  final List<PickerOption<T>> Function()? recents;
  final T? selected;
  final ValueChanged<T> onSelected;
  final Widget Function(bool hovered) builder;
  final String hint;
  final String? tooltip;
  final double width;
  const SearchablePicker({
    super.key,
    required this.items,
    required this.onSelected,
    required this.builder,
    this.pinned,
    this.recents,
    this.selected,
    this.hint = 'Search',
    this.tooltip,
    this.width = 280,
  });

  @override
  Widget build(BuildContext context) {
    final button = Builder(
      builder: (ctx) => Hoverable(
        cursor: SystemMouseCursors.basic,
        onTap: () async {
          final picked = await showSearchablePicker<T>(
            ctx,
            items: items(),
            pinned: pinned?.call() ?? const [],
            recents: recents?.call() ?? const [],
            selected: selected,
            hint: hint,
            width: width,
          );
          if (picked != null) onSelected(picked.value);
        },
        builder: builder,
      ),
    );
    return tooltip == null ? button : Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 600), child: button);
  }
}

class _PickerPopover<T> extends StatefulWidget {
  final Rect anchor;
  final Size overlaySize;
  final List<PickerOption<T>> items;
  final List<PickerOption<T>> pinned;
  final List<PickerOption<T>> recents;
  final T? selected;
  final String hint;
  final String recentsLabel;
  final double width;
  final double maxListHeight;
  const _PickerPopover({
    required this.anchor,
    required this.overlaySize,
    required this.items,
    required this.pinned,
    required this.recents,
    required this.selected,
    required this.hint,
    required this.recentsLabel,
    required this.width,
    required this.maxListHeight,
  });

  @override
  State<_PickerPopover<T>> createState() => _PickerPopoverState<T>();
}

class _PickerPopoverState<T> extends State<_PickerPopover<T>> {
  static const _rowHeight = 26.0;
  final _query = TextEditingController();
  final _scroll = ScrollController();
  late List<PickerOption<T>> _matches = widget.items;
  int _active = 0;
  bool _done = false;

  String get _q => _query.text.trim().toLowerCase();

  /// Pinned and recent options shown above the list (recents only when not searching).
  List<PickerOption<T>> get _header => [...widget.pinned, if (_q.isEmpty) ...widget.recents];

  int get _count => _header.length + _matches.length;

  PickerOption<T> _at(int i) => i < _header.length ? _header[i] : _matches[i - _header.length];

  @override
  void initState() {
    super.initState();
    final sel = widget.selected;
    final h = _header;
    var i = h.indexWhere((o) => o.value == sel);
    if (i < 0) {
      final j = widget.items.indexWhere((o) => o.value == sel);
      i = j < 0 ? 0 : h.length + j;
    }
    _active = i;
    if (i >= h.length) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _reveal());
    }
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
      _matches = q.isEmpty ? widget.items : [for (final o in widget.items) if (o.label.toLowerCase().contains(q)) o];
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

  /// Scroll the list so the active row is visible.
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

  void _pick([int? i]) {
    if (_done) return;
    final idx = i ?? _active;
    if (idx < 0 || idx >= _count) return;
    _done = true;
    Navigator.of(context).pop(_at(idx));
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
        _pick();
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
    final listHeight = math.min(_matches.length * _rowHeight + 8, widget.maxListHeight);
    final width = math.min(widget.width, widget.overlaySize.width - 16);
    final double left = widget.anchor.left.clamp(8.0, math.max(8.0, widget.overlaySize.width - width - 8));
    final top = widget.anchor.bottom + 4;
    final maxHeight = math.max(120.0, widget.overlaySize.height - top - 8);

    Widget row(int i) {
      final o = _at(i);
      return _OptionRow(
        key: ValueKey('picker-option-$i'),
        label: o.label,
        detail: o.detail,
        query: i < header.length && i < widget.pinned.length ? '' : _q,
        selected: o.value == widget.selected,
        active: i == _active,
        onTap: () => _pick(i),
        onHover: () => setState(() => _active = i),
      );
    }

    final sep = Container(height: 1, margin: const EdgeInsets.symmetric(vertical: 4), color: colors.separator);
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
                      onSubmitted: (_) => _pick(),
                      style: theme.textTheme.bodyMedium,
                      decoration: InputDecoration(prefixIcon: const Icon(Icons.search, size: 15), hintText: widget.hint),
                    ),
                  ),
                ),
              ),
              for (var i = 0; i < header.length; i++) ...[
                if (i == widget.pinned.length && widget.recents.isNotEmpty && _q.isEmpty) ...[
                  if (i > 0) sep,
                  Padding(
                    padding: const EdgeInsets.fromLTRB(14, 2, 12, 2),
                    child: Text(widget.recentsLabel, style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
                  ),
                ],
                Padding(padding: const EdgeInsets.symmetric(horizontal: 4), child: SizedBox(height: _rowHeight, child: row(i))),
              ],
              if (header.isNotEmpty && _matches.isNotEmpty) sep,
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
            ]),
          ),
        ),
      ),
    ]);
  }
}

class _OptionRow extends StatelessWidget {
  final String label;
  final String? detail;
  final String query;
  final bool selected;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onHover;
  const _OptionRow({
    super.key,
    required this.label,
    required this.query,
    required this.selected,
    required this.active,
    required this.onTap,
    required this.onHover,
    this.detail,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final base = theme.textTheme.bodyMedium!.copyWith(color: active ? theme.colorScheme.onPrimary : null);
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
    return MouseRegion(
      onHover: (_) => active ? null : onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: BoxDecoration(color: active ? theme.colorScheme.primary : null, borderRadius: BorderRadius.circular(5)),
          child: Row(children: [
            SizedBox(width: 18, child: selected ? Icon(Icons.check, size: 14, color: active ? theme.colorScheme.onPrimary : theme.colorScheme.primary) : null),
            Flexible(child: Text.rich(TextSpan(children: spans), maxLines: 1, overflow: TextOverflow.ellipsis, style: base)),
            if (detail != null) ...[
              const SizedBox(width: 8),
              Flexible(
                child: Text(detail!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(color: active ? theme.colorScheme.onPrimary.withValues(alpha: 0.8) : theme.hintColor)),
              ),
            ],
          ]),
        ),
      ),
    );
  }
}
