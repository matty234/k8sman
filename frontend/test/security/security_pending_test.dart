import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';

import '../support/screenshot.dart';
import 'security_test.dart' show fixture, pumpSecurity;

/// The live fixture as the backend answers before RBAC and the image
/// reports have been listed: those categories are pending, with no
/// findings, grants or images.
Json pendingResponse() {
  const pending = ['rbac', 'images'];
  final j = fixture('security');
  j['pending'] = pending;
  j['findings'] = [for (final f in j['findings'] as List) if (!pending.contains((f as Map)['category'])) f];
  j['permissive'] = [];
  j['images'] = [];
  j['topCVEs'] = [];
  for (final c in j['categories'] as List) {
    if (pending.contains((c as Map)['id'])) {
      c['total'] = 0;
      c['counts'] = {};
    }
  }
  return j;
}

void main() {
  testWidgets('pending categories show placeholders, then fill in on the quick re-fetch', (tester) async {
    await loadRealFonts();
    final (_, source) = await pumpSecurity(tester, pendingResponse(), size: const Size(1000, 1500));

    // The score waits; pending tiles and sections hold their place, never "0 findings".
    expect(find.byKey(const ValueKey('pending-stat-score')), findsOneWidget);
    for (final id in ['rbac', 'images']) {
      final tile = find.byKey(ValueKey('pending-category-$id'));
      expect(tile, findsOneWidget, reason: id);
      expect(find.descendant(of: tile, matching: find.text('0')), findsNothing);
      expect(find.byKey(ValueKey('pending-findings-$id')), findsOneWidget);
      expect(find.byKey(ValueKey('pending-section-$id')), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('pending-category-network')), findsNothing);
    expect(find.text('Network exposure by namespace'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await saveScreenshot(tester, 'security-pending');

    // The backend has finished: the next quick fetch (0.7s) fills everything in.
    source.response = fixture('security');
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pump();
    expect(source.calls, hasLength(2));
    expect(find.byKey(const ValueKey('pending-stat-score')), findsNothing);
    expect(find.byKey(const ValueKey('pending-category-rbac')), findsNothing);
    expect(find.byKey(const ValueKey('pending-section-images')), findsNothing);
    expect(find.text('34 / 100', findRichText: true), findsOneWidget); // the score
    expect(find.text('security-demo-overprivileged'), findsOneWidget);

    // Nothing pending: no more quick fetches.
    await tester.pump(const Duration(seconds: 5));
    expect(source.calls, hasLength(2));
  });
}
