
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/metrics/volume_usage.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/util/k8s.dart';


void main() {
  testWidgets('usage bar states: thresholds, not mounted, not bound', (tester) async {
    Future<void> pump(PvcUsageState s) => tester.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: SizedBox(width: 520, child: PvcUsageView(s))),
        ));
    Color? colorOf(String text) => tester.widget<Text>(find.text(text)).style?.color;
    late BuildContext ctx;

    await pump(const PvcUsageKnown(PvcUsage(used: 50, capacity: 100, source: UsageSource.prometheus, daysToFull: 3.4)));
    ctx = tester.element(find.byType(PvcUsageView));
    expect(find.text('50%'), findsOneWidget);
    expect(colorOf('50%'), isNot(severityColor(ctx, Severity.warn)));
    expect(find.textContaining('full in ~3 days'), findsOneWidget);
    expect(find.textContaining('via Prometheus'), findsOneWidget);

    await pump(const PvcUsageKnown(PvcUsage(used: 82, capacity: 100, source: UsageSource.kubelet)));
    expect(colorOf('82%'), severityColor(ctx, Severity.warn));

    await pump(const PvcUsageKnown(PvcUsage(used: 95, capacity: 100, source: UsageSource.kubelet)));
    expect(colorOf('95%'), severityColor(ctx, Severity.error));

    await pump(const PvcUsageNotMounted());
    expect(find.textContaining('Not mounted, usage unknown'), findsOneWidget);

    await pump(const PvcUsageNotMounted(bound: false));
    expect(find.textContaining('Not bound, usage unknown'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

}
