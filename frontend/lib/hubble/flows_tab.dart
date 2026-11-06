import 'package:flutter/material.dart';

import '../panels/panel.dart';
import '../util/k8s.dart';
import 'flow_list.dart';
import 'hubble_api.dart';

/// Kinds that get a Flows tab, as `group/Kind`.
const flowKinds = {
  '/Pod',
  '/Service',
  '/Namespace',
  'apps/Deployment',
  'apps/StatefulSet',
  'apps/DaemonSet',
  'apps/ReplicaSet',
  'batch/Job',
  'batch/CronJob',
};

/// The flows of the inspector's object, or null for kinds without flows.
///
/// Workloads are matched by their selector's matchLabels (Cilium keeps
/// those in pod identities), within their namespace. Jobs and CronJobs,
/// whose selectors use labels Cilium leaves out of identities, and
/// workloads without matchLabels, are matched by pod name prefix.
FlowQuery? flowQueryFor(PanelContext ctx) {
  final ns = ctx.namespace;
  final name = ctx.name;
  switch (ctx.type.gk) {
    case '/Pod':
      return FlowQuery(pod: '$ns/$name');
    case '/Service':
      return FlowQuery(service: '$ns/$name');
    case '/Namespace':
      return FlowQuery(namespaces: [name]);
    case 'batch/Job' || 'batch/CronJob':
      return FlowQuery(pod: '$ns/$name-');
    case 'apps/Deployment' || 'apps/StatefulSet' || 'apps/DaemonSet' || 'apps/ReplicaSet':
      final labels = asMap(dig<Object>(ctx.spec, ['selector', 'matchLabels']));
      if (labels.isEmpty) return FlowQuery(pod: '$ns/$name-');
      final sel = (labels.entries.map((e) => '${e.key}=${e.value}').toList()..sort()).join(',');
      return FlowQuery(namespaces: [?ns], labels: sel);
  }
  return null;
}

/// The inspector's Flows tab for [ctx]'s object.
PanelTab? flowsTab(PanelContext ctx) {
  final q = flowQueryFor(ctx);
  if (q == null) return null;
  return PanelTab(
    label: 'Flows',
    icon: Icons.swap_horiz,
    builder: (context, ctx) => FlowStreamView(
      key: ValueKey('flows-${ctx.uid}'),
      query: q,
      api: HubbleApi.of(ctx.api),
      compact: true,
      emptyHint: 'No flows for this ${ctx.type.kind} yet. Hubble shows traffic as it happens; recent history is limited by the relay\'s buffer.',
    ),
  );
}
