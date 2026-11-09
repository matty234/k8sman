/// Where the Overview's area cards lead: a card title to its kind's table (or
/// page), a row naming one object to that object, a row covering several to
/// the kind's table with the matching filter typed in.
library;

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../api/models.dart';
import '../../state/app_state.dart';
import 'overview_api.dart';
import 'overview_widgets.dart' show openObject;

/// A destination: one [object], a [page], or the table of ([group], [kind])
/// with [filter] (the table's filter language) pre-set.
class OverviewTarget {
  final ObjectRef? object;
  final MainView? page;
  final String group;
  final String kind;
  final String? filter;
  const OverviewTarget.object(ObjectRef this.object)
      : page = null,
        group = '',
        kind = '',
        filter = null;
  const OverviewTarget.page(MainView this.page)
      : object = null,
        group = '',
        kind = '',
        filter = null;
  const OverviewTarget.table(this.group, this.kind, [this.filter])
      : object = null,
        page = null;
}

/// The table filter that selects what a problem category counts, where the
/// kind's columns can say so (`Status` holds the pod's waiting reason, the
/// node's Ready/NotReady, the PVC phase, ...). Categories not listed (no
/// column tells) filter the Issues list instead.
const _categoryFilters = {
  // Pods. `ImagePull` matches both ImagePullBackOff and ErrImagePull, and
  // `Init:` the "Init:<reason>" statuses.
  'crashLoop': 'status=CrashLoopBackOff',
  'imagePull': 'status=ImagePull',
  'createContainerConfigError': 'status=CreateContainerConfigError',
  'initBlocked': 'status=Init:',
  'podFailed': 'status=Failed',
  'stuckPending': 'status=Pending age>5m', // age counts from creation: close enough
  'stuckTerminating': 'status=Terminating',
  'highRestarts': 'restarts>=5', // the backend flags pods at 5 restarts or more
  // Nodes, PVCs, jobs, Argo CD applications.
  'nodeNotReady': 'status=NotReady',
  'nodeCordoned': 'status=SchedulingDisabled',
  'pvcLost': 'status=Lost',
  'pvcPending': 'status=Pending',
  'jobFailed': 'status=Failed',
  'jobLongRunning': 'status=Running age>1h',
  'jobSuspended': 'status=Suspended',
  'argoDegraded': 'health=Degraded',
  'argoMissing': 'health=Missing',
  'argoOutOfSync': 'sync=OutOfSync',
};

String _refKey(OverviewIssue i) => '${i.group}/${i.kind}/${i.namespace}/${i.name}';

/// Where the row for [c] leads, or null to filter the Issues list instead:
/// the object when the row names exactly one, else the table of its kind
/// with [_categoryFilters]' filter.
OverviewTarget? rowTarget(OverviewData data, OverviewCategory c) {
  final issues = [for (final i in data.issues) if (i.category == c.id) i];
  if (issues.isEmpty) return null;
  if (c.count <= 1 && {for (final i in issues) _refKey(i)}.length == 1) return OverviewTarget.object(issues.first.ref);
  final filter = _categoryFilters[c.id];
  final kinds = {for (final i in issues) '${i.group}/${i.kind}'};
  if (filter == null || kinds.length != 1) return null;
  return OverviewTarget.table(issues.first.group, issues.first.kind, filter);
}

/// Where a card's title leads, or null when it has no destination.
OverviewTarget? titleTarget(OverviewData data, String section) {
  final issues = [for (final i in data.issues) if (data.categories.any((c) => c.id == i.category && c.section == section)) i];
  // The kind all the card's problems are about, else the default.
  OverviewTarget table(String group, String kind) {
    final kinds = {for (final i in issues) '${i.group}/${i.kind}'};
    return kinds.length == 1 ? OverviewTarget.table(issues.first.group, issues.first.kind) : OverviewTarget.table(group, kind);
  }

  return switch (section) {
    'pods' => const OverviewTarget.table('', 'Pod'),
    'workloads' => table('apps', 'Deployment'),
    'jobs' => table('batch', 'Job'),
    'nodes' => const OverviewTarget.page(MainView.nodes),
    'storage' => const OverviewTarget.table('', 'PersistentVolumeClaim'),
    'network' => table('gateway.networking.k8s.io', 'Gateway'),
    'argocd' => const OverviewTarget.table('argoproj.io', 'Application'),
    'alerts' => const OverviewTarget.page(MainView.alerts),
    _ => null,
  };
}

/// Goes to [t], showing tables for the Overview's namespace [scope].
/// Returns false when the cluster doesn't serve the kind.
bool openOverviewTarget(BuildContext context, OverviewTarget t, NamespaceScope scope) {
  final app = context.read<AppState>();
  final obj = t.object;
  if (obj != null) {
    if (app.typeFor(obj.group, obj.kind) == null) return false;
    openObject(context, obj);
    return true;
  }
  final page = t.page;
  if (page != null) {
    app.showView(page);
    return true;
  }
  return app.openTable(t.group, t.kind, scope: scope, filter: t.filter);
}
