import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/ui/widgets/editorial.dart';
import 'package:k8sman/util/k8s.dart';

void main() {
  testWidgets('editorial primitives fit from 200 to 1400px; stat and title clicks reach their targets', (tester) async {
    var opened = 0, titled = 0;
    Widget page() => MaterialApp(
          theme: buildTheme(Brightness.dark),
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                StatusLine(mark: const StatusMark(severity: Severity.warn), headline: 'Needs attention', detail: const Text('3 warnings across 2 areas'), note: '7 workloads healthy'),
                StatStrip(items: [
                  StatItem('pods ready', '3', of: '/ 5', tone: Severity.warn, frac: 0.6, onTap: () => opened++),
                  const StatItem('nodes ready', '2'),
                  const StatItem('loading', null),
                ]),
                EditorialSection(
                  title: 'A rather long section title that has to give way',
                  trailing: const Text('12 problems'),
                  child: AttentionList(groups: [
                    AttentionGroup(
                      icon: Icons.layers_outlined,
                      title: 'Workloads',
                      count: 3,
                      onTitleTap: () => titled++,
                      titleKey: const ValueKey('title'),
                      rows: const AttentionRow(severity: Severity.warn, count: '3', label: 'Unavailable', detail: '3 deployments'),
                    ),
                  ]),
                ),
                SizedBox(height: 26, child: TitleRule(title: const Text('Granted by'), trailing: const Text('7'))),
                const HairlineCell(accent: Colors.red, child: BigFigure('29%', 'in use', suffix: '1.8 cores')),
              ]),
            ),
          ),
        );
    for (final w in [200.0, 320.0, 700.0, 1400.0]) {
      tester.view.physicalSize = Size(w, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(page());
      expect(tester.takeException(), isNull, reason: 'overflow at $w');
    }
    expect(find.byKey(const ValueKey('pending-stat-loading')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('stat-pods ready')));
    await tester.tap(find.byKey(const ValueKey('title')));
    expect((opened, titled), (1, 1));
  });
}
