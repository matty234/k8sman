import 'package:flutter/material.dart';

import '../api/client.dart';
import '../api/models.dart';
import '../panels/kyverno/index.dart';
import 'module.dart';
import '../ui/security/security_tab.dart' show securityTabKinds;
import 'modules.dart' show moduleEnabled, moduleStatuses;

/// Kyverno: policies, exceptions, cleanup policies and the standard policy
/// reports (wgpolicyk8s.io) Kyverno writes. Adds panels for policies and
/// reports, and a "Policy results" tab on any object the reports mention.
/// No backend part: the table columns are the backend's built-in defaults.
/// The sidebar section lists only the kinds the cluster serves.
class KyvernoModule extends AppModule {
  const KyvernoModule();

  @override
  String get id => 'kyverno';

  @override
  String get name => 'Kyverno';

  @override
  String get description => 'Policies, exceptions and policy reports (kyverno.io, wgpolicyk8s.io), with policy results on any object.';

  @override
  List<ResourcePanel> get panels => kyvernoPanels;

  @override
  List<NavGroup> get navGroups => const [
        NavGroup(after: 'Access Control', 'Kyverno', [
          'kyverno.io/ClusterPolicy',
          'kyverno.io/Policy',
          'policies.kyverno.io/ValidatingPolicy',
          'policies.kyverno.io/ImageValidatingPolicy',
          'policies.kyverno.io/MutatingPolicy',
          'policies.kyverno.io/GeneratingPolicy',
          'policies.kyverno.io/DeletingPolicy',
          'kyverno.io/PolicyException',
          'policies.kyverno.io/PolicyException',
          'kyverno.io/CleanupPolicy',
          'kyverno.io/ClusterCleanupPolicy',
          'kyverno.io/UpdateRequest',
          'wgpolicyk8s.io/PolicyReport',
          'wgpolicyk8s.io/ClusterPolicyReport',
        ]),
      ];

  @override
  Map<String, IconData> get kindIcons => const {
        'kyverno.io/ClusterPolicy': Icons.policy_outlined,
        'kyverno.io/Policy': Icons.policy_outlined,
        'policies.kyverno.io/ValidatingPolicy': Icons.rule,
        'policies.kyverno.io/ImageValidatingPolicy': Icons.verified_outlined,
        'policies.kyverno.io/MutatingPolicy': Icons.edit_note,
        'policies.kyverno.io/GeneratingPolicy': Icons.auto_awesome_outlined,
        'policies.kyverno.io/DeletingPolicy': Icons.delete_sweep_outlined,
        'kyverno.io/PolicyException': Icons.gpp_maybe_outlined,
        'policies.kyverno.io/PolicyException': Icons.gpp_maybe_outlined,
        'kyverno.io/CleanupPolicy': Icons.cleaning_services_outlined,
        'kyverno.io/ClusterCleanupPolicy': Icons.cleaning_services_outlined,
        'kyverno.io/UpdateRequest': Icons.sync_alt,
        'wgpolicyk8s.io/PolicyReport': Icons.fact_check_outlined,
        'wgpolicyk8s.io/ClusterPolicyReport': Icons.fact_check_outlined,
      };

  /// The kyverno.io policy CRDs are served; the line counts ClusterPolicies
  /// and Policies and sums the failures in the reports.
  @override
  Future<ModuleStatus> Function(ApiClient api) get detect => (api) async {
        final types = await api.resources();
        ResourceType? find(String group, String resource) => types.where((t) => t.group == group && t.resource == resource).firstOrNull;
        final policyTypes = [for (final r in const ['clusterpolicies', 'policies']) ?find('kyverno.io', r)];
        if (policyTypes.isEmpty) return const ModuleStatus(ModuleState.notInstalled, 'kyverno.io CRDs not served');
        // Policies only: summing PolicyReports would mean listing (and
        // watching) every report in the cluster, often one per resource.
        try {
          var policies = 0;
          for (final t in policyTypes) {
            policies += (await api.items(t.ref)).length;
          }
          return ModuleStatus(ModuleState.connected, '$policies ${policies == 1 ? 'policy' : 'policies'}');
        } catch (e) {
          return ModuleStatus(ModuleState.connected, 'CRDs served · cannot list policies ($e)');
        }
      };

  @override
  List<PanelTab> inspectorTabs(PanelContext ctx) {
    // Only where Kyverno is found (detection runs once per context). Pods
    // and workloads show their results in the Security tab instead.
    if (securityTabKinds.contains(ctx.type.gk) || !kyvernoConnected(ctx)) return const [];
    final tab = policyResultsTab(ctx);
    return tab == null ? const [] : [tab];
  }
}

/// Whether the Kyverno module is on and found on [ctx]'s cluster.
bool kyvernoConnected(PanelContext ctx) {
  const m = KyvernoModule();
  if (!moduleEnabled(m.id, ctx.app.disabledModules)) return false;
  final s = moduleStatuses.of(m, ctx.api, ctx.app.currentContext);
  return s != null && s.state == ModuleState.connected;
}
