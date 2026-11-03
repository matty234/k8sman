import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/models.dart';
import '../../panels/panel.dart';
import '../../panels/pod/pod_logic.dart';
import '../../state/log_dock.dart';
import '../../util/k8s.dart';
import '../keys.dart';

/// Most pods a workload "Logs" action opens at once.
const int kMaxWorkloadLogTabs = 5;

/// Action id for opening logs. The inspector shows it first and keeps it
/// in read-only mode (it doesn't mutate anything).
const String kLogsActionId = 'logs';

/// Opens (or focuses) a log tab for [pod] in the bottom dock.
void openPodLogs(BuildContext context, Json pod, {String? container, bool previous = false}) {
  context.read<LogDock>().open(pod, container: container, previous: previous);
}

/// "Logs" header action for a Pod: opens its default container.
ResourceAction podLogsAction(PanelContext ctx) => ResourceAction(
  id: kLogsActionId,
  label: 'Logs',
  icon: Icons.notes,
  tooltip: 'Open logs in the bottom panel (${shortcutLabel('J')} toggles it)',
  run: (context) async => openPodLogs(context, ctx.object),
);

/// "Logs" header action for a pod controller (Deployment, StatefulSet,
/// DaemonSet, ReplicaSet, Job): one tab per pod for its first container,
/// capped at [kMaxWorkloadLogTabs].
ResourceAction workloadLogsAction(PanelContext ctx) => ResourceAction(
  id: kLogsActionId,
  label: 'Logs',
  icon: Icons.notes,
  tooltip: 'Open logs of up to $kMaxWorkloadLogTabs pods in the bottom panel',
  run: (context) => openWorkloadLogs(context, ctx),
);

Future<void> openWorkloadLogs(BuildContext context, PanelContext ctx) async {
  final dock = context.read<LogDock>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final sel = selectorToString(ctx.spec['selector']);
  if (sel.isEmpty) {
    messenger?.showSnackBar(const SnackBar(content: Text('No pod selector')));
    return;
  }
  List<Json> pods;
  try {
    pods = await ctx.api.items(
      const ResourceRef(resource: 'pods'),
      namespace: ctx.namespace,
      labelSelector: sel,
    );
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('Could not list pods: $e')));
    return;
  }
  // Prefer pods owned by this object when owner refs say so (selectors can overlap).
  final uid = ctx.uid;
  final owned = pods.where((p) => asMapList(dig(p, ['metadata', 'ownerReferences'])).any((r) => r['uid'] == uid)).toList();
  if (owned.isNotEmpty && ctx.type.kind != 'Deployment') pods = owned;
  if (pods.isEmpty) {
    messenger?.showSnackBar(SnackBar(content: Text('${ctx.type.kind} ${ctx.name} has no pods')));
    return;
  }
  int rank(Json p) => switch ('${dig(p, ['status', 'phase'])}') {
    'Running' => 0,
    'Pending' => 2,
    _ => 1,
  };
  pods.sort((a, b) {
    final r = rank(a).compareTo(rank(b));
    return r != 0 ? r : '${dig(a, ['metadata', 'name'])}'.compareTo('${dig(b, ['metadata', 'name'])}');
  });
  final take = pods.take(kMaxWorkloadLogTabs).toList();
  for (final (i, p) in take.indexed) {
    final first = podContainers(p).where((c) => c.kind == ContainerKind.regular).firstOrNull?.name;
    dock.open(p, container: first, focus: i == 0);
  }
  if (pods.length > take.length) {
    messenger?.showSnackBar(SnackBar(content: Text('Opened logs for ${take.length} of ${pods.length} pods')));
  }
}
