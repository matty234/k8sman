import 'package:flutter/material.dart';

import '../gpu/gpu_view.dart';
import '../state/app_state.dart';
import 'module.dart';

/// NVIDIA GPUs: the GPUs page (allocation, DCGM device stats, idle GPUs),
/// shown in the sidebar only on clusters with GPU nodes. The backend's
/// /api/gpu belongs to the same module. (The GPU sections of the Node and
/// Pod panels are part of those core panels.)
class GpusModule extends AppModule {
  const GpusModule();

  static const page = MainView('gpus');

  @override
  String get id => 'gpus';

  @override
  String get name => 'NVIDIA GPUs';

  @override
  List<AppPage> get pages => [
        AppPage(
          view: page,
          icon: Icons.memory,
          label: 'GPUs',
          commands: const ['gpus', 'gpu'],
          after: MainView.nodes,
          navGate: (item) => GpuNavGate(child: item),
          navNote: 'Only on clusters with GPUs',
          builder: (_) => const GpusView(),
        ),
      ];
}
