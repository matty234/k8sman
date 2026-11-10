import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
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
      // The section order round-trips; unknown titles drop out, missing ones follow.
      final ordered = c.withSectionOrder(['Storage', 'Nope', 'Workloads']);
      expect(SidebarConfig.fromJson(ordered.toJson()).sectionOrder, ['Storage', 'Nope', 'Workloads']);
      expect(ordered.orderSections(['Workloads', 'Network', 'Storage']), ['Storage', 'Workloads', 'Network']);
      expect(ordered.pin(_deploy).sectionOrder, ordered.sectionOrder);
      expect(ordered.isDefault, isFalse);
      // Pins land after the last visible entry, not under More.
      expect(back.entries.indexWhere((e) => e.pin == _deploy), lessThan(back.entries.indexWhere((e) => e.view == HelmModule.page)));

      final odd = SidebarConfig.fromJson({
        'items': [
          {'view': 'helm'},
          {'view': 'nope'},
          {'view': 'alerts'}, // moved to the dock: dropped from saved layouts
          {'view': 'addons'}, // moved to Settings: dropped too
          {'view': 'resources'},
          {'kind': 'Pod'},
          {'kind': 'Pod'},
        ],
      });
      expect(odd.entries.first, const SidebarEntry.view(HelmModule.page));
      expect(odd.pins, [const SidebarPin(group: '', kind: 'Pod')]);
      // Every page is present exactly once; ones the file lacked keep their default visibility.
      expect(odd.entries.where((e) => e.view != null).length, SidebarConfig.pages.length);
      expect(odd.isHidden(MainView.overview), isFalse);
      expect(odd.entries.any((e) => e.view == MainView.alerts || e.view?.name == 'addons'), isFalse);
      expect(SidebarConfig.fromJson(null).isDefault, isTrue);
    });

  });

  testWidgets('kinds list: core, then integrations A-Z, then Custom Resources; a saved order wins', (tester) async {
    final extra = [
      const ResourceType(group: 'gateway.networking.k8s.io', version: 'v1', resource: 'gateways', kind: 'Gateway'),
      const ResourceType(group: 'argoproj.io', version: 'v1alpha1', resource: 'applications', kind: 'Application', custom: true),
      const ResourceType(group: 'example.com', version: 'v1', resource: 'widgets', kind: 'Widget', custom: true),
    ];
    Future<void> pump(SidebarConfig? layout) async {
      final api = FakeApiClient();
      final app = AppState(api)..types = [...testTypes, ...extra];
      if (layout != null) app.sidebar = layout;
      tester.view.physicalSize = const Size(232, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MultiProvider(
        providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
        child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: ResourceNav())),
      ));
      await tester.pump();
    }

    double y(String t) => tester.getTopLeft(find.text(t)).dy;
    await pump(null);
    final order = ['Workloads', 'Access Control', 'Argo CD', 'Gateway API', 'Custom Resources'];
    for (var i = 1; i < order.length; i++) {
      expect(y(order[i - 1]), lessThan(y(order[i])), reason: '${order[i - 1]} before ${order[i]}');
    }

    await pump(SidebarConfig.defaults.withSectionOrder(['Gateway API', 'Nope', 'Workloads']));
    expect(y('Gateway API'), lessThan(y('Workloads')));
    expect(y('Workloads'), lessThan(y('Network')));
    expect(y('Argo CD'), greaterThan(y('Access Control')));
    expect(y('Argo CD'), lessThan(y('Custom Resources')));
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

    // A hidden page stays reachable through More; Less stays after opening
    // it, and folding keeps the open page showing.
    await tester.tap(find.text('More'));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('nav-view-security')));
    await tester.pump();
    expect(app.view, MainView.security);
    await tester.tap(find.text('Less'));
    await tester.pump();
    expect(find.text('More'), findsOneWidget);
    expect(find.byKey(const ValueKey('nav-view-security')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

}
