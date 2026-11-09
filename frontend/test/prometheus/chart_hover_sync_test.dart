import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/prometheus/metric_history_chart.dart';
import 'package:k8sman/prometheus/prom_api.dart';
import 'package:k8sman/ui/theme.dart';

void main() {
  testWidgets('hovering one chart shows the same time on the others', (tester) async {
    final t0 = DateTime(2026, 11, 9, 12);
    MetricSeries s(double k) => MetricSeries(const {}, [for (var i = 0; i <= 60; i++) (t0.add(Duration(minutes: i)), k * (i + 1))]);
    Widget chart(Key key, String name, double k) =>
        SizedBox(width: 400, child: AreaChart(key: key, series: [s(k)], unit: MetricUnit.plain, range: const Duration(hours: 1), seriesName: name));
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: ChartHoverScope(
          child: Column(children: [chart(const ValueKey('cpu'), 'cpu', 1), const SizedBox(height: 40), chart(const ValueKey('mem'), 'mem', 2)]),
        ),
      ),
    ));
    expect(find.text('mem'), findsNothing);
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset.zero);
    await g.moveTo(tester.getCenter(find.byKey(const ValueKey('cpu'))));
    await tester.pump();
    // Both readouts show: the hovered chart's and the follower's.
    expect(find.text('cpu'), findsOneWidget);
    expect(find.text('mem'), findsOneWidget);
    await g.moveTo(const Offset(5, 590));
    await tester.pump();
    expect(find.text('mem'), findsNothing);
  });
}
