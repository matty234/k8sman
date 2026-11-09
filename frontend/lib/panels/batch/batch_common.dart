/// Helpers and widgets shared by the Job and CronJob panels.
library;

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../../util/json.dart';

/// Clock used for derived timings (overridable in tests).
DateTime Function() batchNow = DateTime.now;

// ---------------------------------------------------------------------------
// Pure helpers
// ---------------------------------------------------------------------------

/// "in 3m" / "5m ago" relative to [now].
String formatRelative(DateTime t, {DateTime? now}) {
  final n = (now ?? batchNow()).toUtc();
  final d = t.toUtc().difference(n);
  final abs = d.abs();
  String s;
  if (abs.inSeconds < 60) {
    s = '${abs.inSeconds}s';
  } else if (abs.inMinutes < 60) {
    s = '${abs.inMinutes}m';
  } else {
    s = formatDuration(abs, style: DurationStyle.trimmed);
  }
  return d.isNegative ? '$s ago' : 'in $s';
}

String _two(int n) => n.toString().padLeft(2, '0');
const _wd = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const _mon = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

/// "Tue 03 Nov 11:45" for a wall-clock DateTime (fields are used as-is).
String formatWall(DateTime wall, {bool seconds = false}) =>
    '${_wd[wall.weekday - 1]} ${_two(wall.day)} ${_mon[wall.month - 1]} ${_two(wall.hour)}:${_two(wall.minute)}${seconds ? ':${_two(wall.second)}' : ''}';

/// Seconds as "600s (10m)".
String formatSeconds(int s) {
  if (s < 60) return '${s}s';
  return '${s}s (${formatDuration(Duration(seconds: s))})';
}


/// Derived Job state.
class JobState {
  final String label;
  final Severity severity;
  final String? reason;
  final String? message;

  /// When the job reached a terminal state.
  final DateTime? finishedAt;
  const JobState(this.label, this.severity, {this.reason, this.message, this.finishedAt});

  bool get finished => label == 'Complete' || label == 'Failed';
}

Json? _cond(Json job, String type) {
  for (final c in asMapList(dig(job, ['status', 'conditions']))) {
    if (c['type'] == type && c['status'] == 'True') return c;
  }
  return null;
}

JobState deriveJobState(Json job) {
  final status = asMap(job['status']);
  final failed = _cond(job, 'Failed');
  if (failed != null) {
    return JobState('Failed', Severity.error,
        reason: failed['reason'] as String?, message: failed['message'] as String?, finishedAt: parseTime(failed['lastTransitionTime']));
  }
  final complete = _cond(job, 'Complete');
  if (complete != null) {
    return JobState('Complete', Severity.ok,
        reason: complete['reason'] as String?,
        message: complete['message'] as String?,
        finishedAt: parseTime(status['completionTime']) ?? parseTime(complete['lastTransitionTime']));
  }
  final failing = _cond(job, 'FailureTarget');
  if (failing != null) {
    return JobState('Failing', Severity.error, reason: failing['reason'] as String?, message: failing['message'] as String?);
  }
  final succeeding = _cond(job, 'SuccessCriteriaMet');
  if (succeeding != null) return JobState('Completing', Severity.ok, reason: succeeding['reason'] as String?);
  final suspended = _cond(job, 'Suspended');
  if (dig<bool>(job, ['spec', 'suspend']) == true || suspended != null) {
    return JobState('Suspended', Severity.warn, reason: suspended?['reason'] as String?, message: suspended?['message'] as String?);
  }
  if (asInt(status['active']) > 0) return const JobState('Running', Severity.info);
  return const JobState('Pending', Severity.warn);
}

/// Start → finish (or now, while running).
Duration? jobDuration(Json job, {DateTime? now}) {
  final start = parseTime(dig(job, ['status', 'startTime']));
  if (start == null) return null;
  final st = deriveJobState(job);
  final end = st.finishedAt ?? (st.finished ? null : (now ?? batchNow()));
  if (end == null) return null;
  final d = end.toUtc().difference(start.toUtc());
  return d.isNegative ? Duration.zero : d;
}

/// "succeeded/completions", e.g. "1/1", or "3" for work-queue jobs.
String jobCompletions(Json job) {
  final s = asInt(dig(job, ['status', 'succeeded']));
  final c = dig<num>(job, ['spec', 'completions']);
  return c == null ? '$s' : '$s/${c.toInt()}';
}

/// One-line summaries of a podFailurePolicy.
List<String> podFailurePolicySummary(dynamic policy) {
  final out = <String>[];
  for (final r in asMapList(dig(policy, ['rules']))) {
    final action = '${r['action'] ?? '?'}';
    final ex = asMap(r['onExitCodes']);
    final conds = asMapList(r['onPodConditions']);
    if (ex.isNotEmpty) {
      final op = ex['operator'] == 'NotIn' ? 'not in' : 'in';
      final vals = (ex['values'] as List?)?.join(', ') ?? '';
      final ctr = ex['containerName'] != null ? ' (container ${ex['containerName']})' : '';
      out.add('$action when exit code $op [$vals]$ctr');
    } else if (conds.isNotEmpty) {
      out.add('$action on pod condition ${conds.map((c) => '${c['type']}${c['status'] != null && c['status'] != 'True' ? '=${c['status']}' : ''}').join(', ')}');
    } else {
      out.add(action);
    }
  }
  return out;
}

// ---------------------------------------------------------------------------
// Widgets
// ---------------------------------------------------------------------------

/// Small muted text.
Widget hint(BuildContext context, String s, {double? size}) =>
    Text(s, style: Theme.of(context).textTheme.bodySmall?.copyWith(color: Theme.of(context).hintColor, fontSize: size));

/// A segment of a [CountsBar].
class CountSegment {
  final String label;
  final int count;
  final Color color;
  const CountSegment(this.label, this.count, this.color);
}

/// Stacked horizontal bar of counts against a [total], with a legend.
class CountsBar extends StatelessWidget {
  final List<CountSegment> segments;
  final int total;
  final String? caption;
  const CountsBar({super.key, required this.segments, required this.total, this.caption});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final used = segments.fold<int>(0, (a, s) => a + s.count);
    final denom = total < used ? used : (total == 0 ? 1 : total);
    final rest = denom - used;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: 10,
          child: Row(children: [
            for (final s in segments)
              if (s.count > 0) Expanded(flex: s.count, child: Container(color: s.color)),
            if (rest > 0) Expanded(flex: rest, child: Container(color: theme.colorScheme.surfaceContainerHighest)),
          ]),
        ),
      ),
      const SizedBox(height: 6),
      Wrap(spacing: 12, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final s in segments)
          Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: s.count > 0 ? s.color : s.color.withValues(alpha: 0.3), shape: BoxShape.circle)),
            const SizedBox(width: 4),
            Text('${s.count} ${s.label}',
                style: theme.textTheme.bodySmall?.copyWith(color: s.count > 0 ? null : theme.hintColor, fontWeight: s.count > 0 ? FontWeight.w600 : null)),
          ]),
        if (caption != null) hint(context, caption!),
      ]),
    ]);
  }
}

/// "importer:2.4.1 · restart Never" (or "3 containers · 1 init · ...") for
/// a collapsed pod template's header.
String podTemplateSummaryLine(Json template) {
  final spec = asMap(template['spec']);
  final ctrs = asMapList(spec['containers']);
  final init = asMapList(spec['initContainers']);
  return [
    if (ctrs.length == 1) '${ctrs.first['image'] ?? ctrs.first['name']}'.split('/').last else plural(ctrs.length, 'container'),
    if (init.isNotEmpty) '${init.length} init',
    'restart ${spec['restartPolicy'] ?? 'Always'}',
  ].join(' · ');
}

/// Containers, images, commands and pod-level settings of a pod template.
class PodTemplateSummary extends StatelessWidget {
  /// `spec.template` (with `metadata` and `spec`).
  final Json template;
  final String? namespace;
  const PodTemplateSummary(this.template, {super.key, this.namespace});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spec = asMap(template['spec']);
    final sa = spec['serviceAccountName'] as String?;
    final nodeSel = asMap(spec['nodeSelector']);
    final rp = '${spec['restartPolicy'] ?? 'Always'}';
    final init = asMapList(spec['initContainers']);
    final ctrs = asMapList(spec['containers']);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      KeyValueTable([
        ('Restart policy', Align(alignment: Alignment.centerLeft, child: Chipish(text: rp))),
        if (sa != null && sa.isNotEmpty) ('Service account', ResourceLink(ObjectRef(kind: 'ServiceAccount', name: sa, namespace: namespace), label: sa)),
        if (nodeSel.isNotEmpty) ('Node selector', LabelChips(nodeSel)),
        if (spec['priorityClassName'] != null) ('Priority class', '${spec['priorityClassName']}'),
      ], keyWidth: 120),
      for (final c in init) _ContainerCard(c, init: true, namespace: namespace),
      for (final c in ctrs) _ContainerCard(c, namespace: namespace),
      if (ctrs.isEmpty) Text('No containers', style: TextStyle(color: theme.hintColor)),
    ]);
  }
}

class _ContainerCard extends StatelessWidget {
  final Json c;
  final bool init;
  final String? namespace;
  const _ContainerCard(this.c, {this.init = false, this.namespace});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cmd = [...?(c['command'] as List?), ...?(c['args'] as List?)];
    final req = asMap(dig(c, ['resources', 'requests']));
    final lim = asMap(dig(c, ['resources', 'limits']));
    String res(String k) {
      final r = req[k], l = lim[k];
      if (r == null && l == null) return '';
      return '$k ${r ?? '–'}${l != null ? ' / $l' : ''}';
    }

    final resources = [res('cpu'), res('memory')].where((s) => s.isNotEmpty).join(' · ');
    final envFrom = asMapList(c['envFrom']);
    final env = asMapList(c['env']);
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 6, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Icon(init ? Icons.play_circle_outline : Icons.inventory_2_outlined, size: 14, color: theme.colorScheme.primary),
          Text('${c['name']}', style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          if (init) const StatusBadge('init', dense: true, severity: Severity.neutral),
          Chipish(text: '${c['image'] ?? '?'}', copyValue: '${c['image'] ?? ''}'),
        ]),
        if (cmd.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: CodeBlock(shellJoin(cmd))),
        if (cmd.isEmpty) Padding(padding: const EdgeInsets.only(top: 4), child: hint(context, 'Image default entrypoint')),
        if (resources.isNotEmpty || env.isNotEmpty || envFrom.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Wrap(spacing: 10, runSpacing: 2, children: [
              if (resources.isNotEmpty) hint(context, resources),
              if (env.isNotEmpty) hint(context, '${env.length} env var${env.length == 1 ? '' : 's'}'),
              for (final ef in envFrom)
                if (ef['configMapRef'] != null)
                  ResourceLink(ObjectRef(kind: 'ConfigMap', name: '${ef['configMapRef']['name']}', namespace: namespace))
                else if (ef['secretRef'] != null)
                  ResourceLink(ObjectRef(kind: 'Secret', name: '${ef['secretRef']['name']}', namespace: namespace)),
            ]),
          ),
      ]),
    );
  }
}

/// Compact mono text.
Widget mono(BuildContext context, String s, {Color? color, double size = 12}) => Text(s, style: monoStyle(context, size: size, color: color));
