import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/api/models.dart';
import 'package:k8sman/metrics/storage_view.dart';
import 'package:k8sman/metrics/volume_usage.dart';
import 'package:k8sman/prometheus/prom_api.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:k8sman/util/k8s.dart';
import 'package:provider/provider.dart';

import '../prometheus/prom_fixtures.dart';
import '../support/harness.dart';
import '../support/screenshot.dart';

Json _json(String path) => jsonDecode(File(path).readAsStringSync()) as Json;

/// Serves `/api/metrics/summary` with one PVC volume.
class _SummaryApi extends FakeApiClient {
  final List<Map<String, String?>> summaryQueries = [];
  _SummaryApi({required super.itemsByResource});

  @override
  Future<Json> metrics(String path, [Map<String, String?> query = const {}]) async {
    if (path == 'volumes') {
      // Merged per claim: Prometheus has scratch, the kubelet has data-redis-0.
      return {
        'prometheus': true,
        'kubelet': 'available',
        'items': [
          {'namespace': 'demo', 'claim': 'data-redis-0', 'source': 'kubelet', 'usedBytes': 966367642, 'capacityBytes': 1073741824},
          {'namespace': 'demo', 'claim': 'scratch', 'source': 'prometheus', 'usedBytes': 107374182, 'capacityBytes': 1073741824},
        ],
      };
    }
    if (path != 'summary') throw UnimplementedError(path);
    summaryQueries.add(query);
    return {
      'state': 'available',
      'nodes': 1,
      'reporting': 1,
      'volumes': [
        {'namespace': 'demo', 'claim': 'data-redis-0', 'pod': 'redis-0', 'node': 'k8sman-dev-control-plane', 'usedBytes': 966367642, 'capacityBytes': 1073741824, 'availableBytes': 107374182, 'inodes': 65536, 'inodesUsed': 536},
      ],
      'pods': [],
      'nodeNetwork': [],
    };
  }
}

void main() {
  testWidgets('usage bar states: thresholds, not mounted, not bound', (tester) async {
    Future<void> pump(PvcUsageState s) => tester.pumpWidget(MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(body: SizedBox(width: 520, child: PvcUsageView(s))),
        ));
    Color? colorOf(String text) => tester.widget<Text>(find.text(text)).style?.color;
    late BuildContext ctx;

    await pump(const PvcUsageKnown(PvcUsage(used: 50, capacity: 100, source: UsageSource.prometheus, daysToFull: 3.4)));
    ctx = tester.element(find.byType(PvcUsageView));
    expect(find.text('50%'), findsOneWidget);
    expect(colorOf('50%'), isNot(severityColor(ctx, Severity.warn)));
    expect(find.textContaining('full in ~3 days'), findsOneWidget);
    expect(find.textContaining('via Prometheus'), findsOneWidget);

    await pump(const PvcUsageKnown(PvcUsage(used: 82, capacity: 100, source: UsageSource.kubelet)));
    expect(colorOf('82%'), severityColor(ctx, Severity.warn));

    await pump(const PvcUsageKnown(PvcUsage(used: 95, capacity: 100, source: UsageSource.kubelet)));
    expect(colorOf('95%'), severityColor(ctx, Severity.error));

    await pump(const PvcUsageNotMounted());
    expect(find.textContaining('Not mounted, usage unknown'), findsOneWidget);

    await pump(const PvcUsageNotMounted(bound: false));
    expect(find.textContaining('Not bound, usage unknown'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('PVC panel falls back to kubelet stats on the mounting pod\'s node', (tester) async {
    PromApi.debugOverride = (_) => FixturePromApi(missing: true);
    addTearDown(() => PromApi.debugOverride = null);
    await loadRealFonts();
    final api = _SummaryApi(itemsByResource: {
      'pods': [_json('test/panels/storage/fixtures/pod-redis-0.json')],
      'persistentvolumeclaims': [_json('../dev/fixtures/pvc-data-redis-0.json')],
    });
    await pumpPanel(tester, _json('../dev/fixtures/pvc-data-redis-0.json'), api: api, size: const Size(560, 1400));
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Usage'), findsOneWidget);
    expect(find.text('90%'), findsOneWidget);
    expect(find.textContaining('via kubelet'), findsOneWidget);
    expect(api.summaryQueries.single['node'], 'k8sman-dev-control-plane');
    await saveScreenshot(tester, 'pvc-usage-kubelet');
  });

  testWidgets('Storage tab merges sources per claim, fullest first; idle claims say not mounted', (tester) async {
    PromApi.debugOverride = (_) => FixturePromApi(missing: true);
    addTearDown(() => PromApi.debugOverride = null);
    await loadRealFonts();
    final pvc = _json('../dev/fixtures/pvc-data-redis-0.json');
    final idle = jsonDecode(jsonEncode(pvc)) as Json;
    idle['metadata']['name'] = 'scratch';
    final unused = jsonDecode(jsonEncode(pvc)) as Json;
    unused['metadata']['name'] = 'unused';
    final pending = jsonDecode(jsonEncode(pvc)) as Json;
    pending['metadata']['name'] = 'waiting';
    pending['status'] = {'phase': 'Pending'};
    final api = _SummaryApi(itemsByResource: {'persistentvolumeclaims': [idle, unused, pending, pvc]});
    final app = AppState(api)..types = testTypes;
    tester.view.physicalSize = const Size(900, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MultiProvider(
      providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
      child: MaterialApp(theme: buildTheme(Brightness.dark), home: const Scaffold(body: StorageView(scope: NamespaceScope.all))),
    ));
    await tester.pump(const Duration(milliseconds: 50));

    double y(String text) => tester.getTopLeft(find.textContaining(text).first).dy;
    expect(find.text('90%'), findsOneWidget);
    expect(find.text('10%'), findsOneWidget);
    expect(find.text('not mounted'), findsOneWidget);
    expect(find.text('pending'), findsOneWidget);
    expect(y('data-redis-0'), lessThan(y('scratch')));
    expect(y('scratch'), lessThan(y('unused')));
    expect(find.text('usage via Prometheus (1) and kubelet stats (1)'), findsOneWidget);
    await saveScreenshot(tester, 'metrics-storage');

    await tester.tap(find.textContaining('data-redis-0'));
    await tester.pump();
    expect(app.detail?.name, 'data-redis-0');
    expect(app.detail?.type.kind, 'PersistentVolumeClaim');
  });
}
