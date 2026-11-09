
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/state/log_buffer.dart';


void main() {
  test('LogBuffer keeps the newest lines in order and counts evictions', () {
    final b = LogBuffer(4);
    expect(b.append(['a', 'b', 'c']), 0);
    expect(b, ['a', 'b', 'c']);
    expect(b.append(['d', 'e', 'f']), 2);
    expect(b, ['c', 'd', 'e', 'f']);
    expect(b.first, 'c');
    expect(b.last, 'f');
    expect(b.join(','), 'c,d,e,f');
    expect(b.firstSeq, 2);
    expect(b.nextSeq, 6);
    expect(b.append(['g', 'h', 'i', 'j', 'k']), 5, reason: 'more than capacity at once');
    expect(b, ['h', 'i', 'j', 'k']);
    b.clear();
    expect(b, isEmpty);
    expect(b.firstSeq, 11);
    b.add('x');
    expect(b, ['x']);
    expect(() => b[1], throwsRangeError);
    expect(() => b[0] = 'y', throwsUnsupportedError);
  });

}
