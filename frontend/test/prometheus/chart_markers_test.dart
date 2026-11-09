import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/prometheus/metric_history_chart.dart';
import 'package:k8sman/prometheus/prom_api.dart';
import 'package:k8sman/ui/theme.dart';

import '../support/screenshot.dart';

void main() {
  testWidgets('event markers replace the value readout while hovered, and cluster', (tester) async {
    await loadRealFonts();
    tester.view.physicalSize = const Size(560, 190);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final t0 = DateTime(2026, 11, 9, 12);
    final series = MetricSeries(const {}, [for (var i = 0; i <= 60; i++) (t0.add(Duration(minutes: i)), 0.2 + 0.15 * (i % 9) / 9 + (i > 40 ? 0.3 : 0))]);
    ChartMarker m(int min, String title, ChartSeverity s, {int count = 1, List<String> details = const []}) =>
        ChartMarker(time: t0.add(Duration(minutes: min)), title: title, severity: s, count: count, details: details);
    await tester.pumpWidget(MaterialApp(
      theme: buildTheme(Brightness.dark),
      home: Scaffold(
        body: Padding(
          padding: const EdgeInsets.all(40),
          child: SizedBox(
            width: 400,
            child: AreaChart(
              series: [series],
              unit: MetricUnit.cores,
              range: const Duration(hours: 1),
              seriesName: 'cpu',
              markers: [
                m(10, 'Started', ChartSeverity.info, details: ['container web']),
                m(30, 'BackOff', ChartSeverity.error, count: 5, details: ['Back-off restarting failed container web in pod web-0']),
                m(30, 'Unhealthy', ChartSeverity.warn),
                m(50, 'OOMKilled', ChartSeverity.error, details: ['container web', 'exit code 137']),
              ],
            ),
          ),
        ),
      ),
    ));
    final box = tester.getTopLeft(find.byType(AreaChart));
    final y = box.dy + 76 + 6; // inside the marker band
    final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await g.addPointer(location: Offset(box.dx + 100, box.dy + 30));
    await g.moveTo(Offset(box.dx + 100, box.dy + 30));
    await tester.pump();
    expect(find.text('cpu'), findsOneWidget); // value readout

    // Over a lone marker: its tooltip, no readout.
    await g.moveTo(Offset(box.dx + 10 / 60 * 400 + 3, y));
    await tester.pump();
    expect(find.text('Started'), findsOneWidget);
    expect(find.text('container web'), findsOneWidget);
    expect(find.text('cpu'), findsNothing);

    // Two markers at one time cluster: the tooltip lists both.
    await g.moveTo(Offset(box.dx + 200, y));
    await tester.pump();
    expect(find.textContaining('BackOff'), findsOneWidget);
    expect(find.textContaining('Unhealthy'), findsOneWidget);

    // Away from the marker band the readout is back.
    await g.moveTo(Offset(box.dx + 150, box.dy + 30));
    await tester.pump();
    expect(find.text('Started'), findsNothing);
    expect(find.text('cpu'), findsOneWidget);
    await g.removePointer();
  });
}
