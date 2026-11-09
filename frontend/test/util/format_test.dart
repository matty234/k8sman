import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/util/format.dart';

void main() {
  test('duration and cpu styles keep their distinct outputs', () {
    const d = Duration(hours: 2, minutes: 5, seconds: 3);
    expect(formatDuration(d), '2h5m');
    expect(formatDuration(d, style: DurationStyle.padded), '2h05m');
    expect(formatDuration(const Duration(minutes: 10), style: DurationStyle.trimmed), '10m');
    expect(formatDuration(const Duration(minutes: 10)), '10m0s');
    expect(formatCpu(1500), '1.50');
    expect(formatCpu(1500, style: CpuStyle.cores), '1.5');
    expect(formatCpu(0.4, style: CpuStyle.usage), '<1m');
  });
}
