import 'package:flutter/material.dart';

import '../api/client.dart';
import '../gpu/gpu_api.dart';
import '../gpu/gpu_view.dart';
import '../state/app_state.dart';
import 'module.dart';
import 'module_nav_gate.dart';

/// NVIDIA GPUs: the GPUs page (allocation, DCGM device stats, idle GPUs),
/// shown in the sidebar only on clusters with GPU nodes. The backend's
/// /api/gpu belongs to the same module. (The GPU sections of the Node and
/// Pod panels are part of those core panels, and follow [detect] too.)
class GpusModule extends AppModule {
  const GpusModule();

  static const page = MainView('gpus');

  @override
  String get id => 'gpus';

  @override
  String get name => 'NVIDIA GPUs';

  @override
  String get description => 'The GPUs page and GPU columns on nodes and pods.';

  @override
  List<AppPage> get pages => [
        AppPage(
          view: page,
          icon: Icons.memory,
          label: 'GPUs',
          commands: const ['gpus', 'gpu'],
          after: MainView.nodes,
          navGate: (item) => ModuleNavGate(module: this, showOnError: false, child: item),
          navNote: 'Only on clusters with GPUs',
          builder: (_) => const GpusView(),
        ),
      ];

  /// GPU nodes first (allocation only, no Prometheus); the DCGM check
  /// follows only when there are some.
  @override
  Future<ModuleStatus> Function(ApiClient api) get detect => (api) async {
        final gpus = GpuApi.of(api);
        final nodes = (await gpus.inventory(live: false)).nodes.length;
        if (nodes == 0) return const ModuleStatus(ModuleState.notInstalled, 'no GPU nodes');
        final inv = await gpus.inventory();
        final what = '$nodes GPU node${nodes == 1 ? '' : 's'}';
        return ModuleStatus(ModuleState.connected, switch (inv.monitoring) {
          GpuMonitoring.dcgm => '$what · DCGM metrics',
          GpuMonitoring.noExporter => '$what · no DCGM exporter',
          GpuMonitoring.noPrometheus => '$what · no Prometheus',
          GpuMonitoring.error => '$what · metrics unavailable',
          GpuMonitoring.skipped => what,
        });
      };
}
