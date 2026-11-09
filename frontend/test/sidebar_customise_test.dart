import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/modules/addons_module.dart';
import 'package:k8sman/modules/helm_module.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/resource_nav.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/harness.dart';

const _deploy = SidebarPin(group: 'apps', kind: 'Deployment');
const _podsKs = SidebarPin(group: '', kind: 'Pod', namespace: 'kube-system');

Future<(AppState, FakeApiClient)> _pumpNav(WidgetTester tester, {SidebarConfig? layout, double height = 1400, double width = 232}) async {
  final api = FakeApiClient();
  final app = AppState(api)..types = testTypes;
  if (layout != null) app.sidebar = layout;
  tester.view.physicalSize = Size(width, height);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: ResourceNav())),
  ));
  await tester.pump();
  return (app, api);
}

double _y(WidgetTester tester, String key) => tester.getTopLeft(find.byKey(ValueKey(key))).dy;

void main() {
  group('SidebarConfig', () {
    test('JSON round trip; normalises missing, unknown and duplicate entries', () {
      final c = SidebarConfig.defaults.setHidden(MainView.security, true).pin(_deploy).pin(_podsKs);
      final back = SidebarConfig.fromJson(c.toJson());
      expect(back.entries, c.entries);
      expect(back.isHidden(MainView.security), isTrue);
      expect(back.pins, [_deploy, _podsKs]);
      // Pins land after the last visible entry, not under More.
      expect(back.entries.indexWhere((e) => e.pin == _deploy), lessThan(back.entries.indexWhere((e) => e.view == HelmModule.page)));

      final odd = SidebarConfig.fromJson({
        'items': [
          {'view': 'helm'},
          {'view': 'nope'},
          {'view': 'alerts'}, // moved to the dock: dropped from saved layouts
          {'view': 'resources'},
          {'kind': 'Pod'},
          {'kind': 'Pod'},
        ],
      });
      expect(odd.entries.first, const SidebarEntry.view(HelmModule.page));
      expect(odd.pins, [const SidebarPin(group: '', kind: 'Pod')]);
      // Every page is present exactly once; ones the file lacked keep their default visibility.
      expect(odd.entries.where((e) => e.view != null).length, SidebarConfig.pages.length);
      expect(odd.isHidden(AddonsModule.page), isTrue);
      expect(odd.isHidden(MainView.overview), isFalse);
      expect(odd.entries.any((e) => e.view == MainView.alerts), isFalse);
      expect(SidebarConfig.fromJson(null).isDefault, isTrue);
    });

  });

  testWidgets('hidden and reordered pages, pins with selection highlight', (tester) async {
    final layout = SidebarConfig([
      const SidebarEntry.view(MainView.nodes),
      const SidebarEntry.pin(_deploy),
      ...SidebarConfig.defaults.entries.where((e) => e.view != MainView.nodes),
      const SidebarEntry.pin(SidebarPin(group: 'example.com', kind: 'Missing')),
    ]).setHidden(MainView.security, true);
    final (app, _) = await _pumpNav(tester, layout: layout);

    // Order follows the layout; hidden Security is folded under More.
    expect(_y(tester, 'nav-view-nodes'), lessThan(_y(tester, 'nav-pin-apps/Deployment')));
    expect(_y(tester, 'nav-pin-apps/Deployment'), lessThan(_y(tester, 'nav-view-overview')));
    expect(find.byKey(const ValueKey('nav-view-security')), findsNothing);
    // A pin for a kind this cluster doesn't serve is left out quietly.
    expect(find.byKey(const ValueKey('nav-pin-example.com/Missing')), findsNothing);

    // Clicking the pin selects the kind; the pin holds the highlight.
    await tester.tap(find.byKey(const ValueKey('nav-pin-apps/Deployment')));
    await tester.pump();
    expect(app.view, MainView.resources);
    expect(app.selectedType?.gk, 'apps/Deployment');
    expect(app.selectedPin, _deploy);

    // A hidden page stays reachable through More, which stays open while it's active.
    await tester.tap(find.text('More'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-view-security')));
    await tester.pump();
    expect(app.view, MainView.security);
    expect(find.text('Less'), findsNothing);
    expect(find.byKey(const ValueKey('nav-view-security')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('right-click: pin a kind from the list, hide a page, unpin', (tester) async {
    final (app, api) = await _pumpNav(tester);
    // "More" is session-wide state; start with it closed.
    if (find.text('Less').evaluate().isNotEmpty) {
      await tester.tap(find.text('Less'));
      await tester.pump();
    }
    await tester.tap(find.byKey(const ValueKey('nav-kind-apps/Deployment')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin to Sidebar'));
    await tester.pumpAndSettle();
    expect(app.sidebar.pins, [_deploy]);
    expect(find.byKey(const ValueKey('nav-pin-apps/Deployment')), findsOneWidget);
    expect(api.sidebarLayout, isNotNull, reason: 'saved to settings');

    // With a namespace chosen, the pin can be scoped to it.
    app.setNamespace('kube-system');
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-kind-/Pod')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pin to Sidebar in “kube-system”'));
    await tester.pumpAndSettle();
    expect(app.sidebar.isPinned(_podsKs), isTrue);
    app.setNamespace(null);
    await tester.tap(find.byKey(const ValueKey('nav-pin-/Pod@kube-system')));
    await tester.pump();
    expect(app.namespace, 'kube-system');
    expect(app.selectedPin, _podsKs);

    await tester.tap(find.byKey(const ValueKey('nav-view-security')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Hide Security'));
    await tester.pumpAndSettle();
    expect(app.sidebar.isHidden(MainView.security), isTrue);
    expect(find.byKey(const ValueKey('nav-view-security')), findsNothing);

    await tester.tap(find.byKey(const ValueKey('nav-pin-apps/Deployment')), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unpin from Sidebar'));
    await tester.pumpAndSettle();
    expect(app.sidebar.isPinned(_deploy), isFalse);
  });

}
