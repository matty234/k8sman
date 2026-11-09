import 'package:flutter/material.dart';

import '../api/client.dart';
import '../metrics/metrics_api.dart';
import '../metrics/metrics_page.dart';
import '../state/app_state.dart';
import 'module.dart';

/// Metrics: metrics-server status, and the legacy Metrics page (top,
/// storage, network, custom and external metrics). The page is retired:
/// usage lives in the Pods, Nodes and PVC tables, network rates in the
/// inspector and custom/external values in the HPA panel. It stays reachable
/// from ⌘K and `:metrics` for one release, out of the sidebar. The metrics
/// APIs behind it (/api/metrics/*) are core.
class MetricsModule extends AppModule {
  const MetricsModule();

  static const page = MainView('metrics');

  @override
  String get id => 'metrics';

  @override
  String get name => 'Metrics';

  @override
  String get description => 'CPU and memory usage from metrics-server, in the Pods and Nodes tables.';

  @override
  List<AppPage> get pages => [
        AppPage(
          view: page,
          icon: Icons.query_stats,
          label: 'Metrics (legacy)',
          commands: const ['metrics'],
          after: MainView.access,
          inSidebar: false,
          builder: (_) => const MetricsPage(),
        ),
      ];

  /// Whether metrics-server (the resource metrics API) answers, and which
  /// other metrics APIs are served.
  @override
  Future<ModuleStatus> Function(ApiClient api) get detect => (api) async {
        final s = await api.metricsStatus();
        final extra = [if (s.custom.available) 'custom metrics', if (s.external.available) 'external metrics'];
        final more = extra.isEmpty ? '' : ' · ${extra.join(', ')}';
        return switch (s.resource.state) {
          MetricsState.available => ModuleStatus(ModuleState.connected, 'metrics-server available$more'),
          MetricsState.notInstalled => ModuleStatus(ModuleState.notInstalled, 'metrics-server not installed'),
          _ => ModuleStatus(ModuleState.error, 'metrics-server ${s.resource.message ?? s.resource.reason ?? 'not ready'}'),
        };
      };
}
