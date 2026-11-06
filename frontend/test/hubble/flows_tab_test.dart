import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/hubble/flow_list.dart';
import 'package:k8sman/hubble/hubble_api.dart';
import 'package:k8sman/modules/hubble_module.dart';
import 'package:k8sman/modules/modules.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';

/// Serves synthetic flows, honouring the verdict filter like the relay.
class _FakeHubble extends HubbleApi {
  _FakeHubble(super.api);
  final queries = <FlowQuery>[];

  static Json _flow(int i, {bool dropped = false}) => {
        'time': DateTime.utc(2026, 1, 1, 12, 0, i).toIso8601String(),
        'verdict': dropped ? 'DROPPED' : 'FORWARDED',
        if (dropped) 'dropReason': 'POLICY_DENIED',
        'direction': 'EGRESS',
        'source': {'namespace': 'demo', 'pod': 'web-1', 'ip': '10.0.1.10'},
        'destination': {'namespace': 'demo', 'pod': 'api-$i', 'ip': '10.0.2.$i', 'port': 8080},
        'l4': {'protocol': 'TCP'},
        if (!dropped) 'l7': {'kind': 'RESPONSE', 'http': {'method': 'GET', 'url': 'http://api/items', 'code': 200}},
      };

  @override
  Stream<Json> flowFrames(FlowQuery q, {bool follow = true}) {
    queries.add(q);
    final all = [_flow(1), _flow(2, dropped: true), _flow(3), _flow(4, dropped: true), _flow(5)];
    // Left open, like a following stream; the view cancels it.
    final c = StreamController<Json>();
    c.add({'flows': [for (final f in all) if (q.verdicts.isEmpty || q.verdicts.contains(f['verdict'])) f]});
    return c.stream;
  }
}

void main() {
  testWidgets('Flows tab shows flows with drops highlighted, and the verdict filter re-queries', (tester) async {
    final client = FakeApiClient();
    final fake = _FakeHubble(client);
    HubbleApi.debugOverride = (_) => fake;
    addTearDown(() => HubbleApi.debugOverride = null);
    const module = HubbleModule();
    final app = AppState(client)..types = testTypes;
    moduleStatuses.debugSet(module, client, app.currentContext, const ModuleStatus(ModuleState.connected));

    final pod = {
      'apiVersion': 'v1',
      'kind': 'Pod',
      'metadata': {'name': 'web-1', 'namespace': 'demo', 'uid': 'u1'},
    };
    final ctx = PanelContext(object: pod, type: testType('', 'Pod'), api: client, app: app);
    // The module adds the tab to a kind it doesn't own.
    final tab = module.inspectorTabs(ctx).single;
    expect(tab.label, 'Flows');

    tester.view.physicalSize = const Size(520, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: Scaffold(body: Builder(builder: (c) => tab.builder(c, ctx)))),
    ));
    await tester.pump();

    expect(fake.queries.single.pod, 'demo/web-1');
    expect(find.byType(FlowRow), findsNWidgets(5));
    expect(find.text('policy denied'), findsNWidgets(2));
    expect(find.text('GET /items → 200'), findsNWidgets(3));

    // Drops are tinted; forwarded rows aren't.
    Color fill(bool dropped) {
      final row = find.byWidgetPredicate((w) => w is FlowRow && w.flow.dropped == dropped).first;
      return tester.widget<Material>(find.descendant(of: row, matching: find.byType(Material)).first).color!;
    }

    expect(fill(true).a, greaterThan(0));
    expect(fill(false).a, 0);

    // Dropped only: asked of the source, not filtered locally.
    await tester.tap(find.byKey(const ValueKey('verdict-DROPPED')));
    await tester.pump();
    expect(fake.queries.last.verdicts, {'DROPPED'});
    expect(fake.queries.last.pod, 'demo/web-1');
    expect(find.byType(FlowRow), findsNWidgets(2));
    expect(find.byWidgetPredicate((w) => w is FlowRow && !w.flow.dropped), findsNothing);

    await tester.tap(find.byKey(const ValueKey('verdict-all')));
    await tester.pump();
    expect(fake.queries.last.verdicts, isEmpty);
    expect(find.byType(FlowRow), findsNWidgets(5));
  });
}
