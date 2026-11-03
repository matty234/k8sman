import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/detail/detail_sidebar.dart';
import 'package:k8sman/ui/theme.dart';

class _Counter extends StatefulWidget {
  final String label;
  const _Counter(this.label);
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int n = 0;
  @override
  Widget build(BuildContext context) => TextButton(onPressed: () => setState(() => n++), child: Text('${widget.label} $n'));
}

void main() {
  testWidgets('tabs switch instantly, build lazily and keep state', (tester) async {
    var builtB = false;
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: DefaultTabController(
        length: 2,
        animationDuration: Duration.zero,
        child: Scaffold(
          body: Column(children: [
            const TabBar(isScrollable: true, tabs: [Tab(text: 'A'), Tab(text: 'B')]),
            Expanded(
              child: InstantTabView(children: [
                const _Counter('a'),
                Builder(builder: (_) {
                  builtB = true;
                  return const _Counter('b');
                }),
              ]),
            ),
          ]),
        ),
      ),
    ));
    expect(builtB, isFalse, reason: 'unvisited tab is not built');
    await tester.tap(find.text('a 0'));
    await tester.pump();
    expect(find.text('a 1'), findsOneWidget);

    await tester.tap(find.text('B'));
    await tester.pump(); // a single frame: no slide animation to wait for
    expect(builtB, isTrue);
    expect(find.text('b 0'), findsOneWidget);
    expect(find.byType(PageView), findsNothing, reason: 'no sliding page view');
    expect(tester.hasRunningAnimations, isFalse);

    await tester.tap(find.text('A'));
    await tester.pump();
    expect(find.text('a 1'), findsOneWidget, reason: 'state kept across switches');
  });
}
