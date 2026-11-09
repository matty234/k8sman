import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/modules/addons_module.dart';
import 'package:k8sman/modules/helm_module.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/resource_nav.dart';
import 'package:k8sman/ui/settings/sidebar_settings.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import 'support/fixture_api.dart';
import 'support/harness.dart';
import 'support/screenshot.dart';

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

    test('AppState saves through the API and loads it back; defaults reset', () async {
      final api = FakeApiClient();
      final app = AppState(api)..setSidebar(SidebarConfig.defaults.pin(_deploy));
      await Future<void>.delayed(Duration.zero);
      expect(api.sidebarLayout, isNotNull);
      final again = AppState(api);
      await again.loadSidebar();
      expect(again.sidebar.pins, [_deploy]);
      app.setSidebar(SidebarConfig.defaults);
      await Future<void>.delayed(Duration.zero);
      expect(api.sidebarLayout, isNull, reason: 'default layout = no customisation');
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

  testWidgets('Settings ▸ Sidebar: untick and unpin save at once', (tester) async {
    final api = FakeApiClient();
    final app = AppState(api)
      ..types = testTypes
      ..sidebar = SidebarConfig.defaults.pin(_deploy);
    tester.view.physicalSize = const Size(700, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ChangeNotifierProvider<AppState>.value(
      value: app,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: SingleChildScrollView(child: SidebarLayoutEditor()))),
    ));
    await tester.tap(find.byKey(const ValueKey('sidebar-show-overview')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('sidebar-unpin-apps/Deployment@')));
    await tester.pump();
    expect(app.sidebar.isHidden(MainView.overview), isTrue);
    expect(app.sidebar.pins, isEmpty);
    expect(api.sidebarLayout, isNotNull, reason: 'saved without a Done button');
  });

  testWidgets('many pins: short windows scroll instead of overflowing', (tester) async {
    var layout = SidebarConfig.defaults;
    for (final k in ['Pod', 'Service', 'ConfigMap', 'Secret', 'Namespace', 'Event']) {
      layout = layout.pin(SidebarPin(group: '', kind: k));
    }
    await _pumpNav(tester, layout: layout, height: 420);
    expect(tester.takeException(), isNull);
  });

  testWidgets('screenshots: customised sidebar and Settings ▸ Sidebar', (tester) async {
    await loadRealFonts();
    final api = FixtureApi();
    final (app, _) = await pumpShell(tester, api, size: const Size(1200, 780));
    app.setSidebar(SidebarConfig([
      const SidebarEntry.view(MainView.overview),
      const SidebarEntry.pin(SidebarPin(group: 'apps', kind: 'Deployment')),
      const SidebarEntry.pin(_podsKs),
      const SidebarEntry.view(MainView.nodes),
      const SidebarEntry.view(HelmModule.page),
      ...SidebarConfig.defaults.entries.map((e) => e.view == MainView.security ? e.withHidden(true) : e),
    ]));
    app.openPin(_podsKs);
    for (var i = 0; i < 3; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    await saveScreenshot(tester, 'sidebar-customised');
    // Settings (the sidebar's gear) ▸ Sidebar.
    await tester.tap(find.byKey(const ValueKey('nav-settings')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Sidebar').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SidebarLayoutEditor), findsOneWidget);
    await saveScreenshot(tester, 'sidebar-settings');
    expect(tester.takeException(), isNull);
  });
}
