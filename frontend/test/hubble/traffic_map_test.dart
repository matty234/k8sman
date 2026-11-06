import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/hubble/hubble_api.dart';
import 'package:k8sman/hubble/hubble_view.dart';
import 'package:k8sman/hubble/traffic_map.dart';
import 'package:k8sman/hubble/traffic_model.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../support/harness.dart';

/// A connected relay with a synthetic traffic map: web and api behind
/// Ingress, payments calling out, a dropped web → payments edge.
class _FakeHubble extends HubbleApi {
  _FakeHubble(super.api);
  final checks = <(String, String)>[];
  var mapCalls = 0;

  @override
  Future<HubbleStatus> status({bool refresh = false}) async => const HubbleStatus(state: 'connected', version: 'v1.18.0', connectedNodes: 3);

  @override
  Future<TrafficMap> trafficMap({String window = '5m'}) async {
    mapCalls++;
    Json edge(String from, String to, int flows, {int drops = 0, String port = 'TCP/8080', List<String> peers = const []}) => {
          'from': from,
          'to': to,
          'flows': flows,
          'drops': drops,
          'rate': 1.5,
          'ports': [
            {'name': port, 'n': flows + drops},
          ],
          'peers': [
            for (final p in peers) {'name': p, 'n': flows},
          ],
          if (drops > 0)
            'reasons': [
              {'name': 'POLICY_DENIED', 'n': drops},
            ],
        };
    return TrafficMap.fromJson({
      'window': window,
      'flows': 9000,
      'drops': 40,
      'rate': 30,
      'state': 'live',
      'edges': [
        edge('reserved:ingress', 'web', 4000),
        edge('web', 'api', 3000),
        edge('api', 'payments', 1200),
        edge('web', 'payments', 0, drops: 40),
        edge('payments', 'reserved:world', 600, port: 'TCP/443', peers: ['api.stripe.com']),
        edge('api', 'reserved:kube-apiserver', 900, port: 'TCP/6443'),
      ],
    });
  }

  @override
  Future<Connectivity> connectivity(String from, String to, {String since = '15m'}) async {
    checks.add((from, to));
    return const Connectivity(verdict: 'dropped', verdicts: {'DROPPED': 40});
  }

  @override
  Stream<Json> flowFrames(FlowQuery q, {bool follow = true}) => StreamController<Json>().stream;
}

void main() {
  testWidgets('Map draws the namespaces and the world; clicking an edge offers "Can A reach B?"', (tester) async {
    final client = FakeApiClient();
    final fake = _FakeHubble(client);
    HubbleApi.debugOverride = (_) => fake;
    addTearDown(() => HubbleApi.debugOverride = null);
    final app = AppState(client)..types = testTypes;
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: client), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const Scaffold(body: HubbleView())),
    ));
    await tester.pump();
    await tester.pump();

    // The Map tab is the first: the edges of the cluster are listed, and
    // the API server is hidden until asked for (its volume on the toggle).
    expect(fake.mapCalls, 1);
    expect(find.byKey(const ValueKey('map-in-web')), findsOneWidget);
    expect(find.byKey(const ValueKey('map-out-payments')), findsOneWidget);
    expect(find.text('API server 900'), findsOneWidget);
    final layout = debugRadialLayout!;
    expect(layout.lanes.keys, containsAll(['reserved:ingress', 'web', 'api', 'payments']));
    expect(layout.lanes.containsKey('reserved:kube-apiserver'), isFalse);
    expect(layout.pointOn('payments', 'reserved:world'), isNotNull, reason: 'payments calls out: a ray');

    // Click the dropped chord: its details, then the check.
    final canvas = tester.getTopLeft(find.byKey(const ValueKey('traffic-map-canvas')));
    await tester.tapAt(canvas + layout.pointOn('web', 'payments')!);
    await tester.pump();
    expect(find.text('web → payments'), findsOneWidget);
    expect(find.text('policy denied'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('map-check-reach')));
    await tester.pump();
    await tester.pump();
    expect(fake.checks, [('ns:web', 'ns:payments')]);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('reach-from'))).controller!.text, 'ns:web');
    expect(find.byKey(const ValueKey('reach-verdict')), findsOneWidget);

    // Back on the map, it polls again while shown.
    await tester.tap(find.byKey(const ValueKey('hubble-tab-map')));
    await tester.pump();
    expect(fake.mapCalls, 2);
    await tester.pump(mapRefresh);
    expect(fake.mapCalls, 3);
    await tester.pumpWidget(const SizedBox());
  });
}
