import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../panels/panel.dart';
import '../../state/log_dock.dart';
import '../../util/k8s.dart';
import '../keys.dart';

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

/// Whether [kind] is a pod controller or Service whose pods [openWorkloadLogs]
/// can merge.
bool hasWorkloadLogs(String kind) => _kindShort.containsKey(kind);

String _shortKind(String kind) => _kindShort[kind] ?? kind.toLowerCase();

/// Opens (or focuses) one aggregated log tab for the pods selected by the
/// workload's (or service's) label selector. [allContainers] streams every
/// container of each pod instead of its default one.
void openWorkloadLogs(BuildContext context, PanelContext ctx, {bool? allContainers}) {
  final sel = selectorToString(ctx.spec['selector']);
  if (sel.isEmpty) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(const SnackBar(content: Text('No pod selector')));
    return;
  }
  context.read<LogDock>().openAggregate(ctx.namespace ?? '', selector: sel, title: '${_shortKind(ctx.type.kind)}/${ctx.name}', allContainers: allContainers);
}

/// One merged tab per namespace for the pods of several [rows] of the same
/// workload [type]: their selectors are unioned on the backend.
Future<void> openWorkloadsLogs(BuildContext context, ResourceType type, List<TableRowData> rows, {bool? allContainers}) async {
  final api = context.read<ApiClient>();
  final dock = context.read<LogDock>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  final byNs = <String, List<Json>>{};
  try {
    final objects = await Future.wait([for (final r in rows) api.object(type.ref, namespace: type.namespaced ? r.namespace : null, name: r.name)]);
    for (final o in objects) {
      (byNs[dig<String>(o, ['metadata', 'namespace']) ?? ''] ??= []).add(o);
    }
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('Could not read the selected ${type.resource}: $e')));
    return;
  }
  var opened = 0;
  for (final e in byNs.entries) {
    final sels = [for (final o in e.value) selectorToString(asMap(o['spec'])['selector'])].where((s) => s.isNotEmpty).toSet().toList();
    if (sels.isEmpty) continue;
    final names = [for (final o in e.value) '${dig(o, ['metadata', 'name'])}'];
    final title = '${_shortKind(type.kind)}/${names.first}${names.length > 1 ? ' +${names.length - 1}' : ''}';
    dock.openAggregate(e.key, selectors: sels, title: title, allContainers: allContainers);
    opened++;
  }
  if (opened == 0) messenger?.showSnackBar(const SnackBar(content: Text('No pod selector')));
}

/// Opens (or focuses) one aggregated tab for exactly [pods] of [namespace]
/// (two or more selected pod rows).
void openPodsLogs(BuildContext context, String namespace, List<String> pods) {
  context.read<LogDock>().openAggregate(namespace, pods: pods);
}
