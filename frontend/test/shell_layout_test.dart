import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/ui/detail/detail_sidebar.dart';
import 'package:k8sman/ui/logs/log_dock_view.dart';
import 'package:k8sman/ui/logs/log_stream_view.dart';

import 'support/fixture_api.dart';

const _webPod = 'web-6fd47b8fcb-4v4m9';

Future<void> _settle(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 50));
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _openWebPod(WidgetTester tester) async {
  await tester.tap(find.text(_webPod).first);
  await _settle(tester);
}

/// The inspector is on screen (not collapsed offstage).
bool _inspectorVisible(WidgetTester tester) => find.byType(DetailSidebar).hitTestable().evaluate().isNotEmpty;

void main() {
  group('log dock', () {
    testWidgets('opens from the pod Logs action and container cards; reopening focuses', (tester) async {
      final api = FixtureApi();
      final (_, dock) = await pumpShell(tester, api);
      await _openWebPod(tester);
      expect(find.byType(LogDockView), findsOneWidget, reason: 'the bar is always there');
      expect(dock.collapsed, isTrue);

      await tester.tap(find.byKey(const ValueKey('action-logs')));
      await settleLogs(tester);
      expect(dock.collapsed, isFalse);
      expect(dock.tabs.map((t) => t.label), ['$_webPod/nginx']);
      expect(find.byKey(const ValueKey('log-tab-demo/$_webPod/nginx')), findsOneWidget);
      expect(find.textContaining('upstream timed out'), findsWidgets);

      // A container row's "View logs" (shown once it is open or hovered)
      // for another container adds a tab…
      await _expandContainer(tester, 'init-wait');
      final initLogs = find.byKey(const ValueKey('view-logs-init-wait'));
      await tester.ensureVisible(initLogs);
      await tester.tap(initLogs);
      await settleLogs(tester);
      expect(dock.tabs.length, 2);
      expect(dock.active?.container, 'init-wait');

      // …and the same stream again focuses the existing tab.
      await _expandContainer(tester, 'nginx');
      final nginxLogs = find.byKey(const ValueKey('view-logs-nginx'));
      await tester.ensureVisible(nginxLogs);
      await tester.tap(nginxLogs);
      await settleLogs(tester);
      expect(dock.tabs.length, 2);
      expect(dock.active?.container, 'nginx');

      // Tabs survive navigating the table and the inspector.
      await tester.tap(find.text('crashy').first);
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('nav-kind-apps/Deployment')));
      await _settle(tester);
      expect(dock.tabs.length, 2);
      expect(find.byType(LogStreamView), findsOneWidget);
      dock.closeAll();
    });

  });

  group('inspector collapse', () {
    testWidgets('switching kind collapses; the tab re-expands; a row click replaces it', (tester) async {
      final (app, _) = await pumpShell(tester, FixtureApi());
      await _openWebPod(tester);
      expect(_inspectorVisible(tester), isTrue);

      await tester.tap(find.byKey(const ValueKey('nav-kind-apps/Deployment')));
      await _settle(tester);
      expect(app.inspectorCollapsed, isTrue);
      expect(app.detail?.name, _webPod);
      expect(_inspectorVisible(tester), isFalse);
      final tab = find.byKey(const ValueKey('inspector-collapsed-tab'));
      expect(tab, findsOneWidget);
      // The main column reclaims the width (only the slim tab remains).
      expect(tester.getSize(tab).width, lessThan(40));

      await tester.tap(tab);
      await _settle(tester);
      expect(app.inspectorCollapsed, isFalse);
      expect(_inspectorVisible(tester), isTrue);
      expect(app.detail?.name, _webPod);

      // Collapse via the header button, then a row in the new table opens expanded.
      await tester.tap(find.byKey(const ValueKey('inspector-collapse')));
      await _settle(tester);
      expect(app.inspectorCollapsed, isTrue);
      await tester.tap(find.text('coredns').first);
      await _settle(tester);
      expect(app.inspectorCollapsed, isFalse);
      expect(app.detail?.name, 'coredns');
      expect(find.byKey(const ValueKey('inspector-collapsed-tab')), findsNothing);

      // Changing top-level view collapses too (Helm is under "More").
      if (find.text('More').evaluate().isNotEmpty) {
        await tester.tap(find.text('More'));
        await tester.pump();
      }
      await tester.tap(find.text('Helm').first);
      await _settle(tester);
      expect(app.inspectorCollapsed, isTrue);
    });

  });

  testWidgets('no overflow 900–1800 wide with the dock open, inspector open and collapsed', (tester) async {
    final api = FixtureApi();
    final (app, dock) = await pumpShell(tester, api, size: const Size(900, 800));
    await _openWebPod(tester);
    dock.open(FixtureApi.objectFor('pods', _webPod));
    dock.open(FixtureApi.objectFor('pods', 'crashy'));
    dock.open(FixtureApi.objectFor('pods', 'bad-image'));
    await settleLogs(tester);
    for (final collapsed in [false, true]) {
      if (collapsed) app.collapseInspector();
      for (final w in [900.0, 1300.0, 1800.0]) {
        tester.view.physicalSize = Size(w, 800);
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'overflow at width $w (collapsed: $collapsed)');
      }
    }
    // Short window: the dock clamps and the strip-only state fits too.
    tester.view.physicalSize = const Size(900, 420);
    await tester.pump();
    dock.setCollapsed(true);
    await tester.pump();
    expect(tester.takeException(), isNull);
    dock.closeAll();
  });

  testWidgets('opening the inspector does not shift the table columns', (tester) async {
    await pumpShell(tester, FixtureApi(), size: const Size(2000, 900));
    double x(String text) => tester.getTopLeft(find.text(text).first).dx;
    final before = [x('Name'), x('Namespace'), x('Status')];
    await _openWebPod(tester);
    expect(_inspectorVisible(tester), isTrue);
    expect([x('Name'), x('Namespace'), x('Status')], before);
  });
}

Future<void> _expandContainer(WidgetTester tester, String name) async {
  final row = find.byKey(ValueKey('container-row-$name'));
  await tester.ensureVisible(row);
  await tester.tap(row, warnIfMissed: false);
  await tester.pump();
}
