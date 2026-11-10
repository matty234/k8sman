import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/logs/log_syntax.dart';

void main() {
  test('tokenizeLog types JSON and logfmt lines and rejects plain text', () {
    const j = '{"level":"error","msg":"boom","n":3,"ok":true}';
    final jt = tokenizeLog(j)!;
    String of(String s, LogTokKind k) => jt.where((t) => t.kind == k).map((t) => s.substring(t.start, t.end)).join('|');
    expect(of(j, LogTokKind.level), '"error"');
    expect(of(j, LogTokKind.message), '"boom"');
    expect(of(j, LogTokKind.number), '3');
    expect(of(j, LogTokKind.keyword), 'true');
    expect(tokenizeLog('{"a":1'), isNull);

    const f = 'I1110 12:00:00.000 1 main.go:42] level=warn msg="a \\"b\\" c" count=2';
    final ft = tokenizeLog(f)!;
    expect(ft.first.kind, LogTokKind.plain);
    expect(ft.where((t) => t.kind == LogTokKind.message).map((t) => f.substring(t.start, t.end)).single, 'a \\"b\\" c');
    expect(ft.where((t) => t.kind == LogTokKind.level).length, 1);
    expect(ft.last.end, f.length);

    expect(tokenizeLog('starting server on port 8080'), isNull);
    expect(tokenizeLog('only a=b here'), isNull);
  });
}
