import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../state/log_dock.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../../util/text.dart';
import '../../ui/inspector/inspector.dart';
import '../panel.dart';
import 'batch_common.dart';
import 'cron.dart';
import 'job_panel.dart' show jobSpecSummary;
import '../../ui/widgets/atoms.dart';

/// The first scheduled time after [lastSchedule] (or [created]) if it is
/// well overdue at [now], i.e. past by more than max(2m, 25% of cadence).
DateTime? overdueRun(CronSchedule s, ZoneRules zone, {DateTime? lastSchedule, DateTime? created, required DateTime now}) {
  final base = lastSchedule ?? created;
  if (base == null) return null;
  final next = s.nextRuns(base, count: 2, zone: zone);
  if (next.isEmpty) return null;
  final cadence = next.length > 1 ? next[1].difference(next[0]) : const Duration(hours: 1);
  var grace = Duration(seconds: cadence.inSeconds ~/ 4);
  if (grace < const Duration(minutes: 2)) grace = const Duration(minutes: 2);
  return now.toUtc().isAfter(next[0].add(grace)) ? next[0] : null;
}

/// The schedule of a CronJob resolved against its time zone: the parsed
/// expression, the zone (UTC when unknown) and how to label it.
class _Sched {
  final String expr;
  final CronSchedule? sched;
  final String? zoneName;
  final ZoneRules? zone;
  const _Sched._(this.expr, this.sched, this.zoneName, this.zone);

  factory _Sched(Json cronJob) {
    final expr = '${dig(cronJob, ['spec', 'schedule']) ?? ''}';
    final sched = CronSchedule.tryParse(expr);
    final zoneName = dig<String>(cronJob, ['spec', 'timeZone']) ?? sched?.timeZone;
    return _Sched._(expr, sched, zoneName, resolveZone(zoneName));
  }

  ZoneRules get z => zone ?? ZoneRules.utc;

  /// "Every 5 minutes" (capitalised), else the raw expression.
  String get words {
    final desc = describeCron(expr);
    if (desc != null) return '${desc[0].toUpperCase()}${desc.substring(1)}';
    return sched == null ? 'Unrecognised schedule' : expr;
  }

  List<DateTime> next(DateTime now, {int count = 5}) => sched?.nextRuns(now, count: count, zone: z) ?? const <DateTime>[];

  String wall(DateTime t) => '${formatWall(z.toWall(t))} ${z.abbreviationAt(t)}';

  /// "UTC", "Asia/Tokyo (JST)".
  String get zoneShort => zoneName == null ? 'UTC' : (zone == null ? '$zoneName?' : '$zoneName (${z.abbreviationAt(batchNow().toUtc())})');

  String zoneLabel(DateTime now) {
    if (zoneName == null) return 'UTC (no spec.timeZone; controller default)';
    if (zone == null) return '$zoneName (unknown here; showing UTC)';
    final abbr = z.abbreviationAt(now.toUtc());
    final off = z.offsetAt(now.toUtc());
    final sign = off.isNegative ? '-' : '+';
    final h = off.abs().inHours, m = off.abs().inMinutes % 60;
    return '$zoneName ($abbr, UTC$sign${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')})';
  }
}

/// The key prefix of a CronJob's owned-jobs fetch, for [SharedFetch].
String cronJobsKey(ApiClient api, String uid) => 'cronjobs:${identityHashCode(api)}:$uid';

class CronJobPanel extends ResourcePanel {
  const CronJobPanel();

  @override
  bool get showsOwned => true;

  @override
  Set<String> get kinds => {'batch/CronJob'};

  @override
  bool get ownerInHeader => true;

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final now = batchNow();
    final jobSpec = asMap(dig(ctx.spec, ['jobTemplate', 'spec']));
    final suspended = ctx.spec['suspend'] == true;
    final s = _Sched(ctx.object);
    final runs = s.next(now, count: 1);
    final active = {for (final a in asMapList(ctx.status['active'])) '${a['uid'] ?? a['name']}'};
    final signature = [ctx.status['lastScheduleTime'], ctx.status['lastSuccessfulTime'], asMapList(ctx.status['active']).map((a) => a['name']).join(',')].join('/');
    final policy = '${ctx.spec['concurrencyPolicy'] ?? 'Allow'}';
    final deadline = ctx.spec['startingDeadlineSeconds'];
    return [
      // Is it running on time, and did the last run work?
      CronStatusHeader(ctx, signature: signature),
      InspectorSection(
        id: 'cron-jobs',
        title: 'Recent jobs',
        trailing: SharedFetchBuilder<List<Json>>(
          fetchKey: '${cronJobsKey(ctx.api, ctx.uid)}:$signature',
          fetch: () => fetchOwnedJobs(ctx.api, ctx.namespace, ctx.uid),
          builder: (context, snap) {
            final jobs = snap.data;
            if (jobs == null) return const SizedBox.shrink();
            final states = [for (final j in jobs) deriveJobState(j)];
            final bad = states.where((s) => s.label == 'Failed').length;
            final ok = states.where((s) => s.label == 'Complete').length;
            return SectionSummary(
              jobs.isEmpty ? 'none retained' : [plural(jobs.length, 'job'), if (ok > 0) '$ok complete', if (bad > 0) '$bad failed'].join(' · '),
              color: bad > 0 ? severityColor(context, Severity.error) : null,
            );
          },
        ),
        child: CronJobHistory(
          key: ValueKey(ctx.uid),
          api: ctx.api,
          namespace: ctx.namespace,
          uid: ctx.uid,
          active: active,
          signature: signature,
        ),
      ),
      // Reference detail, collapsed behind a one-line summary.
      InspectorSection(
        id: 'cron-runs',
        title: suspended ? 'Next runs (if resumed)' : 'Next runs',
        initiallyExpanded: false,
        trailing: SectionSummary(runs.isEmpty ? (s.sched == null ? 'unknown' : 'never') : s.wall(runs.first)),
        child: CronScheduleView(ctx.object),
      ),
      InspectorSection(
        id: 'cron-spec',
        title: 'Spec',
        initiallyExpanded: false,
        trailing: SectionSummary([
          policy,
          'keep ${ctx.spec['successfulJobsHistoryLimit'] ?? 3} ok / ${ctx.spec['failedJobsHistoryLimit'] ?? 1} failed',
          if (deadline is num) 'deadline ${formatDuration(Duration(seconds: deadline.toInt()), style: DurationStyle.trimmed)}',
        ].join(' · ')),
        child: _CronSpec(ctx.object),
      ),
      InspectorSection(
        id: 'cron-template',
        title: 'Job template',
        initiallyExpanded: false,
        trailing: SectionSummary(jobSpecSummary(jobSpec)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          KeyValueTable([
            if (jobSpec['completions'] != null) ('Completions', '${jobSpec['completions']}'),
            if (jobSpec['parallelism'] != null) ('Parallelism', '${jobSpec['parallelism']}'),
            if (jobSpec['completionMode'] != null) ('Completion mode', '${jobSpec['completionMode']}'),
            ('Backoff limit', '${jobSpec['backoffLimit'] ?? '6 (default)'}'),
            if (jobSpec['activeDeadlineSeconds'] is num) ('Active deadline', formatSeconds((jobSpec['activeDeadlineSeconds'] as num).toInt())),
            if (jobSpec['ttlSecondsAfterFinished'] is num) ('TTL after finished', formatSeconds((jobSpec['ttlSecondsAfterFinished'] as num).toInt())),
            for (final r in podFailurePolicySummary(jobSpec['podFailurePolicy'])) ('Pod failure rule', r),
          ], keyWidth: 120),
          PodTemplateSummary(asMap(jobSpec['template']), namespace: ctx.namespace),
        ]),
      ),
    ];
  }
}

/// The top of the CronJob inspector: the schedule in words, when it runs
/// next, when it last ran and how that went (from the retained jobs),
/// insights for a suspension, a missed schedule or a failed run, Run now
/// and Suspend/Resume, then the expression, active jobs and last success.
class CronStatusHeader extends StatelessWidget {
  final PanelContext ctx;
  final String signature;
  const CronStatusHeader(this.ctx, {super.key, required this.signature});

  @override
  Widget build(BuildContext context) => SharedFetchBuilder<List<Json>>(
        fetchKey: '${cronJobsKey(ctx.api, ctx.uid)}:$signature',
        fetch: () => fetchOwnedJobs(ctx.api, ctx.namespace, ctx.uid),
        builder: (context, snap) => _build(context, snap.data, snap.hasError),
      );

  Widget _build(BuildContext context, List<Json>? jobs, bool failedToLoad) {
    final theme = Theme.of(context);
    final now = batchNow();
    final spec = ctx.spec;
    final status = ctx.status;
    final ns = ctx.namespace;
    final s = _Sched(ctx.object);
    final suspended = spec['suspend'] == true;
    final canAct = !ctx.app.readOnly;
    final runs = s.next(now, count: 1);
    final lastSched = parseTime(status['lastScheduleTime']);
    final lastOk = parseTime(status['lastSuccessfulTime']);
    final active = asMapList(status['active']);
    final overdue = (s.sched == null || suspended)
        ? null
        : overdueRun(s.sched!, s.z, lastSchedule: lastSched, created: parseTime(ctx.metadata['creationTimestamp']), now: now);

    // The newest retained job tells how the last run went.
    final newest = jobs?.firstOrNull;
    final newestState = newest == null ? null : deriveJobState(newest);
    final lastFailed = newestState?.label == 'Failed' || newestState?.label == 'Failing';
    final (String? result, Severity resultSev) = switch (newestState?.label) {
      null => (jobs == null && !failedToLoad ? null : '—', Severity.neutral),
      'Complete' => ('ok', Severity.neutral),
      'Failed' || 'Failing' => ('failed', Severity.error),
      final l => (l.toLowerCase(), Severity.neutral),
    };

    final mark = suspended || overdue != null ? Severity.warn : (lastFailed ? Severity.error : (newestState?.label == 'Complete' ? Severity.ok : Severity.neutral));
    final warn = severityColor(context, Severity.warn);
    final detail = Text.rich(TextSpan(children: [
      if (suspended) TextSpan(text: 'Suspended', style: TextStyle(color: warn, fontWeight: FontWeight.w600)),
      if (suspended && s.sched != null) const TextSpan(text: '  ·  '),
      if (s.sched == null)
        TextSpan(text: s.expr.isEmpty ? 'no schedule' : s.expr)
      else
        TextSpan(text: runs.isEmpty ? 'never fires' : '${suspended ? 'would run' : 'next'} ${s.wall(runs.first)}'),
    ]));

    // Last success older than the last schedule: the latest run failed or
    // is still running.
    final okStale = lastOk != null && lastSched != null && lastOk.isBefore(lastSched) && active.isEmpty;
    Widget timeRow(DateTime t, {Severity? sev}) => Wrap(spacing: 6, children: [
          Text(formatLocal(t), style: theme.textTheme.bodySmall?.copyWith(color: sev == null ? null : severityColor(context, sev))),
          HintText('(${formatRelative(t, now: now)})'),
        ]);

    return InspectorHeader(
      mark: mark,
      headline: s.words,
      detail: detail,
      figures: [
        InspectorFigure(suspended ? 'paused' : (runs.isEmpty ? '—' : formatRelative(runs.first, now: now)), 'next run',
            severity: suspended ? Severity.warn : Severity.neutral, tooltip: runs.isEmpty ? null : s.wall(runs.first)),
        InspectorFigure(lastSched == null ? 'never' : formatRelative(lastSched, now: now), 'last run', tooltip: lastSched == null ? null : formatLocal(lastSched)),
        InspectorFigure(result, 'last result', severity: resultSev, tooltip: newest == null ? null : '${dig(newest, ['metadata', 'name'])}: ${newestState!.label}'),
        InspectorFigure('${active.length}', 'active'),
      ],
      insights: [
        if (suspended) const Insight(Severity.warn, 'Suspended: no new jobs will be scheduled', 'spec.suspend is true. Jobs already running are not affected.'),
        if (overdue != null)
          Insight(
            Severity.warn,
            'Missed schedule: a run was due ${formatRelative(overdue, now: now)}',
            'Expected at ${s.wall(overdue)}, but lastScheduleTime is '
                '${lastSched != null ? formatRelative(lastSched, now: now) : 'unset'}. '
                'Check the controller, startingDeadlineSeconds and concurrencyPolicy.',
          ),
        if (lastFailed)
          Insight(
            Severity.error,
            'Last run failed${newestState!.reason != null ? ': ${newestState.reason}' : ''}',
            '${dig(newest!, ['metadata', 'name'])}${newestState.message != null ? ': ${newestState.message}' : ''}',
          ),
      ],
      actions: [
        if (canAct) RunNowButton(ctx),
        if (canAct && suspended)
          ActionButton(ctx,
              action: 'unsuspend',
              label: 'Resume',
              icon: Icons.play_arrow,
              title: 'Resume CronJob ${ctx.name}?',
              message: 'Sets spec.suspend=false. Runs resume from the next scheduled time; missed runs within startingDeadlineSeconds may start immediately.'),
        if (canAct && !suspended)
          ActionButton(ctx, action: 'suspend', label: 'Suspend', icon: Icons.pause, title: 'Suspend CronJob ${ctx.name}?', message: 'No new jobs will be scheduled.'),
      ],
      facts: [
        ?ownerFact(ctx.object),
        (
          'Schedule',
          Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Chipish(text: s.expr.isEmpty ? '(none)' : s.expr, copyValue: s.expr),
            HintText(s.zoneShort),
          ]),
        ),
        if (active.isNotEmpty)
          (
            'Active',
            Wrap(spacing: 10, runSpacing: 2, children: [
              for (final a in active)
                ResourceLink(ObjectRef(group: 'batch', kind: 'Job', name: '${a['name']}', namespace: a['namespace'] as String? ?? ns), label: '${a['name']}'),
            ]),
          ),
        ('Last ok', lastOk == null ? HintText(lastSched == null ? 'never' : 'never succeeded') : timeRow(lastOk, sev: okStale ? Severity.warn : null)),
      ],
    );
  }
}

/// The next five runs in the CronJob's time zone (dimmed while suspended).
class CronScheduleView extends StatelessWidget {
  final Json cronJob;
  const CronScheduleView(this.cronJob, {super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = batchNow();
    final suspended = dig(cronJob, ['spec', 'suspend']) == true;
    final s = _Sched(cronJob);
    final runs = s.next(now);

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Icon(Icons.public, size: 13, color: theme.hintColor),
        const SizedBox(width: 4),
        Expanded(child: HintText('Time zone: ${s.zoneLabel(now)}')),
      ]),
      const SizedBox(height: 6),
      if (s.sched == null)
        const InlineMessage('Cannot compute run times for this expression.')
      else if (runs.isEmpty)
        const InlineMessage('This schedule never fires.')
      else
        for (final (i, r) in runs.indexed)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 2),
            child: Opacity(
              opacity: suspended ? 0.5 : 1,
              child: Row(children: [
                SizedBox(
                  width: 18,
                  child: Icon(i == 0 ? Icons.arrow_right : Icons.circle, size: i == 0 ? 16 : 5, color: theme.hintColor),
                ),
                Flexible(child: mono(context, s.wall(r), color: i == 0 ? null : theme.colorScheme.onSurfaceVariant)),
                const SizedBox(width: 10),
                Text(formatRelative(r, now: now),
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.hintColor, fontWeight: i == 0 ? FontWeight.w600 : null)),
              ]),
            ),
          ),
    ]);
  }
}

/// Concurrency policy, starting deadline, history limits and suspend.
class _CronSpec extends StatelessWidget {
  final Json cj;
  const _CronSpec(this.cj);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final spec = asMap(cj['spec']);
    final suspended = spec['suspend'] == true;
    final policy = '${spec['concurrencyPolicy'] ?? 'Allow'}';
    final policyHelp = switch (policy) {
      'Forbid' => 'skip a run while one is active',
      'Replace' => 'replace the active run',
      _ => 'runs may overlap',
    };
    return KeyValueTable([
      (
        'Concurrency',
        Text.rich(TextSpan(style: theme.textTheme.bodySmall, children: [
          TextSpan(text: policy, style: const TextStyle(fontWeight: FontWeight.w600)),
          TextSpan(text: ' · $policyHelp', style: TextStyle(color: theme.hintColor)),
        ])),
      ),
      ('Starting deadline', spec['startingDeadlineSeconds'] is num ? formatSeconds((spec['startingDeadlineSeconds'] as num).toInt()) : HintText('none')),
      ('History limits', '${spec['successfulJobsHistoryLimit'] ?? 3} successful · ${spec['failedJobsHistoryLimit'] ?? 1} failed'),
      ('Suspend', suspended ? const Align(alignment: Alignment.centerLeft, child: StatusBadge('Suspended', severity: Severity.warn, dense: true)) : 'false'),
    ], keyWidth: 120);
  }
}

// ---------------------------------------------------------------------------
// Job history
// ---------------------------------------------------------------------------

/// Jobs controlled by the CronJob with [uid], newest first.
Future<List<Json>> fetchOwnedJobs(ApiClient api, String? namespace, String uid) async {
  final jobs = await api.items(const ResourceRef(group: 'batch', resource: 'jobs'), namespace: namespace);
  final owned = [
    for (final j in jobs)
      if (asMapList(dig(j, ['metadata', 'ownerReferences'])).any((o) => o['uid'] == uid)) j,
  ];
  String key(Json j) => '${dig(j, ['status', 'startTime']) ?? dig(j, ['metadata', 'creationTimestamp']) ?? ''}';
  owned.sort((a, b) => key(b).compareTo(key(a)));
  return owned;
}

/// "Run now": triggers the CronJob, then refreshes the job history. The
/// snackbar from [runResourceAction] offers to open the created Job.
class RunNowButton extends StatefulWidget {
  final PanelContext ctx;
  const RunNowButton(this.ctx, {super.key});

  @override
  State<RunNowButton> createState() => _RunNowButtonState();
}

class _RunNowButtonState extends State<RunNowButton> {
  bool _busy = false;

  Future<void> _run() async {
    setState(() => _busy = true);
    final res = await runResourceAction(context, widget.ctx, 'trigger',
        title: 'Run CronJob ${widget.ctx.name} now?',
        message: 'Creates a one-off Job from the job template, outside the schedule. '
            'concurrencyPolicy is not applied to manual runs.',
        confirmLabel: 'Run now');
    if (res != null) SharedFetch.invalidate(cronJobsKey(widget.ctx.api, widget.ctx.uid));
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
        style: OutlinedButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 10)),
        icon: _busy ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.play_circle_outline, size: 16),
        label: const Text('Run now'),
        onPressed: _busy ? null : _run,
      );
}

/// The retained jobs as compact rows: failures first (and open), then the
/// rest newest first, each with a logs action.
class CronJobHistory extends StatelessWidget {
  final ApiClient api;
  final String? namespace;
  final String uid;
  final Set<String> active;
  final String signature;
  const CronJobHistory({super.key, required this.api, required this.namespace, required this.uid, required this.active, required this.signature});

  @override
  Widget build(BuildContext context) => SharedFetchBuilder<List<Json>>(
        fetchKey: '${cronJobsKey(api, uid)}:$signature',
        fetch: () => fetchOwnedJobs(api, namespace, uid),
        builder: (context, snap) {
          if (snap.hasError) return InlineMessage('${snap.error}', isError: true);
          final jobs = snap.data;
          if (jobs == null) return const SectionSpinner(size: 14, strokeWidth: 1.5);
          if (jobs.isEmpty) return const InlineMessage('No jobs found. Older runs are pruned by the history limits.');
          final rows = [for (final j in jobs) (j, deriveJobState(j))];
          bool failed((Json, JobState) r) => r.$2.label == 'Failed' || r.$2.label == 'Failing';
          return TrimmedList([
            for (final (j, st) in [...rows.where(failed), ...rows.where((r) => !failed(r))])
              _HistoryRow(j, st, active: active.contains(dig(j, ['metadata', 'uid'])) || active.contains(dig(j, ['metadata', 'name']))),
          ], keep: 6, trimAbove: 8);
        },
      );
}

class _HistoryRow extends StatelessWidget {
  final Json job;
  final JobState st;
  final bool active;
  const _HistoryRow(this.job, this.st, {required this.active});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = dig<String>(job, ['metadata', 'name']) ?? '';
    final ns = dig<String>(job, ['metadata', 'namespace']);
    final dur = jobDuration(job);
    final failed = st.label == 'Failed' || st.label == 'Failing';
    final start = parseTime(dig(job, ['status', 'startTime']));
    final selector = selectorToString(dig(job, ['spec', 'selector']));
    final small = theme.textTheme.bodySmall;
    return InspectorRow(
      key: ValueKey('cron-job-$name'),
      memoryId: 'cron-job:${dig(job, ['metadata', 'uid']) ?? name}',
      dot: active ? Severity.info : st.severity,
      hollowDot: st.label == 'Complete',
      dotTooltip: active ? 'active' : st.label,
      problem: failed,
      title: ResourceLink(ObjectRef(group: 'batch', kind: 'Job', name: name, namespace: ns), label: name, singleLine: true),
      subtitle: Text.rich(TextSpan(children: [
        TextSpan(text: active ? 'Active' : st.label, style: failed ? TextStyle(color: severityColor(context, Severity.error), fontWeight: FontWeight.w600) : null),
        TextSpan(text: '  ·  ${jobCompletions(job)}'),
        if (dur != null) TextSpan(text: '  ·  ${formatDuration(dur)}'),
      ])),
      trailing: [AgeText(dig(job, ['metadata', 'creationTimestamp']), suffix: ' ago')],
      actions: [
        if (selector.isNotEmpty && ns != null)
          RowAction(
            key: ValueKey('cron-job-logs-$name'),
            icon: Icons.notes,
            tooltip: 'View logs',
            onTap: () => context.read<LogDock>().openAggregate(ns, selector: selector, title: 'job/$name'),
          ),
      ],
      details: (context) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        if (failed && (st.reason != null || st.message != null))
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text('${st.reason ?? ''}${st.message != null ? '${st.reason != null ? ': ' : ''}${st.message}' : ''}',
                style: small?.copyWith(color: severityColor(context, Severity.error))),
          ),
        KeyValueTable([
          if (start != null) ('Started', '${formatLocal(start)} (${formatRelative(start)})'),
          if (st.finishedAt != null) (failed ? 'Failed' : 'Finished', formatLocal(st.finishedAt!)),
          ('Completions', jobCompletions(job)),
          if (dur != null) ('Duration', formatDuration(dur)),
        ], keyWidth: 84),
      ]),
    );
  }
}
