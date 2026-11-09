import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../../ui/logs/open_logs.dart';
import '../../ui/inspector/inspector.dart';
import '../panel.dart';
import 'batch_common.dart';
import '../../util/json.dart';
import '../../ui/widgets/atoms.dart';


class JobPanel extends ResourcePanel {
  const JobPanel();

  @override
  bool get showsOwned => true;

  @override
  Set<String> get kinds => {'batch/Job'};

  @override
  bool get ownerInHeader => true;

  @override
  List<ResourceAction> actions(PanelContext ctx) => [workloadLogsAction(ctx)];

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final status = ctx.status;
    final failed = asInt(status['failed']);
    final active = asInt(status['active']);
    final succeeded = asInt(status['succeeded']);
    final st = deriveJobState(ctx.object);
    final template = asMap(spec['template']);
    final conditions = asMapList(status['conditions']);
    final trueConds = [for (final c in conditions) if (c['status'] == 'True') '${c['type']}'];
    final failedConds = trueConds.any((t) => t == 'Failed' || t == 'FailureTarget');
    return [
      // Did it work, and if not, why?
      JobStatusHeader(ctx),
      InspectorSection(
        id: 'job-pods',
        title: 'Pods',
        trailing: SectionSummary(
          [
            if (failed > 0) '$failed failed',
            if (active > 0) '$active active',
            if (succeeded > 0) '$succeeded succeeded',
            if (failed + active + succeeded == 0) 'none counted',
          ].join(' · '),
          color: failed > 0 ? severityColor(context, st.label == 'Failed' || st.label == 'Failing' ? Severity.error : Severity.warn) : null,
        ),
        child: JobPods(
          key: ValueKey(ctx.uid),
          api: ctx.api,
          namespace: ctx.namespace,
          uid: ctx.uid,
          // Refetch when the counts move (a pod started, finished or failed).
          signature: [status['active'], status['ready'], status['succeeded'], status['failed'], status['terminating'], ctx.metadata['resourceVersion']].join('/'),
        ),
      ),
      // Reference detail, collapsed behind a one-line summary.
      InspectorSection(
        id: 'job-spec',
        title: 'Spec',
        initiallyExpanded: false,
        trailing: SectionSummary(jobSpecSummary(spec)),
        child: JobSpecTable(ctx.object),
      ),
      InspectorSection(
        id: 'job-template',
        title: 'Pod template',
        initiallyExpanded: false,
        trailing: SectionSummary(podTemplateSummaryLine(template)),
        child: PodTemplateSummary(template, namespace: ctx.namespace),
      ),
      InspectorSection(
        id: 'job-conditions',
        title: 'Conditions',
        initiallyExpanded: false,
        trailing: SectionSummary(
          conditions.isEmpty ? 'none' : (trueConds.isEmpty ? 'none true' : trueConds.join(', ')),
          color: failedConds ? severityColor(context, Severity.error) : null,
        ),
        child: ConditionsTable(status['conditions'] as List?),
      ),
    ];
  }
}

/// "completions 1 · parallelism 2 · backoff 6 · TTL 1h": the settings that
/// shape a run.
String jobSpecSummary(Json spec) {
  final completions = (spec['completions'] as num?)?.toInt();
  final deadline = (spec['activeDeadlineSeconds'] as num?)?.toInt();
  final ttl = (spec['ttlSecondsAfterFinished'] as num?)?.toInt();
  return [
    completions == null ? 'work queue' : 'completions $completions',
    'parallelism ${(spec['parallelism'] as num?)?.toInt() ?? 1}',
    'backoff ${(spec['backoffLimit'] as num?)?.toInt() ?? 6}',
    if (spec['completionMode'] == 'Indexed') 'indexed',
    if (deadline != null) 'deadline ${formatDuration(Duration(seconds: deadline), style: DurationStyle.trimmed)}',
    if (ttl != null) 'TTL ${formatDuration(Duration(seconds: ttl), style: DurationStyle.trimmed)}',
  ].join(' · ');
}

/// The is-it-OK header of a Job: "Complete in 2m", "Running 3/5
/// succeeded" or "Failed: BackoffLimitExceeded", with succeeded, failed,
/// active and duration figures, the insights that explain a problem, and
/// where it came from.
class JobStatusHeader extends StatelessWidget {
  final PanelContext ctx;
  const JobStatusHeader(this.ctx, {super.key});

  @override
  Widget build(BuildContext context) {
    final job = ctx.object;
    final now = batchNow();
    final spec = ctx.spec;
    final status = ctx.status;
    final st = deriveJobState(job);

    final succeeded = asInt(status['succeeded']);
    final failed = asInt(status['failed']);
    final active = asInt(status['active']);
    final ready = status['ready'] is num ? asInt(status['ready']) : null;
    final terminating = asInt(status['terminating']);
    final completions = (spec['completions'] as num?)?.toInt();
    final backoff = (spec['backoffLimit'] as num?)?.toInt() ?? 6;
    final deadline = (spec['activeDeadlineSeconds'] as num?)?.toInt();
    final start = parseTime(status['startTime']);
    final dur = jobDuration(job, now: now);
    final readyActive = ready == null ? active : ready.clamp(0, active);
    final failing = st.label == 'Failed' || st.label == 'Failing';
    final canAct = !ctx.app.readOnly;

    final headline = switch (st.label) {
      'Complete' => dur != null ? 'Complete in ${formatDuration(dur)}' : 'Complete',
      'Failed' || 'Failing' => st.reason != null ? '${st.label}: ${st.reason}' : st.label,
      'Running' => completions != null ? 'Running $succeeded/$completions succeeded' : 'Running · $succeeded succeeded',
      _ => st.label,
    };
    final mark = switch (st.label) {
      'Complete' || 'Completing' => Severity.ok,
      'Running' => failed > 0 ? Severity.warn : Severity.info,
      _ => st.severity,
    };
    final detail = [
      if (st.finishedAt != null) '${st.label == 'Failed' ? 'failed' : 'finished'} ${formatRelative(st.finishedAt!, now: now)}',
      if (!st.finished && start != null) 'started ${formatRelative(start, now: now)}',
      if (st.label == 'Pending' && start == null) 'no pods started yet',
    ].join(' · ');

    // A live job running out of time.
    Insight? deadlineInsight;
    if (deadline != null && !st.finished && start != null && st.reason != 'DeadlineExceeded') {
      final left = start.add(Duration(seconds: deadline)).difference(now);
      if (left.inSeconds < deadline * 0.1) {
        deadlineInsight = Insight(Severity.warn, left.isNegative ? 'Past its active deadline' : 'Active deadline in ${formatDuration(left)}',
            'activeDeadlineSeconds is ${formatDuration(Duration(seconds: deadline), style: DurationStyle.trimmed)}; the job fails with DeadlineExceeded when it runs out.');
      }
    }
    final failedIdx = status['failedIndexes'] as String?;

    final insights = <Insight>[
      if (failing) Insight(Severity.error, _failureTitle(st.reason), st.message),
      if (st.label == 'Suspended') Insight(Severity.warn, 'Suspended: no new pods will be created', st.message ?? 'spec.suspend is true; active pods were terminated.'),
      if (st.label == 'Running' && failed > 0)
        Insight(Severity.warn, 'Retrying after ${plural(failed, 'failed attempt')}',
            'The job fails once failures exceed backoffLimit ($backoff). Failed pods are listed first under Pods.'),
      if (spec['completionMode'] == 'Indexed' && (failedIdx ?? '').isNotEmpty) Insight(Severity.error, 'Failed indexes: $failedIdx'),
      ?deadlineInsight,
    ];

    return InspectorHeader(
      mark: mark,
      headline: headline,
      headlineTone: failing ? Severity.error : (st.label == 'Suspended' ? Severity.warn : null),
      detail: detail.isEmpty ? null : Text(detail),
      figures: [
        InspectorFigure('$succeeded', 'succeeded',
            of: completions == null ? null : '/$completions',
            tooltip: completions == null ? 'Work queue: no fixed completion count' : '$succeeded of $completions completions'),
        InspectorFigure('$failed', 'failed',
            severity: failed == 0 ? Severity.neutral : (failing ? Severity.error : Severity.warn),
            tooltip: 'backoffLimit $backoff: the job fails after ${backoff + 1} failed attempts'),
        InspectorFigure('$active', 'active',
            tooltip: [
              '$readyActive running',
              if (active - readyActive > 0) '${active - readyActive} starting',
              if (terminating > 0) '$terminating terminating',
            ].join(', ')),
        if (dur != null) InspectorFigure(formatDuration(dur), st.finished ? 'took' : 'running for'),
      ],
      insights: insights,
      actions: [
        if (st.label == 'Suspended' && canAct)
          ActionButton(ctx,
              action: 'unsuspend',
              label: 'Resume',
              icon: Icons.play_arrow,
              title: 'Resume Job ${ctx.name}?',
              message: 'Sets spec.suspend=false; the job controller starts creating pods again.'),
      ],
      facts: [
        ?ownerFact(ctx.object),
        if (start != null) ('Started', _timeWithAge(context, start)),
        if (st.finishedAt != null) (st.label == 'Failed' ? 'Failed' : 'Finished', _timeWithAge(context, st.finishedAt!)),
        if (terminating > 0) ('Pods', '$terminating terminating'),
      ],
    );
  }

  static String _failureTitle(String? reason) => switch (reason) {
        'BackoffLimitExceeded' => 'Too many failed attempts (BackoffLimitExceeded)',
        'DeadlineExceeded' => 'activeDeadlineSeconds exceeded',
        'PodFailurePolicy' => 'Failed by the pod failure policy',
        'MaxFailedIndexesExceeded' => 'Too many failed indexes',
        'FailedIndexes' => 'Some indexes failed',
        null => 'Failed',
        _ => 'Failed: $reason',
      };
}

/// The settings of a Job (completions, parallelism, backoff, deadline, TTL,
/// pod failure policy, suspend) with the live state where it matters:
/// failures against the backoff budget, time left, deletion due.
class JobSpecTable extends StatelessWidget {
  final Json job;
  const JobSpecTable(this.job, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = batchNow();
    final spec = asMap(job['spec']);
    final status = asMap(job['status']);
    final st = deriveJobState(job);
    final failed = asInt(status['failed']);
    final completions = (spec['completions'] as num?)?.toInt();
    final parallelism = (spec['parallelism'] as num?)?.toInt() ?? 1;
    final backoff = (spec['backoffLimit'] as num?)?.toInt() ?? 6;
    final backoffPerIndex = (spec['backoffLimitPerIndex'] as num?)?.toInt();
    final deadline = (spec['activeDeadlineSeconds'] as num?)?.toInt();
    final ttl = (spec['ttlSecondsAfterFinished'] as num?)?.toInt();
    final mode = '${spec['completionMode'] ?? 'NonIndexed'}';
    final start = parseTime(status['startTime']);
    final pfp = podFailurePolicySummary(spec['podFailurePolicy']);
    final dur = jobDuration(job, now: now);

    // Backoff budget: the job fails once failures exceed backoffLimit.
    final backoffText = StringBuffer('$backoff');
    if (failed > 0) backoffText.write(' · $failed failure${failed == 1 ? '' : 's'} so far');
    final backoffSev = failed == 0 ? null : (failed > backoff || st.reason == 'BackoffLimitExceeded' ? Severity.error : Severity.warn);

    Widget? deadlineWidget;
    if (deadline != null) {
      var text = formatSeconds(deadline);
      Severity? sev;
      if (st.reason == 'DeadlineExceeded') {
        text += ' · exceeded';
        sev = Severity.error;
      } else if (!st.finished && start != null) {
        final left = start.add(Duration(seconds: deadline)).difference(now);
        text += left.isNegative ? ' · past deadline' : ' · ${formatDuration(left)} left';
        sev = left.inSeconds < deadline * 0.1 ? Severity.warn : null;
      }
      deadlineWidget = _sevText(context, text, sev);
    }

    Widget? ttlWidget;
    if (ttl != null) {
      if (st.finished && st.finishedAt != null) {
        final at = st.finishedAt!.add(Duration(seconds: ttl));
        final left = at.difference(now);
        ttlWidget = _sevText(
            context,
            left.isNegative ? '${formatSeconds(ttl)} · deletion due (${formatRelative(at, now: now)})' : '${formatSeconds(ttl)} · will be deleted ${formatRelative(at, now: now)}',
            Severity.warn);
      } else {
        ttlWidget = _sevText(context, '${formatSeconds(ttl)} after finishing', null);
      }
    }

    final completedIdx = status['completedIndexes'] as String?;
    final failedIdx = status['failedIndexes'] as String?;

    return KeyValueTable([
      ('Completions', '${jobCompletions(job)}${completions == null ? ' (work queue)' : ''}'),
      ('Parallelism', '$parallelism'),
      ('Completion mode', mode),
      if (mode == 'Indexed' && (completedIdx ?? '').isNotEmpty) ('Completed indexes', completedIdx),
      if (mode == 'Indexed' && (failedIdx ?? '').isNotEmpty) ('Failed indexes', _sevText(context, failedIdx!, Severity.error)),
      ('Backoff limit', _sevText(context, backoffText.toString(), backoffSev)),
      if (backoffPerIndex != null) ('Backoff per index', '$backoffPerIndex${spec['maxFailedIndexes'] != null ? ' · max failed indexes ${spec['maxFailedIndexes']}' : ''}'),
      if (deadlineWidget != null) ('Active deadline', deadlineWidget),
      if (ttlWidget != null) ('TTL after finished', ttlWidget),
      if (pfp.isNotEmpty)
        (
          'Pod failure policy',
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [for (final r in pfp) Text(r, style: theme.textTheme.bodySmall)]),
        ),
      if (spec['suspend'] == true) ('Suspend', _sevText(context, 'true', Severity.warn)),
      if (dur != null) ('Duration', formatDuration(dur)),
    ], keyWidth: 120);
  }
}

Widget _sevText(BuildContext context, String text, Severity? sev) => Text(text,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: sev == null ? null : severityColor(context, sev), fontWeight: sev == null ? null : FontWeight.w600));

Widget _timeWithAge(BuildContext context, DateTime t) => Wrap(spacing: 6, children: [
      Text(formatLocal(t), style: Theme.of(context).textTheme.bodySmall),
      HintText('(${formatRelative(t)})'),
    ]);

// ---------------------------------------------------------------------------
// Pods
// ---------------------------------------------------------------------------

/// Pods of a job, by `batch.kubernetes.io/controller-uid` (falling back to
/// the legacy `controller-uid` label).
Future<List<Json>> fetchJobPods(ApiClient api, String? namespace, String uid) async {
  const pods = ResourceRef(resource: 'pods');
  var items = await api.items(pods, namespace: namespace, labelSelector: 'batch.kubernetes.io/controller-uid=$uid');
  if (items.isEmpty) items = await api.items(pods, namespace: namespace, labelSelector: 'controller-uid=$uid');
  items.sort((a, b) => '${dig(a, ['metadata', 'creationTimestamp']) ?? ''}'.compareTo('${dig(b, ['metadata', 'creationTimestamp']) ?? ''}'));
  return items;
}

/// The job's pods as compact rows: failed (and stuck) attempts first and
/// open, then the rest in the order they were created. Each row keeps its
/// attempt number.
class JobPods extends StatefulWidget {
  final ApiClient api;
  final String? namespace;
  final String uid;
  final String signature;
  const JobPods({super.key, required this.api, required this.namespace, required this.uid, required this.signature});

  @override
  State<JobPods> createState() => _JobPodsState();
}

class _JobPodsState extends State<JobPods> {
  late Future<List<Json>> _future;

  @override
  void initState() {
    super.initState();
    _future = fetchJobPods(widget.api, widget.namespace, widget.uid);
  }

  @override
  void didUpdateWidget(JobPods old) {
    super.didUpdateWidget(old);
    if (old.uid != widget.uid || old.signature != widget.signature) {
      _future = fetchJobPods(widget.api, widget.namespace, widget.uid);
    }
  }

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
        future: _future,
        builder: (context, pods) {
          if (pods.isEmpty) {
            return const InlineMessage('No pods found. They may have been cleaned up (TTL or history limits) or not created yet.');
          }
          final numbered = [for (final (i, p) in pods.indexed) (i + 1, p, jobPodStatus(p).$2)];
          bool bad(Severity s) => s == Severity.error || s == Severity.warn;
          final ordered = [...numbered.where((e) => bad(e.$3)), ...numbered.where((e) => !bad(e.$3))];
          var opened = 0;
          return TrimmedList([
            for (final (n, pod, sev) in ordered)
              JobPodRow(
                pod,
                key: ValueKey('job-pod-${dig(pod, ['metadata', 'name'])}'),
                attempt: n,
                // Open the first few failures; a long run of them stays tidy.
                initiallyExpanded: sev == Severity.error && opened++ < 3,
              ),
          ], keep: 6, trimAbove: 8);
        },
      );
}

/// Pod status label for a job pod: phase, refined by reasons.
(String, Severity) jobPodStatus(Json pod) {
  if (dig(pod, ['metadata', 'deletionTimestamp']) != null) return ('Terminating', Severity.neutral);
  final phase = '${dig(pod, ['status', 'phase']) ?? 'Pending'}';
  final statuses = [...asMapList(dig(pod, ['status', 'initContainerStatuses'])), ...asMapList(dig(pod, ['status', 'containerStatuses']))];
  String? waiting;
  for (final s in statuses) {
    final w = dig<String>(s, ['state', 'waiting', 'reason']);
    if (w != null && w != 'PodInitializing' && w != 'ContainerCreating') waiting = w;
  }
  switch (phase) {
    case 'Succeeded':
      return ('Succeeded', Severity.ok);
    case 'Failed':
      final r = dig<String>(pod, ['status', 'reason']);
      return (r != null ? 'Failed: $r' : 'Failed', Severity.error);
    case 'Running':
      return waiting != null ? (waiting, Severity.error) : ('Running', Severity.info);
    default:
      return waiting != null ? (waiting, severityOf(waiting) == Severity.error ? Severity.error : Severity.warn) : (phase, Severity.warn);
  }
}

/// One attempt: "#2 import-data-2cx9", its state, how long it ran and a
/// logs action; open for the node, timings and each container's exit.
class JobPodRow extends StatelessWidget {
  final Json pod;
  final int attempt;
  final bool initiallyExpanded;
  const JobPodRow(this.pod, {super.key, required this.attempt, this.initiallyExpanded = false});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = dig<String>(pod, ['metadata', 'name']) ?? '';
    final ns = dig<String>(pod, ['metadata', 'namespace']);
    final node = dig<String>(pod, ['spec', 'nodeName']);
    final idx = dig<String>(pod, ['metadata', 'annotations', 'batch.kubernetes.io/job-completion-index']) ??
        dig<String>(pod, ['metadata', 'labels', 'batch.kubernetes.io/job-completion-index']);
    final (label, sev) = jobPodStatus(pod);
    final statuses = [
      for (final s in asMapList(dig(pod, ['status', 'initContainerStatuses']))) (s, true),
      for (final s in asMapList(dig(pod, ['status', 'containerStatuses']))) (s, false),
    ];
    final start = parseTime(dig(pod, ['status', 'startTime']));
    DateTime? finish;
    for (final (s, _) in statuses) {
      final f = parseTime(dig(s, ['state', 'terminated', 'finishedAt']));
      if (f != null && (finish == null || f.isAfter(finish))) finish = f;
    }
    final phase = dig<String>(pod, ['status', 'phase']);
    final done = phase == 'Succeeded' || phase == 'Failed';
    final ran = start != null && finish != null && done ? (finish.difference(start).isNegative ? Duration.zero : finish.difference(start)) : null;
    final podMsg = dig<String>(pod, ['status', 'message']);
    final problem = sev == Severity.error || sev == Severity.warn;
    final hintStyle = theme.textTheme.bodySmall?.copyWith(color: theme.hintColor);

    return InspectorRow(
      dot: sev,
      hollowDot: sev == Severity.ok,
      dotTooltip: label,
      problem: problem,
      initiallyExpanded: initiallyExpanded,
      title: Row(children: [
        Text('#$attempt', style: monoStyle(context, size: 11, color: theme.hintColor)),
        const SizedBox(width: 6),
        Flexible(child: ResourceLink(ObjectRef(kind: 'Pod', name: name, namespace: ns), label: name, singleLine: true)),
      ]),
      subtitle: Text.rich(TextSpan(children: [
        TextSpan(text: label, style: problem ? TextStyle(color: severityColor(context, sev), fontWeight: FontWeight.w600) : null),
        if (idx != null) TextSpan(text: '  ·  index $idx'),
        if (ran != null) TextSpan(text: '  ·  ran ${formatDuration(ran)}'),
      ])),
      trailing: [AgeText(dig(pod, ['metadata', 'creationTimestamp']))],
      actions: [
        RowAction(key: ValueKey('job-pod-logs-$name'), icon: Icons.notes, tooltip: 'View logs', onTap: () => openPodLogs(context, pod)),
      ],
      details: (context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (node != null)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.dns_outlined, size: 12, color: theme.hintColor),
              const SizedBox(width: 3),
              Flexible(child: ResourceLink(ObjectRef(kind: 'Node', name: node), label: node, singleLine: true)),
            ])
          else
            Text('not scheduled', style: hintStyle),
          if (start != null) Text('started ${formatLocal(start)}', style: hintStyle),
        ]),
        if (podMsg != null && podMsg.isNotEmpty)
          Padding(padding: const EdgeInsets.only(top: 4), child: Text(podMsg, style: theme.textTheme.bodySmall?.copyWith(color: severityColor(context, sev)))),
        if (statuses.isNotEmpty) ...[
          const SizedBox(height: 8),
          QuietGroup('Containers', [for (final (s, init) in statuses) _ContainerStateLine(s, init: init)], gap: 3),
        ],
      ]),
    );
  }
}

class _ContainerStateLine extends StatelessWidget {
  final Json s;
  final bool init;
  const _ContainerStateLine(this.s, {required this.init});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = '${s['name']}${init ? ' (init)' : ''}';
    final term = asMap(dig(s, ['state', 'terminated']));
    final wait = asMap(dig(s, ['state', 'waiting']));
    final running = asMap(dig(s, ['state', 'running']));
    final last = asMap(dig(s, ['lastState', 'terminated']));
    final restarts = asInt(s['restartCount']);

    final parts = <InlineSpan>[];
    Color? color;
    String? message;
    if (term.isNotEmpty) {
      final code = asInt(term['exitCode']);
      final sig = term['signal'] != null ? ' signal ${term['signal']}' : '';
      color = code == 0 ? null : severityColor(context, Severity.error);
      parts.add(TextSpan(text: 'exit $code$sig', style: TextStyle(color: color, fontWeight: FontWeight.w600)));
      if (term['reason'] != null) parts.add(TextSpan(text: ' · ${term['reason']}'));
      final a = parseTime(term['startedAt']), b = parseTime(term['finishedAt']);
      if (a != null && b != null) parts.add(TextSpan(text: ' · ${formatDuration(b.difference(a).isNegative ? Duration.zero : b.difference(a))}', style: TextStyle(color: theme.hintColor)));
      message = term['message'] as String?;
    } else if (wait.isNotEmpty) {
      final r = '${wait['reason'] ?? 'Waiting'}';
      color = severityColor(context, severityOf(r) == Severity.error ? Severity.error : Severity.warn);
      parts.add(TextSpan(text: 'waiting: $r', style: TextStyle(color: color, fontWeight: FontWeight.w600)));
      message = wait['message'] as String?;
    } else if (running.isNotEmpty) {
      parts.add(const TextSpan(text: 'running', style: TextStyle(fontWeight: FontWeight.w600)));
      final a = parseTime(running['startedAt']);
      if (a != null) parts.add(TextSpan(text: ' · since ${formatLocal(a)}', style: TextStyle(color: theme.hintColor)));
    }
    if (restarts > 0) {
      final lc = last['exitCode'];
      parts.add(TextSpan(
          text: ' · restarted $restarts×${lc != null ? ', last exit $lc${last['reason'] != null ? ' (${last['reason']})' : ''}' : ''}',
          style: TextStyle(color: severityColor(context, Severity.warn))));
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Text.rich(
        TextSpan(style: theme.textTheme.bodySmall, children: [
          TextSpan(text: '$name  ', style: monoStyle(context, size: 11)),
          ...parts,
        ]),
      ),
      if (message != null && message.trim().isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Tooltip(
            message: message.trim(),
            child: Text(message.trim(), maxLines: 6, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11, color: color ?? theme.hintColor)),
          ),
        ),
    ]);
  }
}
