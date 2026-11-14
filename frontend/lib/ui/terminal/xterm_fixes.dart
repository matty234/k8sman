import 'package:xterm/xterm.dart';

/// [Terminal] with package:xterm 4.0's delete-lines (CSI M) fixed.
///
/// xterm's `Buffer.deleteLines` shifts lines up with
/// `lines[i] = lines[i + count]`, which leaves the same line object in two
/// slots; overwriting the lower slot then marks it detached while it's still
/// shown in the upper one. Its index goes stale, so a selection anchored to
/// it lands on another row. TUIs that redraw with CSI M (Claude Code, after
/// every resize) hit this all the time. Moving lines with `swap`, as
/// `insertLines` already does, keeps each line in exactly one slot.
class FixedTerminal extends Terminal {
  FixedTerminal({super.maxLines, super.platform, super.mouseHandler});

  @override
  void deleteLines(int amount) {
    final b = buffer;
    if (!b.isInVerticalMargin) return;
    b.setCursorX(0);
    final y = b.absoluteCursorY;
    final bottom = b.absoluteMarginBottom;
    final count = amount.clamp(0, bottom - y + 1);
    final toMove = bottom - y + 1 - count;
    for (var i = 0; i < toMove; i++) {
      b.lines[y + i] = b.lines.swap(y + i + count, BufferLine(viewWidth));
    }
    for (var i = 0; i < count; i++) {
      b.lines[bottom - i] = BufferLine(viewWidth);
    }
  }
}
