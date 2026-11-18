import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/util/ansi.dart';

void main() {
  test('parseAnsi strips escapes and keeps colour runs (pino-pretty line)', () {
    const raw = '[19:21:53] \x1b[32mINFO\x1b[39m: \x1b[36mvariant index built\x1b[39m    \x1b[35mvariants\x1b[39m: 21368 \x1b[1;38;5;196mX\x1b[0m\x1b]8;;http://x\x07';
    final (text, runs) = parseAnsi(raw);
    expect(text, '[19:21:53] INFO: variant index built    variants: 21368 X');
    String at(int fg) => [for (final (a, e, s) in runs) if (s.fg == fg) text.substring(a, e)].join('|');
    expect(at(2), 'INFO');
    expect(at(6), 'variant index built');
    expect(at(5), 'variants');
    final x = runs.last;
    expect((text.substring(x.$1, x.$2), x.$3.fg, x.$3.bold), ('X', 196, true));
  });
}
