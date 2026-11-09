import 'package:flutter/material.dart';

import '../../ui/widgets/common.dart';
import '../../ui/widgets/editorial.dart';
import '../network/widgets.dart';
import '../panel.dart';
import '../pod/pod_widgets.dart';
import 'kyverno_common.dart';

/// Kinds that never get a Policy results tab: Kyverno's own and the
/// reports themselves.
bool _skipKind(String gk) =>
    gk.startsWith('$kyvernoGroup/') || gk.startsWith('$reportGroup/') || gk.startsWith('policies.kyverno.io/') || gk == '/Event' || gk == 'events.k8s.io/Event';

/// The "Policy results" tab for [ctx]'s object, from the cached PolicyReports
/// of its namespace (or the ClusterPolicyReports, for cluster-scoped kinds).
/// Null for kinds that have none or when the cluster serves no reports.
PanelTab? policyResultsTab(PanelContext ctx) {
  if (_skipKind(ctx.type.gk)) return null;
  final resource = ctx.type.namespaced ? 'policyreports' : 'clusterpolicyreports';
  if (ctx.app.typeForResource(reportGroup, resource) == null) return null;
  return PanelTab(
    label: 'Policy results',
    icon: Icons.policy_outlined,
    builder: (context, ctx) => _ObjectResults(key: ValueKey('kyverno-${ctx.uid}'), ctx: ctx, resource: resource),
  );
}

class _ObjectResults extends StatelessWidget {
  final PanelContext ctx;
  final String resource;
  const _ObjectResults({super.key, required this.ctx, required this.resource});

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
        return PageScroll(padding: const EdgeInsets.all(12), children: [
          DetailSection(
            title: 'Policy results',
            icon: Icons.policy_outlined,
            divider: false,
            trailing: RefreshButton(reload),
            child: snap.connectionState != ConnectionState.done
                ? spinner
                : snap.hasError
                    ? Hint('Could not read policy reports: ${snap.error}')
                    : rs!.isEmpty
                        ? const Hint('No policy reports mention this object')
                        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            ResultCounts(rs),
                            const SizedBox(height: 6),
                            ResultsList(rs, showResource: false),
                          ]),
          ),
        ]);
      },
    );
  }
}
