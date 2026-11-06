import 'package:flutter/material.dart';

import '../metrics/metrics_page.dart';
import '../state/app_state.dart';
import 'module.dart';

/// Metrics: the Metrics page (top, storage, network, custom and external
/// metrics, HPAs). The metrics APIs behind it (/api/metrics/*) stay core:
/// the Nodes page, table usage columns and panels use them too.
class MetricsModule extends AppModule {
  const MetricsModule();

  static const page = MainView('metrics');

  @override
  String get id => 'metrics';

  @override
  String get name => 'Metrics';

  @override
  List<AppPage> get pages => [
        AppPage(
          view: page,
          icon: Icons.query_stats,
          label: 'Metrics',
          commands: const ['metrics'],
          after: MainView.access,
          underMore: true,
          builder: (_) => const MetricsPage(),
        ),
      ];
}
