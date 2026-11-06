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
import '../support/screenshot.dart';

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

Future<void> _pumpView(WidgetTester tester, Size size) async {
  final api = FakeApiClient();
  final app = AppState(api)
    ..types = testTypes
    ..currentContext = 'gpu-cluster'
    ..view = GpusModule.page;
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  await tester.pumpWidget(MultiProvider(
    providers: [Provider<ApiClient>.value(value: api), ChangeNotifierProvider<AppState>.value(value: app)],
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(Brightness.dark), home: const Scaffold(body: GpusView())),
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

  test('inventory parses the backend payload', () {
    final inv = GpuInventory.fromJson(_inventoryJson());
    expect(inv.live, isTrue);
    expect(inv.attribution, isTrue);
    expect(inv.nodes.map((n) => n.name), ['gpu-node-a', 'gpu-node-b']);
    final b = inv.node('gpu-node-b')!;
    expect(b.devices, hasLength(3));
    expect(b.devices[1].idle, isTrue);
    expect(b.devices[0].pods.single.name, 'trainer-0');
    expect(b.devices[0].memTotal, greaterThan(b.devices[0].memUsed!));
    expect(inv.pod('ml', 'trainer-0')!.selector, contains('exported_pod="trainer-0"'));
    expect(inv.node('gpu-node-a')!.monitored, isFalse);
  });

  testWidgets('GPUs page renders nodes, devices and callouts without overflow', (tester) async {
    await loadRealFonts();
    addTearDown(tester.view.reset);
    for (final w in [480.0, 760.0, 1180.0]) {
      await _pumpView(tester, Size(w, 1000));
      expect(tester.takeException(), isNull, reason: 'overflow at width $w');
      if (w == 1180) await saveScreenshot(tester, 'gpus-${w.toInt()}');
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

  testWidgets('GPUs table: device sub-rows collapse and expand with their node', (tester) async {
    await loadRealFonts();
    addTearDown(tester.view.reset);
    await _pumpView(tester, const Size(1200, 800));
    await saveScreenshot(tester, 'gpus-1200x800');
    expect(find.text('GPU 1'), findsOneWidget);
    expect(find.text('Idle'), findsOneWidget);
    expect(find.text('4 × Tesla V100 SXM2 32GB · no live stats'), findsOneWidget);
    await tester.tap(find.byIcon(Icons.expand_more).at(1)); // gpu-node-b's chevron
    await tester.pump();
    expect(find.text('GPU 1'), findsNothing);
    await tester.tap(find.byIcon(Icons.chevron_right).first);
    await tester.pump();
    expect(find.text('GPU 1'), findsOneWidget);
    await _pumpView(tester, const Size(800, 600));
    expect(tester.takeException(), isNull);
    await saveScreenshot(tester, 'gpus-800x600');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('node panel shows the GPU section and history; pod panel its GPUs', (tester) async {
    await loadRealFonts();
    final node = {
      'apiVersion': 'v1',
      'kind': 'Node',
      'metadata': {'name': 'gpu-node-b', 'uid': 'n1', 'labels': {'nvidia.com/gpu.product': 'NVIDIA-RTX-PRO-4000-Blackwell'}},
      'spec': {},
      'status': {
        'capacity': {'cpu': '94', 'memory': '990485244Ki', 'nvidia.com/gpu': '3', 'pods': '110'},
        'allocatable': {'cpu': '93300m', 'memory': '984193788Ki', 'nvidia.com/gpu': '3', 'pods': '110'},
        'conditions': [{'type': 'Ready', 'status': 'True'}],
      },
    };
    await pumpPanel(tester, node, size: const Size(560, 2600));
    expect(find.text('GPUs'), findsOneWidget);
    expect(find.text('GPU history'), findsOneWidget);
    expect(find.text('2/3 allocated'), findsOneWidget);
    expect(prom.queries.any((q) => q.contains('DCGM_FI_DEV_GPU_UTIL{UUID=~"GPU-11111111')), isTrue);
    await saveScreenshot(tester, 'gpu-node-panel');

    final pod = {
      'apiVersion': 'v1',
      'kind': 'Pod',
      'metadata': {'name': 'trainer-0', 'namespace': 'ml', 'uid': 'p1'},
      'spec': {
        'nodeName': 'gpu-node-b',
        'containers': [
          {'name': 'train', 'image': 'trainer:1', 'resources': {'limits': {'nvidia.com/gpu': '2'}}},
        ],
      },
      'status': {'phase': 'Running'},
    };
    await pumpPanel(tester, pod, size: const Size(560, 2600));
    expect(find.text('2 GPUs'), findsOneWidget);
    expect(find.text('GPU history'), findsOneWidget);
    expect(prom.queries.any((q) => q.contains('exported_pod="trainer-0"')), isTrue);

    // A pod without GPUs gets no section.
    await pumpPanel(tester, {...pod, 'spec': {'containers': [{'name': 'web', 'image': 'nginx'}]}}, size: const Size(560, 1600));
    expect(find.text('GPU history'), findsNothing);
  });
}
