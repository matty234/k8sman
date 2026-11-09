import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/state/aggregate_log_stream.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/detail/detail_sidebar.dart';
import 'package:k8sman/ui/alerts/alerts_view.dart';
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

      // Closing the last tab collapses the dock to its bar; ⌘J opens Alerts.
      dock.close(a);
      await tester.pump();
      expect(ca.hasListener, isFalse);
      expect(dock.collapsed, isTrue);
      expect(find.byType(LogDockView), findsOneWidget);
      await _meta(tester, LogicalKeyboardKey.keyJ);
      expect(dock.collapsed, isFalse);
      expect(find.byType(AlertsView), findsOneWidget);
      await _meta(tester, LogicalKeyboardKey.keyJ);
      expect(dock.collapsed, isTrue);
      expect(find.byType(AlertsView), findsNothing);
    });

    testWidgets('Alerts lives in the dock: its tab, showView and the logs share the panel', (tester) async {
      final api = FixtureApi();
      final (app, dock) = await pumpShell(tester, api);
      expect(find.byKey(const ValueKey('nav-view-alerts')), findsNothing, reason: 'not a sidebar page any more');

      await tester.tap(find.byKey(const ValueKey('dock-alerts-tab')));
      await tester.pump();
      expect(dock.alertsOpen && !dock.collapsed, isTrue);
      expect(find.byWidgetPredicate((w) => w is AlertsView && w.docked), findsOneWidget);
      // Clicking it again tucks the dock away.
      await tester.tap(find.byKey(const ValueKey('dock-alerts-tab')));
      await tester.pump();
      expect(dock.collapsed, isTrue);

      // "Alerts" from anywhere else (palette, Prometheus links) opens the pane,
      // leaving the page that was showing alone.
      final view = app.view;
      app.showView(MainView.alerts);
      await tester.pump();
      expect(app.view, view);
      expect(dock.alertsOpen && !dock.collapsed, isTrue);

      // Opening logs switches the panel to them; the Alerts tab switches back.
      final s = dock.open(FixtureApi.objectFor('pods', _webPod));
      await settleLogs(tester);
      expect(dock.alertsOpen, isFalse);
      expect(dock.activeTab, s);
      expect(find.byType(LogStreamView), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('dock-alerts-tab')));
      await tester.pump();
      expect(find.byType(LogStreamView), findsNothing);
      expect(find.byWidgetPredicate((w) => w is AlertsView && w.docked), findsOneWidget);
      dock.closeAll();
      expect(dock.collapsed, isFalse, reason: 'Alerts was showing, so the panel stays');
      dock.setCollapsed(true);
      await tester.pump();
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

    testWidgets('Deployment Logs opens one merged tab; sources can be hidden', (tester) async {
      final api = FixtureApi();
      final (app, dock) = await pumpShell(tester, api);
      app.openDetail(DetailTarget(type: app.typeFor('apps', 'Deployment')!, name: 'web', namespace: 'demo'));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('action-logs')));
      await settleLogs(tester);
      expect(api.aggregateRequests, hasLength(1));
      expect(api.aggregateRequests.single, startsWith('selector=app=web'));
      expect(dock.tabs.map((t) => t.label), ['deploy/web (2 pods)']);

      // Lines carry a short pod label (the name minus the shared prefix).
      expect(find.text('4v4m9'), findsWidgets);
      expect(find.text('z7wpf'), findsWidgets);
      expect(find.textContaining('served by web-6fd47b8fcb-z7wpf'), findsWidgets);

      // Hiding a source drops its lines.
      final s = dock.tabs.single as AggregateLogStream;
      s.setPodHidden('web-6fd47b8fcb-z7wpf', true);
      await tester.pump();
      expect(find.textContaining('served by web-6fd47b8fcb-z7wpf'), findsNothing);
      expect(find.textContaining('served by web-6fd47b8fcb-4v4m9'), findsWidgets);

      // Previous reconnects with previous=true, then back to normal.
      s.setOptions(previous: true);
      await settleLogs(tester);
      expect(api.aggregateRequests.last, endsWith('previous'));
      expect(s.previous, isTrue);
      s.setOptions(previous: false);
      await settleLogs(tester);
      expect(api.aggregateRequests.last, isNot(endsWith('previous')));
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

    testWidgets('breadcrumbs: kind opens its list, namespace opens the Namespace; history menu', (tester) async {
      final (app, _) = await pumpShell(tester, FixtureApi());
      await _openWebPod(tester);
      final pod = app.detail!;
      expect(pod.type.kind, 'Pod');

      // Elsewhere first, so the crumb has somewhere to take us back from.
      app.showView(MainView.overview);
      await _settle(tester);
      app.expandInspector();
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('crumb-kind')));
      await _settle(tester);
      expect(app.view, MainView.resources);
      expect(app.selectedType, pod.type);
      expect(app.inspectorCollapsed, isTrue, reason: 'the table gets the width');
      expect(app.detail, pod, reason: 'its row stays selected');

      // The namespace crumb pushes the Namespace object (Back returns).
      app.expandInspector();
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('crumb-namespace')));
      await _settle(tester);
      tester.takeException(); // the fixtures have no Namespace object to load
      final ns = app.detail!;
      expect(ns.type.kind, 'Namespace');
      expect(ns.name, pod.namespace);
      expect(app.canGoBack, isTrue);
      expect(app.recentDetails.take(2), [ns, pod]);

      // History lists the others (not the current object); picking one
      // opens it afresh.
      app.back();
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('inspector-history')));
      await _settle(tester);
      expect(find.byType(PopupMenuItem<DetailTarget>), findsOneWidget);
      await tester.tap(find.byType(PopupMenuItem<DetailTarget>));
      await _settle(tester);
      tester.takeException();
      expect(app.detail, ns);
      expect(app.canGoBack, isFalse, reason: 'opening from history starts afresh');
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

    testWidgets('Job: Copy kubectl and Delete share the ⋯ menu', (tester) async {
      await open(tester, 'batch', 'Job', 'migrate-db');
      expect(find.byType(OutlinedButton), findsNWidgets(2)); // Logs, Suspend
      await tester.tap(find.byTooltip('More actions'));
      await tester.pumpAndSettle();
      expect(find.text('Copy kubectl…'), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);
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

Future<void> _expandContainer(WidgetTester tester, String name) async {
  final row = find.byKey(ValueKey('container-row-$name'));
  await tester.ensureVisible(row);
  await tester.tap(row, warnIfMissed: false);
  await tester.pump();
}
