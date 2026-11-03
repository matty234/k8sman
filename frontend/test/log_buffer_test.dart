import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/log_buffer.dart';
import 'package:k8sman/state/log_dock.dart';

import 'support/harness.dart';

class _Api extends FakeApiClient {
  final c = StreamController<LogMessage>();
  @override
  Stream<LogMessage> logs({
    required String namespace,
    required String pod,
    String? container,
    int tailLines = 500,
    bool previous = false,
    bool follow = true,
    bool timestamps = false,
    int? sinceSeconds,
  }) =>
      c.stream;
}

Json _pod() => {
      'metadata': {'name': 'web', 'namespace': 'demo'},
      'spec': {
        'containers': [
          {'name': 'app'},
        ],
      },
      'status': {
        'containerStatuses': [
          {
            'name': 'app',
            'state': {
              'running': {'startedAt': '2026-11-03T10:00:00Z'},
            },
          },
        ],
      },
    };

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

  test('LogStream caps lines and keeps search matches across evictions', () async {
    final api = _Api();
    final s = LogStream(api: api, namespace: 'demo', pod: 'web', container: 'app', podObject: _pod());
    s.setQuery('ERR');
    for (var i = 0; i < kMaxLogLines + 500; i++) {
      api.c.add(LogMessage(line: i % 100 == 0 ? 'error $i\n' : 'ok $i\n'));
    }
    // Flushes run on a 50 ms timer.
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(s.lines.length, kMaxLogLines);
    expect(s.dropped, 500);
    expect(s.lines.first, 'error 500');
    expect(s.matching.length, kMaxLogLines ~/ 100);
    expect(s.lines[s.matching.first], 'error 500');

    // New lines extend the matches incrementally; old ones fall off.
    for (var i = 0; i < 150; i++) {
      api.c.add(LogMessage(line: i == 149 ? 'ERROR late' : 'ok late $i'));
    }
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(s.lines[s.matching.first], 'error 700', reason: 'error 600 was evicted');
    expect(s.lines[s.matching.last], 'ERROR late');
    expect(s.matching.length, kMaxLogLines ~/ 100 - 2 + 1);

    s.setQuery('late 1');
    expect(s.matching.map((i) => s.lines[i]), [for (var i = 0; i < 149; i++) 'ok late $i'].where((l) => l.contains('late 1')));
    s.clear();
    expect(s.matching, isEmpty);
    s.dispose();
  });
}
