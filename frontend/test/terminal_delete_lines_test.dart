import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/terminal/xterm_fixes.dart';

// xterm 4.0's delete-lines left a line in two slots with a stale index, so
// selections in Claude Code tabs landed on the wrong row.
void main() {
  test('delete lines shifts rows up and keeps every line indexed', () {
    final t = FixedTerminal(maxLines: 200)..resize(40, 10);
    for (var i = 0; i < 30; i++) {
      t.write('row $i\r\n');
    }
    t.write('\x1b[3;1H\x1b[2M\x1b[3L\x1b[1;1H\x1b[4M');
    final ls = t.buffer.lines;
    for (var k = 0; k < ls.length; k++) {
      expect(ls[k].index, k, reason: 'line $k');
    }
    final screen = [for (var r = 0; r < 10; r++) ls[t.buffer.scrollBack + r].getText().trim()];
    expect(screen, ['', 'row 25', 'row 26', 'row 27', 'row 28', 'row 29', '', '', '', '']);
  });
}
