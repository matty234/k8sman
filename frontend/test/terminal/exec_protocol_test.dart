import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/terminal/exec_protocol.dart';
import 'package:k8sman/ui/terminal/open_terminal.dart';
import 'package:k8sman/ui/terminal/terminal_session.dart';

Map<String, dynamic> fixture(String name) => jsonDecode(File('../dev/fixtures/$name.json').readAsStringSync()) as Map<String, dynamic>;

void main() {
  group('ExecFrames', () {

    test('decodes binary output and control frames', () {
      final out = ExecFrames.decode(Uint8List.fromList([104, 105]));
      expect(out, isA<ExecOutput>().having((o) => o.bytes, 'bytes', [104, 105]));
      expect(ExecFrames.decode(<int>[1, 2]), isA<ExecOutput>());
      expect(ExecFrames.decode('{"type":"started","container":"nginx","command":["/bin/sh","-c","x"]}'),
          isA<ExecStarted>().having((e) => e.container, 'container', 'nginx').having((e) => e.command.length, 'argc', 3));
      expect(ExecFrames.decode('{"type":"exit","code":3}'), isA<ExecExit>().having((e) => e.code, 'code', 3));
      final err = ExecFrames.decode('{"type":"error","reason":"noShell","message":"no /bin/sh","code":127}');
      expect(err, isA<ExecError>().having((e) => e.reason, 'reason', ExecReason.noShell).having((e) => e.code, 'code', 127));
      expect(ExecFrames.decode('{"type":"mystery"}'), isNull);
      expect(ExecFrames.decode('not json'), isNull);
    });
  });

  group('ExecRequest', () {
    test('auto shell query', () {
      final q = const ExecRequest(namespace: 'demo', pod: 'p', container: 'c', cols: 80, rows: 24).toQuery();
      expect(q, {'namespace': 'demo', 'pod': 'p', 'container': 'c', 'shell': 'auto', 'cols': '80', 'rows': '24'});
    });

    test('explicit command is JSON-encoded and drops shell', () {
      final q = const ExecRequest(namespace: 'demo', pod: 'p', command: ['redis-cli', '-n', '1']).toQuery();
      expect(q['command'], '["redis-cli","-n","1"]');
      expect(q.containsKey('shell'), isFalse);
      expect(q.containsKey('container'), isFalse);
    });

  });

  test('splitCommandLine handles quotes and escapes', () {
    expect(splitCommandLine('/bin/bash -l'), ['/bin/bash', '-l']);
    expect(splitCommandLine(r'''sh -c 'echo "hi there"' a\ b'''), ['sh', '-c', 'echo "hi there"', 'a b']);
    expect(splitCommandLine('  '), isEmpty);
    expect(splitCommandLine('redis-cli ""'), ['redis-cli', '']);
    expect(splitCommandLine(shellJoinArgs(['sh', '-c', "it's ok"])), ['sh', '-c', "it's ok"]);
  });

  group('container / pod choice', () {
    test('default terminal container is the first running regular one', () {
      final pod = fixture('pod-web');
      final cs = terminalContainers(pod);
      expect(cs, isNotEmpty);
      expect(defaultTerminalContainer(pod), cs.first.name);
      expect(cs.every((c) => c.isRunning), isTrue);
    });

    test('pickReadyPod prefers ready, running pods', () {
      Map<String, dynamic> pod(String name, String phase, {bool ready = false}) => {
            'metadata': {'name': name},
            'status': {
              'phase': phase,
              'conditions': [
                {'type': 'Ready', 'status': ready ? 'True' : 'False'},
              ],
            },
          };
      expect(pickReadyPod([pod('a', 'Pending'), pod('b', 'Running'), pod('c', 'Running', ready: true)])?['metadata']['name'], 'c');
      expect(pickReadyPod([pod('a', 'Pending'), pod('b', 'Running')])?['metadata']['name'], 'b');
      expect(pickReadyPod([pod('a', 'Failed')]), isNull);
    });
  });
}
