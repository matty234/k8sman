import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:k8sman/api/client.dart';
import 'package:k8sman/gpu/gpu_api.dart';
import 'package:k8sman/gpu/gpu_view.dart';
import 'package:k8sman/prometheus/prom_api.dart';
import 'package:k8sman/modules/gpus_module.dart';
import 'package:k8sman/state/app_state.dart';
import 'package:k8sman/ui/theme.dart';
import 'package:provider/provider.dart';

import '../prometheus/prom_fixtures.dart';
import '../support/harness.dart';

/// /api/gpu as the backend builds it from backend/internal/gpu/testdata
/// (two GPU nodes, one without an exporter; devices attributed to pods).
Map<String, dynamic> _inventoryJson() => jsonDecode(File('test/gpu/fixtures/gpu.json').readAsStringSync());

class _FixtureGpuApi extends GpuApi {
  _FixtureGpuApi(super.api);
  @override
  Future<GpuInventory> inventory({bool live = true, bool refresh = false}) async => GpuInventory.fromJson(_inventoryJson());
}

/// Prometheus with a reachable instance; range queries return a gentle
/// synthetic curve per device (or per breakdown label).
class _GpuPromApi extends PromApi {
  final List<String> queries = [];
  _GpuPromApi() : super(ApiClient(base: Uri.parse('http://fake')));

  @override
  Future<dynamic> getJson(String path, [Map<String, String?> query = const {}]) async {
    if (path == 'status') return promFixture('status');
    if (path != 'query_range') throw ApiException(404, 'no fixture for $path');
    final q = query['query'] ?? '';
    queries.add(q);
    final keys = q.contains('by (UUID)')
        ? ['GPU-11111111-aaaa-bbbb-cccc-000000000000', 'GPU-22222222-aaaa-bbbb-cccc-000000000000', 'GPU-33333333-aaaa-bbbb-cccc-000000000000']
        : (q.contains('by (gpu)') ? ['0', '1', '2'] : ['']);
    final label = q.contains('by (UUID)') ? 'UUID' : 'gpu';
    final now = DateTime.now().millisecondsSinceEpoch / 1000;
    final scale = q.contains('UTIL') ? 1.0 : (q.contains('FB_USED') ? 18e9 : (q.contains('TEMP') ? 70.0 : 130.0));
    return {
      'resultType': 'matrix',
      'series': keys.length,
      'result': [
        for (final (i, k) in keys.indexed)
          {
            'metric': k.isEmpty ? {} : {label: k},
            'values': [
              for (var t = 0; t < 60; t++)
                [now - (60 - t) * 60, '${i == 0 ? scale * (0.55 + 0.3 * math.sin(t / 7)) : (i == 1 ? 0 : scale * 0.05)}'],
            ],
          },
      ],
    };
  }
}

Future<void> _pumpView(WidgetTester tester, Size size, {Brightness brightness = Brightness.dark}) async {
  final api = FakeApiClient();
  final app = AppState(api)
    ..types = testTypes
    ..currentContext = 'gpu-cluster'
    ..view = GpusModule.page;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(brightness), home: const Scaffold(body: GpusView())),
  ));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 50));
}

void main() {
  late _GpuPromApi prom;
  setUp(() {
    prom = _GpuPromApi();
    GpuApi.debugOverride = (api) => _FixtureGpuApi(api);
    PromApi.debugOverride = (_) => prom;
  });
  tearDown(() {
    GpuApi.debugOverride = null;
    PromApi.debugOverride = null;
  });

  testWidgets('GPUs page renders nodes, devices and callouts without overflow', (tester) async {
    addTearDown(tester.view.reset);
    for (final w in [480.0, 760.0, 1180.0]) {
      await _pumpView(tester, Size(w, 1000));
      expect(tester.takeException(), isNull, reason: 'overflow at width $w');
    }
    expect(find.text('gpu-node-a'), findsOneWidget);
    expect(find.text('No exporter'), findsOneWidget);
    expect(find.text('Waiting for GPUs'), findsOneWidget);
    expect(find.byTooltip('1 allocated GPU idle for the last hour'), findsOneWidget);
    expect(find.text('trainer-0'), findsWidgets);
    // One range query feeds every sparkline.
    expect(prom.queries.where((q) => q.contains('by (UUID)')), isNotEmpty);
    await tester.pumpWidget(const SizedBox()); // dispose the poll timer
  });

}
