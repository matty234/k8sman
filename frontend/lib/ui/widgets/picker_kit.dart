import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// Shared pieces of the keyboard-driven popover lists (searchable picker,
/// namespace picker, command palette).
abstract final class PickerKeys {
  /// Handles ↑/↓, PageUp/PageDown (by [page]), Enter and Esc for a list of
  /// [count] rows whose highlighted row is [active]. A move calls [onActive]
  /// with the clamped new index; nothing moves when [count] is 0.
  static KeyEventResult handle(
    KeyEvent e, {
    required int count,
    required int active,
    required int page,
    required ValueChanged<int> onActive,
    required VoidCallback onEnter,
    required VoidCallback onEscape,
  }) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    void move(int delta) {
      if (count > 0) onActive((active + delta).clamp(0, count - 1));
    }

    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        move(1);
      case LogicalKeyboardKey.arrowUp:
        move(-1);
      case LogicalKeyboardKey.pageDown:
        move(page);
      case LogicalKeyboardKey.pageUp:
        move(-page);
      case LogicalKeyboardKey.enter || LogicalKeyboardKey.numpadEnter:
        onEnter();
      case LogicalKeyboardKey.escape:
        onEscape();
      default:
        return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  /// Scrolls [scroll] so row [index] (of fixed [rowHeight]) is visible.
  static void reveal(ScrollController scroll, int index, double rowHeight) {
    if (index < 0 || !scroll.hasClients) return;
    final top = index * rowHeight;
    final view = scroll.position.viewportDimension;
    if (top < scroll.offset) {
      scroll.jumpTo(top);
    } else if (top + rowHeight > scroll.offset + view) {
      scroll.jumpTo(math.min(top + rowHeight - view, scroll.position.maxScrollExtent));
    }
  }
}

/// Where a popover anchored under a button goes: clamped inside the overlay.
({double left, double top, double width, double maxHeight}) popoverPlacement(Rect anchor, Size overlay, double wanted) {
  final width = math.min(wanted, overlay.width - 16);
  final double left = anchor.left.clamp(8.0, math.max(8.0, overlay.width - width - 8));
  final top = anchor.bottom + 4;
  return (left: left, top: top, width: width, maxHeight: math.max(120.0, overlay.height - top - 8));
}

/// A list row's hit area and background: primary when [active], hover
/// activates it.
class PickerRowShell extends StatelessWidget {
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onHover;
  final EdgeInsetsGeometry padding;
  final double? height;
  final double radius;
  final Widget child;
  const PickerRowShell({
    super.key,
    required this.active,
    required this.onTap,
    required this.onHover,
    required this.padding,
    required this.child,
    this.height,
    this.radius = 5,
  });

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onHover: (_) => active ? null : onHover(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          height: height,
          padding: padding,
          decoration: BoxDecoration(color: active ? Theme.of(context).colorScheme.primary : null, borderRadius: BorderRadius.circular(radius)),
          child: child,
        ),
      ),
    );
  }
}

/// [label] split around the first case-insensitive match of [query] (or at
/// the character positions in [marks]) with [highlight] on the matches.
List<TextSpan> highlightSpans(String label, String query, {TextStyle? base, required TextStyle highlight, Set<int>? marks}) {
  if (marks != null) {
    final spans = <TextSpan>[];
    for (var i = 0; i < label.length;) {
      final on = marks.contains(i);
      var j = i + 1;
      while (j < label.length && marks.contains(j) == on) {
        j++;
      }
      spans.add(TextSpan(text: label.substring(i, j), style: on ? highlight : base));
      i = j;
    }
    return spans;
  }
  final i = query.isEmpty ? -1 : label.toLowerCase().indexOf(query);
  if (i < 0) return [TextSpan(text: label, style: base)];
  return [
    TextSpan(text: label.substring(0, i), style: base),
    TextSpan(text: label.substring(i, i + query.length), style: highlight),
    TextSpan(text: label.substring(i + query.length), style: base),
  ];
}
