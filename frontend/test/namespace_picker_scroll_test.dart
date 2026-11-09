import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/widgets/namespace_picker.dart';

import 'support/table_fakes.dart';

void main() {
  testWidgets('scrolling a long namespace list under the mouse rebuilds only a few rows per step', (tester) async {
    final app = await pumpTable(tester, TableFakeApi(), podType);
    app.namespaces = [for (var i = 0; i < 400; i++) 'ns-${i.toString().padLeft(3, '0')}'];
    app.favouriteNamespaces = ['ns-007', 'ns-120', 'ns-300'];
    app.setNamespaceScope(NamespaceScope.of(['ns-010', 'ns-200', 'ns-350']));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('namespace-picker')));
    await tester.pump();

    final list = find.byType(ListView);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: tester.getCenter(list));
    await tester.pump();

    debugRowBuilds = 0;
    const steps = 20;
    for (var i = 0; i < steps; i++) {
      // A wheel tick of one row; the mouse stays put, so the hovered row changes.
      await tester.sendEventToBinding(PointerScrollEvent(position: tester.getCenter(list), scrollDelta: const Offset(0, 26)));
      await tester.pump();
      await mouse.moveBy(const Offset(0, 1));
      await tester.pump();
    }
    // Rows scrolling into view build once and hover rebuilds two; never the whole list.
    expect(debugRowBuilds / steps, lessThan(8), reason: '${debugRowBuilds / steps} row builds per step');
    // ignore: avoid_print
    print('row builds per step: ${debugRowBuilds / steps}');
  });
}
