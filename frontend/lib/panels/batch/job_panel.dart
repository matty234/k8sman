import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../ui/logs/open_logs.dart';
import '../panel.dart';
import 'batch_common.dart';

int _int(dynamic v) => v is num ? v.toInt() : 0;

class JobPanel extends ResourcePanel {
  const JobPanel();

  @override
  bool get showsOwned => true;

  @override
  Set<String> get kinds => {'batch/Job'};

  @override
  List<ResourceAction> actions(PanelContext ctx) => [workloadLogsAction(ctx)];

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final job = ctx.object;
    final pods = _int(ctx.status['active']) + _int(ctx.status['succeeded']) + _int(ctx.status['failed']);
    return [
      DetailSection(title: 'Job', icon: Icons.work_outline, child: JobSummary(job, ctx: ctx)),
      DetailSection(
        title: 'Pods',
        icon: Icons.view_in_ar,
        trailing: pods > 0 ? hint(context, '$pods attempt${pods == 1 ? '' : 's'} counted') : null,
        child: JobPods(
          key: ValueKey(ctx.uid),
          api: ctx.api,
          namespace: ctx.namespace,
          uid: ctx.uid,
          // Refetch when the counts move (a pod started, finished or failed).
          signature: [ctx.status['active'], ctx.status['ready'], ctx.status['succeeded'], ctx.status['failed'], ctx.status['terminating'], ctx.metadata['resourceVersion']]
              .join('/'),
        ),
      ),
      DetailSection(title: 'Conditions', icon: Icons.fact_check_outlined, child: ConditionsTable(ctx.status['conditions'] as List?)),
      DetailSection(
        title: 'Pod template',
        icon: Icons.inventory_2_outlined,
        child: PodTemplateSummary(asMap(ctx.spec['template']), namespace: ctx.namespace),
      ),
    ];
  }
}

/// Status, counts and settings of one Job. Also used by the CronJob history.
class JobSummary extends StatelessWidget {
  final Json job;

  /// When given (and not read-only), in-context actions are shown.
  final PanelContext? ctx;
  const JobSummary(this.job, {super.key, this.ctx});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = batchNow();
    final spec = asMap(job['spec']);
    final status = asMap(job['status']);
    final st = deriveJobState(job);

    final succeeded = _int(status['succeeded']);
    final failed = _int(status['failed']);
    final active = _int(status['active']);
    final ready = status['ready'] is num ? _int(status['ready']) : null;
    final terminating = _int(status['terminating']);
    final completions = (spec['completions'] as num?)?.toInt();
    final parallelism = (spec['parallelism'] as num?)?.toInt() ?? 1;
    final backoff = (spec['backoffLimit'] as num?)?.toInt() ?? 6;
    final backoffPerIndex = (spec['backoffLimitPerIndex'] as num?)?.toInt();
    final deadline = (spec['activeDeadlineSeconds'] as num?)?.toInt();
    final ttl = (spec['ttlSecondsAfterFinished'] as num?)?.toInt();
    final mode = '${spec['completionMode'] ?? 'NonIndexed'}';
    final start = parseTime(status['startTime']);
    final dur = jobDuration(job, now: now);
    final owners = ownerRefs(job);
    final pfp = podFailurePolicySummary(spec['podFailurePolicy']);

    final ok = severityColor(context, Severity.ok);
    final err = severityColor(context, Severity.error);
    final info = severityColor(context, Severity.info);
    final warn = severityColor(context, Severity.warn);
    final neutral = severityColor(context, Severity.neutral);

    final total = completions ?? (succeeded + failed + active > parallelism ? succeeded + failed + active : parallelism);
    final readyActive = ready == null ? active : ready.clamp(0, active);

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

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        StatusBadge(st.label, severity: st.severity),
        if (st.reason != null) ...[
          const SizedBox(width: 8),
          Flexible(child: Text(st.reason!, style: theme.textTheme.bodyMedium?.copyWith(color: severityColor(context, st.severity), fontWeight: FontWeight.w600))),
        ],
        const Spacer(),
        if (dur != null) hint(context, st.finished ? 'took ${formatDuration(dur)}' : 'running ${formatDuration(dur)}'),
      ]),
      const SizedBox(height: 8),
      if (st.label == 'Failed' || st.label == 'Failing')
        Callout(
          severity: Severity.error,
          title: _failureTitle(st.reason),
          body: st.message,
        )
      else if (st.label == 'Suspended')
        Callout(
          severity: Severity.warn,
          icon: Icons.pause_circle_outline,
          title: 'Suspended: no new pods will be created',
          body: st.message ?? 'spec.suspend is true; active pods were terminated.',
          action: ctx == null || ctx!.app.readOnly
              ? null
              : ActionButton(ctx!,
                  action: 'unsuspend',
                  label: 'Resume',
                  icon: Icons.play_arrow,
                  title: 'Resume Job ${ctx!.name}?',
                  message: 'Sets spec.suspend=false; the job controller starts creating pods again.'),
        )
      else if (st.label == 'Running' && failed > 0)
        Callout(
          severity: Severity.warn,
          title: 'Retrying after $failed failed attempt${failed == 1 ? '' : 's'}',
          body: 'The job fails once failures exceed backoffLimit ($backoff). See Pods below for exit codes.',
        ),
      CountsBar(
        total: total,
        caption: completions == null ? '(no fixed completion count)' : 'of $completions',
        segments: [
          CountSegment('succeeded', succeeded, ok),
          CountSegment('failed', failed, err),
          CountSegment('running', readyActive, info),
          if (active - readyActive > 0) CountSegment('starting', active - readyActive, warn),
          if (terminating > 0) CountSegment('terminating', terminating, neutral),
        ],
      ),
      const SizedBox(height: 10),
      KeyValueTable([
        if (owners.isNotEmpty)
          (
            'Owner',
            Wrap(spacing: 8, children: [for (final o in owners) ResourceLink(o)]),
          ),
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
        if (start != null) ('Started', _timeWithAge(context, start)),
        if (st.finishedAt != null) (st.label == 'Failed' ? 'Failed at' : 'Completed', _timeWithAge(context, st.finishedAt!)),
        if (dur != null) ('Duration', formatDuration(dur)),
      ]),
    ]);
  }

  static String _failureTitle(String? reason) => switch (reason) {
        'BackoffLimitExceeded' => 'Failed: too many failed attempts (BackoffLimitExceeded)',
        'DeadlineExceeded' => 'Failed: activeDeadlineSeconds exceeded',
        'PodFailurePolicy' => 'Failed by pod failure policy',
        'MaxFailedIndexesExceeded' => 'Failed: too many failed indexes',
        'FailedIndexes' => 'Failed: some indexes failed',
        null => 'Failed',
        _ => 'Failed: $reason',
      };
}

Widget _sevText(BuildContext context, String text, Severity? sev) => Text(text,
    style: Theme.of(context).textTheme.bodySmall?.copyWith(color: sev == null ? null : severityColor(context, sev), fontWeight: sev == null ? null : FontWeight.w600));

Widget _timeWithAge(BuildContext context, DateTime t) => Wrap(spacing: 6, children: [
      Text(formatLocal(t), style: Theme.of(context).textTheme.bodySmall),
      hint(context, '(${formatRelative(t)})'),
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
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (var i = 0; i < pods.length; i++) JobPodRow(pods[i], attempt: i + 1),
          ]);
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

class JobPodRow extends StatelessWidget {
  final Json pod;
  final int attempt;
  const JobPodRow(this.pod, {super.key, required this.attempt});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = dig<String>(pod, ['metadata', 'name']) ?? '';
    final ns = dig<String>(pod, ['metadata', 'namespace']);
    final node = dig<String>(pod, ['spec', 'nodeName']);
    final idx = dig<String>(pod, ['metadata', 'annotations', 'batch.kubernetes.io/job-completion-index']) ??
        dig<String>(pod, ['metadata', 'labels', 'batch.kubernetes.io/job-completion-index']);
    final (label, sev) = jobPodStatus(pod);
    final c = severityColor(context, sev);
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
    final podMsg = dig<String>(pod, ['status', 'message']);

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      decoration: BoxDecoration(
        color: sev == Severity.error ? c.withValues(alpha: 0.06) : theme.colorScheme.surfaceContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: c, width: 3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          Text('#$attempt', style: monoStyle(context, size: 11, color: theme.hintColor)),
          const SizedBox(width: 6),
          StatusBadge(label, severity: sev, dense: true),
          if (idx != null) ...[const SizedBox(width: 6), Chipish(text: 'index $idx')],
          const SizedBox(width: 8),
          Expanded(child: ResourceLink(ObjectRef(kind: 'Pod', name: name, namespace: ns), label: name)),
          AgeText(dig(pod, ['metadata', 'creationTimestamp'])),
        ]),
        const SizedBox(height: 3),
        Wrap(spacing: 10, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
          if (node != null)
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.dns_outlined, size: 12, color: theme.hintColor),
              const SizedBox(width: 3),
              ResourceLink(ObjectRef(kind: 'Node', name: node), label: node),
            ])
          else
            hint(context, 'not scheduled'),
          if (start != null) hint(context, 'started ${formatLocal(start)}'),
          if (start != null && finish != null && done) hint(context, 'ran ${formatDuration(finish.difference(start).isNegative ? Duration.zero : finish.difference(start))}'),
        ]),
        if (podMsg != null && podMsg.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 3), child: Text(podMsg, style: theme.textTheme.bodySmall?.copyWith(color: c))),
        for (final (s, init) in statuses) _ContainerStateLine(s, init: init),
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
    final restarts = _int(s['restartCount']);

    final parts = <InlineSpan>[];
    Color? color;
    String? message;
    if (term.isNotEmpty) {
      final code = _int(term['exitCode']);
      final sig = term['signal'] != null ? ' signal ${term['signal']}' : '';
      color = severityColor(context, code == 0 ? Severity.ok : Severity.error);
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
      color = severityColor(context, Severity.info);
      parts.add(TextSpan(text: 'running', style: TextStyle(color: color, fontWeight: FontWeight.w600)));
      final a = parseTime(running['startedAt']);
      if (a != null) parts.add(TextSpan(text: ' · since ${formatLocal(a)}', style: TextStyle(color: theme.hintColor)));
    }
    if (restarts > 0) {
      final lc = last['exitCode'];
      parts.add(TextSpan(
          text: ' · restarted $restarts×${lc != null ? ', last exit $lc${last['reason'] != null ? ' (${last['reason']})' : ''}' : ''}',
          style: TextStyle(color: severityColor(context, Severity.warn))));
    }

    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(Icons.subdirectory_arrow_right, size: 12, color: theme.hintColor),
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text.rich(
              TextSpan(style: theme.textTheme.bodySmall, children: [
                TextSpan(text: '$name  ', style: monoStyle(context, size: 11)),
                ...parts,
              ]),
            ),
          ),
        ]),
        if (message != null && message.trim().isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 2),
            child: Tooltip(
              message: message.trim(),
              child: Text(message.trim(), maxLines: 6, overflow: TextOverflow.ellipsis, style: monoStyle(context, size: 11, color: color ?? theme.hintColor)),
            ),
          ),
      ]),
    );
  }
}
