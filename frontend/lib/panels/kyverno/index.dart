import '../panel.dart';
import 'policy_panel.dart';
import 'report_panel.dart';

export 'resource_results.dart' show ObjectPolicyResults, policyReportResource, policyResultsTab;

/// Panels of Kyverno and the policy-report CRDs. Registered by their module
/// in lib/modules; the other kinds use the generic panel.
final List<ResourcePanel> kyvernoPanels = [
  const KyvernoPolicyPanel(),
  const PolicyReportPanel(),
];
