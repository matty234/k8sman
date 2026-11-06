import '../panel.dart';
import 'instance_panel.dart';
import 'monitor_panel.dart';
import 'rule_panel.dart';

/// Panels for the Prometheus Operator (monitoring.coreos.com). Registered by their module in lib/modules.
final List<ResourcePanel> prometheusPanels = [
  const PrometheusRulePanel(),
  const MonitorPanel(),
  const PromInstancePanel(),
];
