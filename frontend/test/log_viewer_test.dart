import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/log_dock.dart';
import 'package:k8sman/ui/logs/log_stream_view.dart';

import 'support/harness.dart';

Json _pod() => jsonDecode(File('../dev/fixtures/pod-web.json').readAsStringSync()) as Json;

/// Records log requests and hands out live streams the test feeds.
class _LogApi extends FakeApiClient {
  final requests = <String>[];
  final streams = <StreamController<LogMessage>>[];
  Json? pod;

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
  }) {
    requests.add('$container previous=$previous follow=$follow');
    final c = StreamController<LogMessage>();
    streams.add(c);
    return c.stream;
  }

  @override
  Future<Json> object(ResourceRef r, {String? namespace, required String name}) async => pod ?? super.object(r, namespace: namespace, name: name);

  void push(Iterable<String> lines) {
    for (final l in lines) {
      streams.last.add(LogMessage(line: l));
    }
  }
}

void main() {
  testWidgets('scrolling up pauses following; evicted lines and new lines leave the view still', (tester) async {
    final api = _LogApi();
    final dock = await pumpLogDock(tester, _pod(), api: api, container: 'nginx');
    final s = dock.active!;
    var n = 0;
    Future<void> add(int count) async {
      api.push([for (var i = 0; i < count; i++) 'line ${n++}']);
      await tester.pump(const Duration(milliseconds: 60));
      await tester.pump();
    }

    await add(300);
    final list = find.descendant(of: find.byType(LogStreamView), matching: find.byType(ListView));
    final scroll = tester.widget<ListView>(list).controller!;
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(tester.getCenter(list)));
    expect(scroll.offset, scroll.position.maxScrollExtent);

    // A small wheel nudge up is enough to stop following: new lines don't
    // drag the view back to the end.
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -10)));
    await tester.pump();
    final reading = scroll.offset;
    await add(20);
    expect(scroll.offset, reading);
    expect(scroll.position.maxScrollExtent, greaterThan(reading + 300));
    expect(find.text('Jump to latest'), findsOneWidget);

    // Back at the end (here via the button), following resumes; fill the
    // buffer past its capacity.
    await tester.tap(find.text('Jump to latest'));
    await tester.pump();
    await add(kMaxLogLines);
    expect(s.dropped, greaterThan(0));
    expect(scroll.offset, scroll.position.maxScrollExtent);

    // Scrolled up with the buffer full, evicting old lines must not slide
    // the rows on screen.
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -2000)));
    await tester.pump();
    final probe = s.lines[(scroll.offset / 17).ceil() + 3];
    final y = tester.getTopLeft(find.text(probe)).dy;
    await add(100);
    expect(s.dropped, greaterThan(100));
    expect(tester.getTopLeft(find.text(probe)).dy, y);

    // Scrolling back to the end resumes following.
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100000)));
    await tester.pump();
    await add(5);
    expect(scroll.offset, scroll.position.maxScrollExtent);
    expect(find.text('line ${n - 1}'), findsOneWidget);
    expect(find.text('Jump to latest'), findsNothing);
    dock.closeAll();
  });

  test('previous-instance logs: right container, no follow, errors shown, mode kept across switches', () async {
    final api = _LogApi();
    final dock = LogDock(api);
    final pod = _pod();
    final s = dock.open(pod, container: 'nginx');
    expect(api.requests.last, 'nginx previous=false follow=true');
    expect(s.canPrevious, isFalse);

    // The container crashes: the stream ends and the refreshed pod shows
    // the restart, enabling "Previous".
    final restarted = _pod();
    ((restarted['status'] as Map)['containerStatuses'] as List).firstWhere((c) => c['name'] == 'nginx')['restartCount'] = 1;
    api.pod = restarted;
    await api.streams.last.close();
    await pumpEventQueue();
    expect(s.canPrevious, isTrue);

    s.setOptions(previous: true);
    expect(api.requests.last, 'nginx previous=true follow=false');

    // Switching container keeps asking for the previous instance, and the
    // API's "not found" is shown rather than current logs.
    dock.switchContainer(s, 'log-sidecar');
    expect(api.requests.last, 'log-sidecar previous=true follow=false');
    api.streams.last.add(const LogMessage(error: 'previous terminated container "log-sidecar" in pod "web" not found'));
    await pumpEventQueue();
    expect(s.phase, LogPhase.error);
    expect(s.error, contains('not found'));
    expect(s.lines, isEmpty);

    dock.switchContainer(s, 'init-wait');
    expect(api.requests.last, 'init-wait previous=true follow=false');

    // "View logs" on the same container switches the tab back to the
    // current instance.
    dock.open(pod, container: 'init-wait');
    expect(api.requests.last, 'init-wait previous=false follow=true');
    expect(s.previous, isFalse);
    dock.dispose();
  });
}
