import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/reconnecting_watch.dart';

void main() {
  testWidgets('reconnects with growing backoff, and starts over after a good frame', (tester) async {
    var opens = 0;
    late StreamController<WatchMessage> c;
    late ReconnectingWatch w;
    w = ReconnectingWatch(
      open: () {
        opens++;
        c = StreamController<WatchMessage>();
        return c.stream;
      },
      onFrame: (_) => w.resetBackoff(),
    )..start();
    expect(opens, 1);
    c.close(); // attempt 0: 250-500 ms
    await tester.pump(const Duration(milliseconds: 500));
    expect(opens, 2);
    c.close(); // attempt 1: 500-1000 ms
    await tester.pump(const Duration(milliseconds: 400));
    expect(opens, 2);
    await tester.pump(const Duration(milliseconds: 600));
    expect(opens, 3);
    c.add(const WatchMessage(type: 'SNAPSHOT'));
    await tester.pump();
    c.close(); // back to attempt 0
    await tester.pump(const Duration(milliseconds: 500));
    expect(opens, 4);
    w.stop();
  });
}
