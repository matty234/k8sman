import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/state/app_state.dart';

import 'support/fixture_api.dart';

void main() {
  testWidgets('back and forward walk page, table and inspector; the mouse side buttons too', (tester) async {
    final (app, _) = await pumpShell(tester, FixtureApi());
    app.showView(MainView.nodes);
    await tester.pump();
    app.showView(MainView.resources);
    await tester.pump(const Duration(milliseconds: 50));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('web-6fd47b8fcb-4v4m9').first);
    await tester.pump(const Duration(milliseconds: 50));
    expect(app.detail, isNotNull);

    app.navBack();
    await tester.pump();
    expect(app.detail, isNull);
    expect(app.view, MainView.resources);
    app.navBack();
    await tester.pump();
    expect(app.view, MainView.nodes);
    app.navBack();
    await tester.pump();
    expect(app.view, MainView.resources);
    expect(app.canNavBack, isFalse);

    app.navForward();
    await tester.pump();
    expect(app.view, MainView.nodes);

    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.down(const Offset(400, 300), buttons: kForwardMouseButton));
    await tester.pump();
    expect(app.view, MainView.resources);
    await tester.sendEventToBinding(mouse.up());
    await tester.sendEventToBinding(mouse.down(const Offset(400, 300), buttons: kBackMouseButton));
    await tester.pump();
    expect(app.view, MainView.nodes);
  });
}
