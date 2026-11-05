import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/terminal/sgr_filter.dart';
import 'package:xterm/xterm.dart';

void main() {
  test('output xterm.dart misreads is rewritten: modifyOtherKeys, bold reset, DCS strings (split across chunks)', () {
    final f = SgrFilter();
    final t = Terminal();
    for (final chunk in ['\x1b[>4;2m\x1b[1mbold\x1b[2', '2mplain\x1bP+q54', '4e\x1b\\!']) {
      t.write(f.process(chunk));
    }
    final line = t.buffer.lines[0];
    expect(line.toString().trimRight(), 'boldplain!', reason: 'no leaked DCS text');
    expect(line.getAttributes(0) & CellAttr.bold, isNot(0));
    expect(line.getAttributes(4) & CellAttr.bold, 0, reason: '22 ends bold');
    expect(line.getAttributes(4) & CellAttr.underline, 0, reason: 'CSI > 4;2 m is not underline');
  });
}
