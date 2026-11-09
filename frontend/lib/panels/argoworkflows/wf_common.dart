/// Shared Argo Workflows helpers: refs, phase styling, durations, the
/// argo-server status API, step pod lookup and workflow list rows.
library;

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../../api/backend_http.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/log_dock.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../argocd/argo_common.dart' show ArgoStyle;
import 'wf_graph.dart';

const wfGroup = 'argoproj.io';
const workflowsRef = ResourceRef(group: wfGroup, resource: 'workflows');
const podsRef = ResourceRef(resource: 'pods');

const labelWorkflow = 'workflows.argoproj.io/workflow';
const labelCronWorkflow = 'workflows.argoproj.io/cron-workflow';
const labelWorkflowTemplate = 'workflows.argoproj.io/workflow-template';
const labelClusterWorkflowTemplate = 'workflows.argoproj.io/cluster-workflow-template';
const labelResubmittedFrom = 'workflows.argoproj.io/resubmitted-from-workflow';
const labelCreator = 'workflows.argoproj.io/creator';
const annotationNodeId = 'workflows.argoproj.io/node-id';
const annotationNodeName = 'workflows.argoproj.io/node-name';
const annotationPodNameFormat = 'workflows.argoproj.io/pod-name-format';

// ---------------------------------------------------------------------------
// Phases
// ---------------------------------------------------------------------------

Color _pick(BuildContext context, int dark, int light) => Color(Theme.of(context).brightness == Brightness.dark ? dark : light);

/// Style of a workflow or node phase (Argo UI colours).
ArgoStyle wfPhaseStyle(BuildContext context, String? phase) => switch (phase) {
      'Succeeded' => ArgoStyle(Icons.check_circle, _pick(context, 0xFF18BE94, 0xFF0E8F6E), Severity.ok),
      'Running' => ArgoStyle(Icons.play_circle, _pick(context, 0xFF0DADEA, 0xFF0A7FB0), Severity.info),
      'Pending' => ArgoStyle(Icons.schedule, _pick(context, 0xFF9AA6AF, 0xFF6B7780), Severity.neutral),
      'Suspended' => ArgoStyle(Icons.pause_circle, _pick(context, 0xFFB79CF0, 0xFF6A4FB0), Severity.warn),
      'Failed' || 'Error' => ArgoStyle(Icons.cancel, _pick(context, 0xFFE96D76, 0xFFC93A45), Severity.error),
      'Skipped' || 'Omitted' => ArgoStyle(Icons.remove_circle_outline, _pick(context, 0xFF7E8A93, 0xFF8A949C), Severity.neutral),
      _ => ArgoStyle(Icons.help_outline, _pick(context, 0xFF9AA6AF, 0xFF6B7780), Severity.neutral),
    };

/// The phase shown for a workflow: "Suspended" while running but suspended.
String workflowPhase(Json wf) {
  final p = dig<String>(wf, ['status', 'phase']) ?? '';
  if (p.isEmpty) return 'Pending';
  if (p == 'Running' && workflowSuspended(wf)) return 'Suspended';
  return p;
}

/// spec.suspend, or a suspend step waiting for resume.
bool workflowSuspended(Json wf) {
  if (dig(wf, ['spec', 'suspend']) == true) return true;
  return asMap(dig(wf, ['status', 'nodes'])).values.any((n) => n is Map && n['type'] == 'Suspend' && n['phase'] == 'Running');
}

bool workflowCompleted(Json wf) => const {'Succeeded', 'Failed', 'Error'}.contains(dig<String>(wf, ['status', 'phase']));

/// Small phase pill: icon + text, or just the icon.
class PhaseBadge extends StatelessWidget {
  final String phase;
  final bool large;
  final bool iconOnly;
  const PhaseBadge(this.phase, {super.key, this.large = false, this.iconOnly = false});

  @override
  Widget build(BuildContext context) {
    final s = wfPhaseStyle(context, phase);
    final theme = Theme.of(context);
    if (iconOnly) return Tooltip(message: phase, child: Icon(s.icon, size: 14, color: s.color));
    if (!large) {
      return Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(s.icon, size: 13, color: s.color),
        const SizedBox(width: 4),
        Flexible(child: Text(phase, maxLines: 1, overflow: TextOverflow.ellipsis, style: theme.textTheme.bodySmall?.copyWith(color: s.color, fontWeight: FontWeight.w500))),
      ]);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(7, 3, 9, 3),
      decoration: BoxDecoration(color: s.color.withValues(alpha: theme.brightness == Brightness.dark ? 0.16 : 0.12), borderRadius: BorderRadius.circular(6)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(s.icon, size: 16, color: s.color),
        const SizedBox(width: 6),
        Text(phase, style: theme.textTheme.bodyMedium?.copyWith(color: s.color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

// ---------------------------------------------------------------------------
// Durations
// ---------------------------------------------------------------------------

/// Run time of something with startedAt/finishedAt (running: until [now]).
Duration? runDuration(dynamic startedAt, dynamic finishedAt, {DateTime? now}) {
  final s = parseTime(startedAt);
  if (s == null) return null;
  final e = parseTime(finishedAt) ?? (now ?? DateTime.now()).toUtc();
  final d = e.difference(s);
  return d.isNegative ? Duration.zero : d;
}

/// `resourcesDuration` ({cpu: 12, memory: 30, nvidia.com/gpu: 4}) as
/// "12s cpu · 30s memory".
String formatResourcesDuration(dynamic rd) {
  final m = asMap(rd);
  if (m.isEmpty) return '';
  return [
    for (final e in m.entries)
      if (e.value is num) '${formatDuration(Duration(seconds: (e.value as num).toInt()), style: DurationStyle.padded)} ${e.key}',
  ].join(' · ');
}

// ---------------------------------------------------------------------------
// argo-server status
// ---------------------------------------------------------------------------

/// GET /api/argowf/status.
class ArgoWFStatus {
  /// The Workflow CRD is served (Argo Workflows is on this cluster).
  final bool crd;
  final bool found;
  final bool reachable;
  final bool available;

  /// "server" (argo-server's service account) or "client" (your token).
  final String auth;
  final String? subject;
  final String? version;
  final String? serverNamespace;
  final String? error;
  const ArgoWFStatus({this.crd = true, this.found = false, this.reachable = false, this.available = false, this.auth = '', this.subject, this.version, this.serverNamespace, this.error});

  factory ArgoWFStatus.fromJson(Json j) => ArgoWFStatus(
        crd: j['crd'] != false,
        found: j['found'] == true,
        reachable: j['reachable'] == true,
        available: j['available'] == true,
        auth: '${j['auth'] ?? ''}',
        subject: j['subject'] as String?,
        version: dig<String>(j, ['server', 'version']),
        serverNamespace: dig<String>(j, ['server', 'namespace']),
        error: j['error'] as String?,
      );

  String get authLabel => switch (auth) {
        'server' => 'server auth mode: actions run as ${subject ?? 'its service account'}',
        'client' => 'client auth mode: actions run as ${subject ?? 'you'}',
        _ => 'not usable',
      };
}

/// `/api/argowf/*`, with the status cached per kube context for 30s.
class ArgoWFApi {
  final ApiClient api;
  final BackendHttp _http;
  ArgoWFApi(this.api, {http.Client? httpClient}) : _http = BackendHttp(api, '/api/argowf/', httpClient: httpClient);

  /// Tests replace this to serve a canned status.
  static final _of = PerApi(ArgoWFApi.new);
  static set debugOverride(ArgoWFApi Function(ApiClient api)? f) => _of.debugOverride = f;
  static ArgoWFApi of(ApiClient api) => _of(api);

  final Map<String, (DateTime, Future<ArgoWFStatus>)> _cache = {};

  /// The cached status for [context], if fetched and still fresh.
  ArgoWFStatus? cached(String context) => _last[context];
  final Map<String, ArgoWFStatus> _last = {};

  Future<ArgoWFStatus> status(String context, {bool refresh = false}) {
    final hit = _cache[context];
    if (!refresh && hit != null && DateTime.now().difference(hit.$1) < const Duration(seconds: 30)) return hit.$2;
    final f = fetchStatus(refresh: refresh).then((s) => _last[context] = s, onError: (Object e) {
      _cache.remove(context);
      return ArgoWFStatus(error: '$e');
    });
    _cache[context] = (DateTime.now(), f);
    return f;
  }

  Future<ArgoWFStatus> fetchStatus({bool refresh = false}) async {
    final res = await _http.get('status', {'refresh': refresh ? '1' : null});
    return ArgoWFStatus.fromJson(jsonObjectBody(res));
  }
}

// ---------------------------------------------------------------------------
// Pods of steps
// ---------------------------------------------------------------------------

/// The pod name Argo gives [node]'s pod: v1 = the node id; v2 =
/// `<workflow>-<template>-<hash>` (the hash is the node id's suffix), or
/// the workflow name for a single-pod workflow.
String expectedPodName(Json wf, WfNode node) {
  final wfName = dig<String>(wf, ['metadata', 'name']) ?? '';
  final format = dig<String>(wf, ['metadata', 'annotations', annotationPodNameFormat]) ?? 'v2';
  if (format == 'v1') return node.id;
  if (node.name == wfName) return wfName;
  final hash = node.id.substring(node.id.lastIndexOf('-') + 1);
  var prefix = node.name.contains('.inline') ? wfName : '$wfName-${node.template}';
  if (prefix.length > 242) prefix = prefix.substring(0, 242);
  return '$prefix-$hash';
}

/// Finds [node]'s pod among [pods] (the workflow's pods, by the
/// `workflows.argoproj.io/workflow` label): by the node-id annotation, then
/// by the expected v2/v1 name, then by the node-name annotation.
Json? findNodePod(Json wf, WfNode node, List<Json> pods) {
  String ann(Json p, String k) => dig<String>(p, ['metadata', 'annotations', k]) ?? '';
  for (final p in pods) {
    if (ann(p, annotationNodeId) == node.id) return p;
  }
  final expected = {expectedPodName(wf, node), node.id};
  for (final p in pods) {
    if (expected.contains(dig<String>(p, ['metadata', 'name']))) return p;
  }
  for (final p in pods) {
    if (ann(p, annotationNodeName) == node.name) return p;
  }
  return null;
}

Future<List<Json>> fetchWorkflowPods(ApiClient api, Json wf) => api.items(podsRef,
    namespace: dig<String>(wf, ['metadata', 'namespace']), labelSelector: '$labelWorkflow=${dig<String>(wf, ['metadata', 'name'])}');

/// Opens the `main` container's logs of [node]'s pod in the log dock.
Future<void> openNodeLogs(BuildContext context, ApiClient api, Json wf, WfNode node) async {
  final dock = context.read<LogDock>();
  final messenger = ScaffoldMessenger.maybeOf(context);
  List<Json> pods;
  try {
    pods = await fetchWorkflowPods(api, wf);
  } catch (e) {
    messenger?.showSnackBar(SnackBar(content: Text('Could not list pods: $e')));
    return;
  }
  final pod = findNodePod(wf, node, pods);
  if (pod == null) {
    messenger?.showSnackBar(SnackBar(
        content: Text('The pod of ${node.displayName} (${expectedPodName(wf, node)}) no longer exists: it was garbage-collected (podGC) or the workflow was archived.')));
    return;
  }
  final containers = [for (final c in asMapList(dig(pod, ['spec', 'containers']))) '${c['name']}'];
  dock.open(pod, container: containers.contains('main') ? 'main' : containers.firstOrNull);
}

// ---------------------------------------------------------------------------
// Lists of workflows
// ---------------------------------------------------------------------------

/// Newest first (by start, else creation).
int compareWorkflowsNewest(Json a, Json b) {
  String key(Json w) => '${dig(w, ['status', 'startedAt']) ?? dig(w, ['metadata', 'creationTimestamp']) ?? ''}';
  return key(b).compareTo(key(a));
}

/// One workflow in a history list: phase, name link, progress, started,
/// duration.
class WorkflowRow extends StatelessWidget {
  final Json wf;
  const WorkflowRow(this.wf, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = dig<String>(wf, ['metadata', 'name']) ?? '';
    final ns = dig<String>(wf, ['metadata', 'namespace']);
    final phase = workflowPhase(wf);
    final started = parseTime(dig(wf, ['status', 'startedAt'])) ?? parseTime(dig(wf, ['metadata', 'creationTimestamp']));
    final d = runDuration(dig(wf, ['status', 'startedAt']), dig(wf, ['status', 'finishedAt']));
    final progress = dig<String>(wf, ['status', 'progress']);
    final msg = dig<String>(wf, ['status', 'message']);
    final hintStyle = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);
    return LayoutBuilder(builder: (context, box) {
      final narrow = box.maxWidth < 420;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          PhaseBadge(phase, iconOnly: true),
          const SizedBox(width: 6),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              DefaultTextStyle.merge(
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                child: ResourceLink(ObjectRef(group: wfGroup, kind: 'Workflow', name: name, namespace: ns), label: name),
              ),
              if (msg != null && msg.isNotEmpty && (phase == 'Failed' || phase == 'Error'))
                Text(msg, maxLines: 1, overflow: TextOverflow.ellipsis, style: hintStyle?.copyWith(color: severityColor(context, Severity.error))),
            ]),
          ),
          if (!narrow && progress != null) SizedBox(width: 44, child: Text(progress, textAlign: TextAlign.right, style: hintStyle)),
          SizedBox(width: narrow ? 56 : 70, child: Text(started == null ? '' : formatAge(started), textAlign: TextAlign.right, style: hintStyle)),
          SizedBox(width: 64, child: Text(d == null ? '' : formatDuration(d, style: DurationStyle.padded), textAlign: TextAlign.right, style: monoStyle(context, size: 11.5, color: theme.hintColor))),
        ]),
      );
    });
  }
}

/// A list of workflows with a count summary, newest first, capped at [limit].
class WorkflowList extends StatelessWidget {
  final List<Json> workflows;
  final int limit;
  final String empty;
  const WorkflowList(this.workflows, {super.key, this.limit = 15, this.empty = 'No workflows'});

  @override
  Widget build(BuildContext context) {
    if (workflows.isEmpty) return InlineMessage(empty);
    final sorted = [...workflows]..sort(compareWorkflowsNewest);
    final counts = <String, int>{};
    for (final w in sorted) {
      final p = workflowPhase(w);
      counts[p] = (counts[p] ?? 0) + 1;
    }
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Wrap(spacing: 12, runSpacing: 4, children: [
        for (final p in const ['Running', 'Suspended', 'Pending', 'Succeeded', 'Failed', 'Error'])
          if (counts[p] != null)
            Row(mainAxisSize: MainAxisSize.min, children: [
              PhaseBadge(p, iconOnly: true),
              const SizedBox(width: 4),
              Text('${counts[p]} ${p.toLowerCase()}', style: theme.textTheme.bodySmall),
            ]),
      ]),
      const SizedBox(height: 6),
      for (final w in sorted.take(limit)) WorkflowRow(w),
      if (sorted.length > limit)
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text('… and ${sorted.length - limit} older', style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor)),
        ),
    ]);
  }
}

/// Parameters as a table: name, value (mono), with an optional note.
class ParamTable extends StatelessWidget {
  final List<Json> params;

  /// Marks values that came from template defaults.
  final Set<String> defaulted;
  const ParamTable(this.params, {super.key, this.defaulted = const {}});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (params.isEmpty) return const InlineMessage('No parameters');
    return KeyValueTable([
      for (final p in params)
        (
          '${p['name']}',
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Flexible(child: Text(_paramValue(p), style: monoStyle(context, size: 11.5))),
            if (defaulted.contains(p['name'])) ...[
              const SizedBox(width: 6),
              Text('default', style: theme.textTheme.labelSmall?.copyWith(color: theme.hintColor)),
            ],
          ]),
        ),
    ], keyWidth: 150);
  }
}

String _paramValue(Json p) {
  final v = p['value'] ?? p['default'];
  if (v != null) return '$v';
  final vf = asMap(p['valueFrom']);
  if (vf.isNotEmpty) {
    final src = vf.entries.where((e) => e.key != 'default').map((e) => '${e.key}: ${e.value is Map ? (e.value as Map).values.join('/') : e.value}').join(', ');
    return 'from $src';
  }
  return '—';
}
