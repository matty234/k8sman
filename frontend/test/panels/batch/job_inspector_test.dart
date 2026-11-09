import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/panels/batch/batch_common.dart';
import 'package:k8sman/ui/inspector/inspector.dart';

import '../../support/harness.dart';
import '../../support/screenshot.dart';
import 'batch_panels_test.dart' show failedJob, failedPods;

void main() {
  setUp(() {
    batchNow = () => DateTime.utc(2026, 11, 3, 11, 33);
    SectionMemory.reset();
  });
  tearDown(() => batchNow = DateTime.now);

  testWidgets('failed Job: status header first, failed pods open, the rest collapsed behind summaries, clean at 320', (tester) async {
    await loadRealFonts();
    final api = FakeApiClient(itemsByResource: {'pods': failedPods()}, itemsFilter: labelSelectorFilter);
    for (final width in [560.0, 320.0]) {
      await pumpPanel(tester, failedJob(), api: api, size: Size(width, 1600));
      expect(tester.takeException(), isNull, reason: 'overflow at $width');

      expect(find.byKey(const ValueKey('inspector-headline')), findsOneWidget);
      expect(find.text('Failed: BackoffLimitExceeded'), findsOneWidget);
      for (final label in ['succeeded', 'failed', 'active', 'took']) {
        expect(find.byKey(ValueKey('figure-$label')), findsOneWidget, reason: label);
      }
      expect(find.text('Too many failed attempts (BackoffLimitExceeded)'), findsOneWidget);
      // Failed attempts start open.
      expect(find.textContaining('exit 137', findRichText: true), findsOneWidget);
      // Secondary sections are collapsed behind one-line summaries.
      expect(find.text('completions 1 · parallelism 1 · backoff 2 · deadline 30m · TTL 2h'), findsOneWidget);
      expect(find.text('importer:2.4.1 · restart Never'), findsOneWidget);
      expect(find.text('FailureTarget, Failed'), findsOneWidget);
      expect(find.text('FailJob when exit code in [42] (container import)'), findsNothing);
    }
  });
}
