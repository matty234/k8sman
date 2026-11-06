import '../panels/prometheus/index.dart';
import 'module.dart';

/// Prometheus Operator: Prometheus, Alertmanager, PrometheusRule and
/// monitor panels (live rule and target state) and the Monitoring sidebar
/// section (see docs/PROMETHEUS.md). The backend's /api/prom/* and the
/// alerts in the overview belong to the same module.
///
/// The Alerts dock pane and the history charts in core panels also read
/// /api/prom; they are core and show "no Prometheus" while this is off.
class PrometheusModule extends AppModule {
  const PrometheusModule();

  @override
  String get id => 'prometheus';

  @override
  String get name => 'Prometheus';

  @override
  List<ResourcePanel> get panels => prometheusPanels;

  @override
  List<NavGroup> get navGroups => const [
        NavGroup(after: 'Config', 'Monitoring', [
          'monitoring.coreos.com/PrometheusRule',
          'monitoring.coreos.com/ServiceMonitor',
          'monitoring.coreos.com/PodMonitor',
          'monitoring.coreos.com/Prometheus',
          'monitoring.coreos.com/Alertmanager',
        ]),
      ];
}
