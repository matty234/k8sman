import 'package:xterm/xterm.dart';

/// Works around package:xterm 4.0 reporting the mouse wheel as button
/// 68/69 (`64 + 4`, `64 + 5`) instead of 64/65. The extra 4 is the Shift
/// bit, so apps that track the mouse (Claude Code's fullscreen TUI, vim,
/// htop) saw Shift+wheel and didn't scroll. Wheel events are reported
/// here; everything else goes to xterm's own handler.
class WheelFixMouseHandler implements TerminalMouseHandler {
  const WheelFixMouseHandler();

  @override
  String? call(TerminalMouseEvent event) {
    final b = event.button;
    if (!b.isWheel) return defaultMouseHandler(event);
    final mode = event.state.mouseMode;
    // Wheel needs a tracking mode beyond click-only (1000/1002/1003), and
    // has no release event.
    if (mode == MouseMode.none || mode == MouseMode.clickOnly || event.buttonState == TerminalMouseButtonState.up) return null;
    final id = 64 + switch (b) {
      TerminalMouseButton.wheelUp => 0,
      TerminalMouseButton.wheelDown => 1,
      TerminalMouseButton.wheelLeft => 2,
      _ => 3,
    };
    final x = event.position.x + 1, y = event.position.y + 1;
    switch (event.state.mouseReportMode) {
      case MouseReportMode.sgr:
        return '\x1b[<$id;$x;${y}M';
      case MouseReportMode.urxvt:
        return '\x1b[${32 + id};$x;${y}M';
      case MouseReportMode.normal:
      case MouseReportMode.utf:
        final limit = event.state.mouseReportMode == MouseReportMode.normal ? 223 : 2015;
        String pos(int v) => v > limit ? '\x00' : String.fromCharCode(32 + v);
        return '\x1b[M${String.fromCharCode(32 + id)}${pos(x)}${pos(y)}';
    }
  }
}
