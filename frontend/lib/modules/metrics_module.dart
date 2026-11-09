import '../api/client.dart';
import '../metrics/metrics_api.dart';
import 'module.dart';

/// Metrics: metrics-server status. Usage shows in the Pods, Nodes and PVC
/// tables, network rates in the inspector and custom/external metric values
/// in the HPA panel; the metrics APIs behind them (/api/metrics/*) are core.
class MetricsModule extends AppModule {
  const MetricsModule();

  @override
  String get id => 'metrics';

  @override
  String get name => 'Metrics';

  @override
  String get description => 'CPU and memory usage from metrics-server, in the Pods and Nodes tables.';

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
