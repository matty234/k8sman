import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/models.dart';
import '../../panels/panel.dart';
import '../../state/log_dock.dart';
import '../../util/k8s.dart';
import '../keys.dart';

/// Most pods the Argo workflow "Logs" action opens as separate tabs.
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
/// DaemonSet, ReplicaSet, Job) or a Service: one tab merging the logs of all
/// its pods, following them as they come and go.
ResourceAction workloadLogsAction(PanelContext ctx) => ResourceAction(
  id: kLogsActionId,
  label: 'Logs',
  icon: Icons.layers_outlined,
  tooltip: 'Open the merged logs of all its pods in the bottom panel',
  run: (context) async => openWorkloadLogs(context, ctx),
);

const _kindShort = {'Deployment': 'deploy', 'StatefulSet': 'sts', 'DaemonSet': 'ds', 'ReplicaSet': 'rs', 'Job': 'job', 'Service': 'svc'};

/// Opens (or focuses) one aggregated log tab for the pods selected by the
/// workload's (or service's) label selector.
void openWorkloadLogs(BuildContext context, PanelContext ctx) {
  final sel = selectorToString(ctx.spec['selector']);
  if (sel.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('No pod selector')));
    return;
  }
  context.read<LogDock>().openAggregate(ctx.namespace ?? '', selector: sel, title: '${_kindShort[ctx.type.kind] ?? ctx.type.kind.toLowerCase()}/${ctx.name}');
}

/// Opens (or focuses) one aggregated tab for exactly [pods] of [namespace]
/// (two or more selected pod rows).
void openPodsLogs(BuildContext context, String namespace, List<String> pods) {
  context.read<LogDock>().openAggregate(namespace, pods: pods);
}
