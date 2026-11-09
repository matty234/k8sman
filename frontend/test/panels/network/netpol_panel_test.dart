import 'package:flutter_test/flutter_test.dart';

import '../../support/harness.dart';
import 'net_support.dart';

void main() {
  testWidgets('netpol: explanation and selected pods', (tester) async {
    final app = await pumpPanel(tester, devFixture('netpol-web-allow-frontend'),
        api: FakeApiClient(itemsByResource: {'pods': demoPods()}, itemsFilter: labelSelectorFilter));
    expect(find.text('Applies to pods matching app=web in demo (2 pods).'), findsOneWidget);
    expect(find.text('Restricts ingress'), findsOneWidget);
    expect(find.text('Restricted · 2 allowed'), findsOneWidget);
    expect(find.text('Not restricted'), findsOneWidget);
    expect(find.text('from pods with tier=frontend in this namespace on TCP 8080'), findsOneWidget);
    await tester.tap(find.text('web-6fd47b8fcb-4v4m9'));
    expect(app.detail?.type.kind, 'Pod');
  });

}
