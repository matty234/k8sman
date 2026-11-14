import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/terminal/mouse_fix.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('the wheel is reported as button 64/65, not Shift+wheel', () {
    final out = <String>[];
    final t = Terminal(mouseHandler: const WheelFixMouseHandler())..onOutput = out.add;
    t.write('\x1b[?1002h\x1b[?1006h'); // what Claude Code's fullscreen TUI asks for
    t.mouseInput(TerminalMouseButton.wheelUp, TerminalMouseButtonState.down, const CellOffset(4, 2));
    t.mouseInput(TerminalMouseButton.wheelDown, TerminalMouseButtonState.down, const CellOffset(4, 2));
    expect(out, ['\x1b[<64;5;3M', '\x1b[<65;5;3M']);
  });
}
