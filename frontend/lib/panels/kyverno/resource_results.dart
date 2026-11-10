import 'package:flutter/material.dart';

import '../../ui/widgets/common.dart';
import '../../ui/widgets/editorial.dart';
import '../panel.dart';
import 'kyverno_common.dart';
import '../../ui/widgets/atoms.dart';

/// Kinds that never get a Policy results tab: Kyverno's own and the
/// reports themselves.
bool _skipKind(String gk) =>
    gk.startsWith('$kyvernoGroup/') || gk.startsWith('$reportGroup/') || gk.startsWith('policies.kyverno.io/') || gk == '/Event' || gk == 'events.k8s.io/Event';

/// The policy report resource for [ctx]'s kind (`policyreports`, or
/// `clusterpolicyreports` for cluster-scoped kinds), or null for kinds that
/// have none or when the cluster serves no reports.
String? policyReportResource(PanelContext ctx) {
  if (_skipKind(ctx.type.gk)) return null;
  final resource = ctx.type.namespaced ? 'policyreports' : 'clusterpolicyreports';
  return ctx.app.typeForResource(reportGroup, resource) == null ? null : resource;
}

/// The "Policy results" tab for [ctx]'s object, from the cached PolicyReports
/// of its namespace (or the ClusterPolicyReports, for cluster-scoped kinds).
/// Null for kinds that have none or when the cluster serves no reports.
PanelTab? policyResultsTab(PanelContext ctx) {
  final resource = policyReportResource(ctx);
  if (resource == null) return null;
  return PanelTab(
    label: 'Policy results',
    icon: Icons.policy_outlined,
    builder: (context, ctx) => ObjectPolicyResults(
      key: ValueKey('kyverno-${ctx.uid}'),
      ctx: ctx,
      resource: resource,
      wrap: (content, reload) => PageScroll(padding: const EdgeInsets.all(12), children: [
        DetailSection(title: 'Policy results', icon: Icons.policy_outlined, divider: false, trailing: RefreshButton(reload), child: content),
      ]),
    ),
  );
}

/// The policy results that mention [ctx]'s object (counts, then the list),
/// placed by [wrap] with a reload callback: the Policy results tab, or a
/// section of another tab (Security).
class ObjectPolicyResults extends StatelessWidget {
  final PanelContext ctx;
  final String resource;
  final Widget Function(Widget content, VoidCallback reload) wrap;
  const ObjectPolicyResults({super.key, required this.ctx, required this.resource, required this.wrap});

  @override
  Widget build(BuildContext context) {
    return NetFetch<List<PolicyResult>>(
      fetchKey: ctx.uid,
      load: () async => resultsForObject(
        await cachedReports(ctx.api, ctx.app, resource, namespace: ctx.namespace),
        uid: ctx.uid,
        kind: ctx.type.kind,
        name: ctx.name,
        namespace: ctx.namespace,
      ),
      builder: (context, snap, reload) {
        final rs = snap.data;
        return wrap(
          snap.connectionState != ConnectionState.done
              ? SectionSpinner()
              : snap.hasError
                  ? HintText('Could not read policy reports: ${snap.error}')
                  : rs!.isEmpty
                      ? const HintText('No policy reports mention this object')
                      : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                          ResultCounts(rs),
                          const SizedBox(height: 6),
                          ResultsList(rs, showResource: false),
                        ]),
          reload,
        );
      },
    );
  }
}
