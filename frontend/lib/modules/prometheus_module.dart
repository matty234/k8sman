import 'package:flutter/widgets.dart';

import '../api/client.dart';
import '../panels/prometheus/index.dart';
import '../prometheus/prom_api.dart';
import '../prometheus/prometheus_settings.dart';
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
  String get description => 'Alerts and the usage charts on pods, nodes and workloads.';

  @override
  List<ResourcePanel> get panels => prometheusPanels;

  @override
  WidgetBuilder get settingsBuilder => (_) => const PrometheusSettingsForm();

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

  /// Discovery's result: which Prometheus (and Alertmanager) was found and
  /// whether it answers. Shared with the alerts badge and the history
  /// charts through [PromApi.discover].
  @override
  Future<ModuleStatus> Function(ApiClient api) get detect => (api) async {
        final s = await PromApi.of(api).discover();
        final prom = s.defaultPrometheus;
        if (prom == null && s.defaultAlertmanager == null) {
          return ModuleStatus(ModuleState.notInstalled, s.operatorCRDs ? 'Operator CRDs installed, no Prometheus found' : 'no Prometheus found');
        }
        if (prom == null) return const ModuleStatus(ModuleState.connected, 'Alertmanager only (no Prometheus found)');
        final label = '${prom.namespace}/${prom.name}${prom.version.isEmpty ? '' : ' ${prom.version}'}';
        if (!prom.reachable) return ModuleStatus(ModuleState.error, '$label · ${prom.error ?? 'not reachable'}');
        return ModuleStatus(ModuleState.connected, [
          label,
          if (s.prometheus.length > 1) '${s.prometheus.length} instances',
          if (s.defaultAlertmanager != null) 'Alertmanager',
        ].join(' · '));
      };
}
