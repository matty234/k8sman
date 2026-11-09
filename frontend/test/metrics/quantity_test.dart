import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/metrics/metrics_api.dart';
import 'package:k8sman/metrics/quantity.dart';
import 'package:k8sman/metrics/workload_usage.dart';
import 'package:k8sman/panels/cluster/logic.dart';
import 'package:k8sman/util/k8s.dart';


void main() {
  group('parseQuantity', () {
    test('suffixes', () {
      expect(parseQuantity('250m'), closeTo(0.25, 1e-12));
      expect(parseQuantity('3454908092n'), closeTo(3.454908092, 1e-9));
      expect(parseQuantity('15u'), closeTo(15e-6, 1e-15));
      expect(parseQuantity('2'), 2);
      expect(parseQuantity('1Ki'), 1024);
      expect(parseQuantity('128Mi'), 128 * 1024 * 1024);
      expect(parseQuantity('1k'), 1000);
      expect(parseQuantity('1.5G'), 1.5e9);
      expect(parseQuantity('1.5e3'), 1500);
      expect(parseQuantity('42%'), 42);
      expect(parseQuantity(7), 7);
    });
    test('rejects garbage', () {
      expect(parseQuantity(null), isNull);
      expect(parseQuantity(''), isNull);
      expect(parseQuantity('abc'), isNull);
      expect(parseQuantity('xMi'), isNull);
      expect(parseQuantity('—'), isNull);
    });
  });

  test('compareQuantities sorts by value, empties last', () {
    final cells = ['120m', null, '12m', '1', '2Gi', '900Mi', ''];
    final cpu = ['120m', '12m', '1']..sort(compareQuantities);
    expect(cpu, ['12m', '120m', '1']);
    final mem = ['2Gi', '900Mi']..sort(compareQuantities);
    expect(mem, ['900Mi', '2Gi']);
    final mixed = [...cells]..sort(compareQuantities);
    expect(mixed.take(5), ['12m', '120m', '1', '900Mi', '2Gi']);
    expect(mixed.skip(5).every((c) => c == null || c == ''), isTrue);
    expect((['9%', '70%', '100%']..sort(compareQuantities)), ['9%', '70%', '100%']);
  });

  test('fractions, percents and thresholds', () {
    expect(fraction(50, 200), 0.25);
    expect(fraction(1, 0), isNull);
    expect(fraction(null, 10), isNull);
    expect(formatPercent(0.4237), '42%');
    expect(formatPercent(0.004), '<1%');
    expect(formatPercent(0), '0%');
    expect(formatPercent(null), '—');
    expect(thresholdSeverity(0.69), Severity.neutral);
    expect(thresholdSeverity(0.70), Severity.warn);
    expect(thresholdSeverity(0.899), Severity.warn);
    expect(thresholdSeverity(0.90), Severity.error);
    expect(thresholdSeverity(1.4), Severity.error);
    expect(thresholdSeverity(null), Severity.neutral);
  });

  test('usage formatting', () {
    expect(formatCpuUsage(0.3), '<1m');
    expect(formatCpuUsage(0), '0m');
    expect(formatCpuUsage(850), '850m');
    expect(formatCpuUsage(3455), '3.46');
    expect(formatCpuUsage(12500), '12.5');
    expect(formatCpuUsage(null), '—');
  });



  test('WorkloadTotals sums only sampled pods', () {
    final rows = [
      PodUsageRow(const {}, const PodResources(cpuRequest: 100, memRequest: 1000), const Usage(30, 400)),
      PodUsageRow(const {}, const PodResources(cpuRequest: 100, memRequest: 1000), const Usage(50, 600)),
      PodUsageRow(const {}, const PodResources(cpuRequest: 100, memRequest: 1000), null),
    ];
    final t = WorkloadTotals.of(rows);
    expect(t.pods, 3);
    expect(t.sampled, 2);
    expect(t.used.cpuMillis, 80);
    expect(t.resources.cpuRequest, 200);
    expect(fraction(t.used.cpuMillis, t.resources.cpuRequest), 0.4);
  });

}
