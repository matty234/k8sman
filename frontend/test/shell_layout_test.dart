import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/app_state.dart';
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

Future<void> _meta(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
}

/// The inspector is on screen (not collapsed offstage).
bool _inspectorVisible(WidgetTester tester) => find.byType(DetailSidebar).hitTestable().evaluate().isNotEmpty;

void main() {
  group('log dock', () {
    testWidgets('opens from the pod Logs action and container cards; reopening focuses', (tester) async {
      final api = FixtureApi();
      final (_, dock) = await pumpShell(tester, api);
      await _openWebPod(tester);
      expect(find.byType(LogDockView), findsNothing);

      await tester.tap(find.byKey(const ValueKey('action-logs')));
      await settleLogs(tester);
      expect(find.byType(LogDockView), findsOneWidget);
      expect(dock.tabs.map((t) => t.label), ['$_webPod/nginx']);
      expect(find.byKey(const ValueKey('log-tab-demo/$_webPod/nginx')), findsOneWidget);
      expect(find.textContaining('upstream timed out'), findsWidgets);

      // A container card's "View logs" for another container adds a tab…
      final initLogs = find.byKey(const ValueKey('view-logs-init-wait'));
      await tester.ensureVisible(initLogs);
      await tester.tap(initLogs);
      await settleLogs(tester);
      expect(dock.tabs.length, 2);
      expect(dock.active?.container, 'init-wait');

      // …and the same stream again focuses the existing tab.
      final nginxLogs = find.byKey(const ValueKey('view-logs-nginx'));
      await tester.ensureVisible(nginxLogs);
      await tester.tap(nginxLogs);
      await settleLogs(tester);
      expect(dock.tabs.length, 2);
      expect(dock.active?.container, 'nginx');

      // Tabs survive navigating the table and the inspector.
      await tester.tap(find.text('crashy').first);
      await _settle(tester);
      await tester.tap(find.text('Deployment').first);
      await _settle(tester);
      expect(dock.tabs.length, 2);
      expect(find.byType(LogStreamView), findsOneWidget);
      dock.closeAll();
    });

    testWidgets('closing a tab cancels its stream; collapsed tabs keep streaming', (tester) async {
      final api = FixtureApi();
      final (_, dock) = await pumpShell(tester, api);
      final a = dock.open(FixtureApi.objectFor('pods', _webPod));
      final b = dock.open(FixtureApi.objectFor('pods', 'crashy'));
      await settleLogs(tester);
      final ca = api.logControllers['demo/$_webPod/nginx']!;
      final cb = api.logControllers['demo/crashy/app']!;
      expect(ca.hasListener && cb.hasListener, isTrue);

      // Collapsed (⌘J) still streams into the buffer.
      await _meta(tester, LogicalKeyboardKey.keyJ);
      expect(dock.collapsed, isTrue);
      expect(find.byType(LogStreamView), findsNothing);
      ca.add(const LogMessage(line: 'while collapsed'));
      await settleLogs(tester);
      expect(a.lines.last, 'while collapsed');
      await _meta(tester, LogicalKeyboardKey.keyJ);
      expect(dock.collapsed, isFalse);

      await tester.tap(find.byKey(const ValueKey('log-tab-close-demo/crashy/app')));
      await tester.pump();
      expect(cb.hasListener, isFalse, reason: 'closed tab cancels its subscription');
      expect(b.isSubscribed, isFalse);
      expect(ca.hasListener, isTrue);
      expect(dock.tabs, [a]);

      // Closing the last tab hides the dock; ⌘J brings back an empty one.
      dock.close(a);
      await tester.pump();
      expect(ca.hasListener, isFalse);
      expect(find.byType(LogDockView), findsNothing);
      await _meta(tester, LogicalKeyboardKey.keyJ);
      expect(find.byType(LogDockView), findsOneWidget);
      expect(find.textContaining('No log streams'), findsOneWidget);
      await _meta(tester, LogicalKeyboardKey.keyJ);
      expect(find.byType(LogDockView), findsNothing);
    });

    testWidgets('context menu: close others', (tester) async {
      final api = FixtureApi();
      final (_, dock) = await pumpShell(tester, api);
      dock.open(FixtureApi.objectFor('pods', _webPod));
      dock.open(FixtureApi.objectFor('pods', 'crashy'));
      dock.open(FixtureApi.objectFor('pods', _webPod), container: 'log-sidecar');
      await settleLogs(tester);
      await tester.tap(find.byKey(const ValueKey('log-tab-demo/crashy/app')), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Close others'));
      await tester.pumpAndSettle();
      expect(dock.tabs.map((t) => t.label), ['crashy/app']);
      expect(api.logControllers['demo/$_webPod/nginx']!.hasListener, isFalse);
      dock.closeAll();
    });

    testWidgets('Deployment Logs opens a tab per pod', (tester) async {
      final api = FixtureApi();
      final (app, dock) = await pumpShell(tester, api);
      app.openDetail(DetailTarget(type: app.typeFor('apps', 'Deployment')!, name: 'web', namespace: 'demo'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('action-logs')));
      await settleLogs(tester);
      expect(dock.tabs.map((t) => t.label), ['$_webPod/nginx', 'web-6fd47b8fcb-z7wpf/nginx']);
      expect(dock.active?.pod, _webPod);
      dock.closeAll();
    });
  });

  group('inspector collapse', () {
    testWidgets('switching kind collapses; the tab re-expands; a row click replaces it', (tester) async {
      final (app, _) = await pumpShell(tester, FixtureApi());
      await _openWebPod(tester);
      expect(_inspectorVisible(tester), isTrue);

      await tester.tap(find.text('Deployment').first);
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

      // Changing top-level view collapses too (Port Forwards is under "More").
      if (find.text('More').evaluate().isNotEmpty) {
        await tester.tap(find.text('More'));
        await tester.pump();
      }
      await tester.tap(find.text('Port Forwards').first);
      await _settle(tester);
      expect(app.inspectorCollapsed, isTrue);
    });

    testWidgets('⌘I toggles the inspector', (tester) async {
      final (app, _) = await pumpShell(tester, FixtureApi());
      await _meta(tester, LogicalKeyboardKey.keyI); // no detail: no-op
      expect(app.inspectorCollapsed, isFalse);
      await _openWebPod(tester);
      await _meta(tester, LogicalKeyboardKey.keyI);
      expect(app.inspectorCollapsed, isTrue);
      expect(_inspectorVisible(tester), isFalse);
      await _meta(tester, LogicalKeyboardKey.keyI);
      expect(app.inspectorCollapsed, isFalse);
      expect(_inspectorVisible(tester), isTrue);
    });
  });

  group('inspector header actions', () {
    Future<AppState> open(WidgetTester tester, String group, String kind, String name) async {
      final (app, _) = await pumpShell(tester, FixtureApi());
      app.openDetail(DetailTarget(type: app.typeFor(group, kind)!, name: name, namespace: 'demo'));
      await _settle(tester);
      return app;
    }

    testWidgets('Secret: Delete is a header icon, no action row', (tester) async {
      await open(tester, '', 'Secret', 'web-secret');
      expect(find.byKey(const ValueKey('action-delete')), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byTooltip('More actions'), findsNothing);
      // Delete sits in the header, left of copy/collapse/close.
      final del = tester.getCenter(find.byKey(const ValueKey('action-delete')));
      final close = tester.getCenter(find.byTooltip('Close (Esc)'));
      expect((del.dy - close.dy).abs(), lessThan(2));
      expect(del.dx, lessThan(tester.getCenter(find.byTooltip('Copy name')).dx));
    });

    testWidgets('Deployment: action row plus ⋯ with Roll back and Delete', (tester) async {
      await open(tester, 'apps', 'Deployment', 'web');
      expect(find.byKey(const ValueKey('action-logs')), findsOneWidget);
      expect(find.byType(OutlinedButton), findsNWidgets(3));
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(find.text('Roll back'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
    });

    testWidgets('Job: a single overflow action is an icon button, not a menu', (tester) async {
      await open(tester, 'batch', 'Job', 'migrate-db');
      expect(find.byType(OutlinedButton), findsNWidgets(2)); // Logs, Suspend
      expect(find.byTooltip('More actions'), findsNothing);
      expect(find.byKey(const ValueKey('action-delete')), findsOneWidget);
      expect(find.byTooltip('Delete'), findsOneWidget);
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
      for (var w = 900.0; w <= 1800; w += 13) {
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
}
