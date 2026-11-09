import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/inspector/inspector.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';
import 'samples.dart';

void main() {
  setUp(SectionMemory.reset);

  testWidgets('ConfigMap: header counts and usage, compact key rows, binary data collapsed, clean at 320', (tester) async {
    await loadRealFonts();
    final api = FakeApiClient(itemsByResource: {'pods': [richPod]});
    for (final width in [560.0, 320.0]) {
      await pumpPanel(tester, richConfigMap, api: api, size: Size(width, 1600));
      expect(tester.takeException(), isNull, reason: 'overflow at $width');

      // Header: keys, size, who uses it, immutable, the missing key.
      for (final label in ['keys', 'size', 'pod uses it', 'workloads']) {
        expect(find.byKey(ValueKey('figure-$label')), findsOneWidget, reason: label);
      }
      expect(find.text('7'), findsOneWidget); // 6 data keys + 1 binary
      expect(find.text('immutable'), findsOneWidget);
      expect(find.textContaining('Key FEATURE_X is referenced but missing'), findsOneWidget);
      // Keys are rows (values on demand); binary data is collapsed.
      expect(find.text('settings.json'), findsOneWidget);
      expect(find.textContaining('"port": 8080'), findsNothing);
      expect(find.text('1 key · 16 B'), findsOneWidget);
      expect(find.text('logo.png'), findsNothing);
    }
  });
}
