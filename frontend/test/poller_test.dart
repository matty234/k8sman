import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/state/poller.dart';

/// A page that polls every 10s through [PollingState].
class _Page extends StatefulWidget {
  final Future<bool> Function() onTick;
  const _Page(this.onTick);
  @override
  State<_Page> createState() => _PageState();
}

class _PageState extends State<_Page> with PollingState {
  late final Poll p;
  @override
  void initState() {
    super.initState();
    p = poll(const Duration(seconds: 10), widget.onTick);
  }

  @override
  Widget build(BuildContext context) => const SizedBox();
}

void main() {
  Future<_PageState> pumpPage(WidgetTester tester, Future<bool> Function() onTick, ValueNotifier<bool> visible) async {
    await tester.pumpWidget(ValueListenableBuilder<bool>(
      valueListenable: visible,
      builder: (_, v, _) => TickerMode(enabled: v, child: _Page(onTick)),
    ));
    return tester.state<_PageState>(find.byType(_Page));
  }

  testWidgets('ticks every interval while visible; no timer after dispose', (tester) async {
    var n = 0;
    await pumpPage(tester, () async => (n++, true).$2, ValueNotifier(true));
    expect(PollScheduler.instance.armedCount, 1);
    await tester.pump(const Duration(seconds: 9));
    expect(n, 0);
    await tester.pump(const Duration(seconds: 1));
    expect(n, 1);
    await tester.pump(const Duration(seconds: 30));
    expect(n, 4);
    await tester.pumpWidget(const SizedBox());
    expect(PollScheduler.instance.pollCount, 0);
    expect(PollScheduler.instance.armedCount, 0);
  });

  testWidgets('pauses while TickerMode is off and refreshes on becoming visible', (tester) async {
    var n = 0;
    final visible = ValueNotifier(true);
    final page = await pumpPage(tester, () async => (n++, true).$2, visible);
    visible.value = false;
    await tester.pump();
    expect(page.p.armed, isFalse);
    await tester.pump(const Duration(minutes: 5));
    expect(n, 0);
    visible.value = true;
    await tester.pump();
    expect(n, 1, reason: 'immediate refresh when shown again');
    expect(page.p.armed, isTrue);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('backs off exponentially on failure and resets on success', (tester) async {
    var n = 0;
    var fail = true;
    final page = await pumpPage(tester, () async {
      n++;
      if (fail) throw StateError('down');
      return true;
    }, ValueNotifier(true));
    await tester.pump(const Duration(seconds: 10)); // 1st failure
    expect(n, 1);
    expect(page.p.nextDelay, const Duration(seconds: 20));
    await tester.pump(const Duration(seconds: 19));
    expect(n, 1);
    await tester.pump(const Duration(seconds: 1)); // 2nd failure
    expect(n, 2);
    expect(page.p.nextDelay, const Duration(seconds: 40));
    for (var i = 0; i < 6; i++) {
      await tester.pump(page.p.nextDelay);
    }
    expect(page.p.nextDelay, const Duration(seconds: 80), reason: 'capped at 8x the interval');
    fail = false;
    await tester.pump(page.p.nextDelay);
    expect(page.p.failures, 0);
    expect(page.p.nextDelay, const Duration(seconds: 10));
    await tester.pumpWidget(const SizedBox());
  });

}
