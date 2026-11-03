import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'batch_common.dart';
import 'cron.dart';

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

class CronJobPanel extends ResourcePanel {
  const CronJobPanel();

  @override
  Set<String> get kinds => {'batch/CronJob'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final jobSpec = asMap(dig(ctx.spec, ['jobTemplate', 'spec']));
    return [
      DetailSection(title: 'Schedule', icon: Icons.schedule, child: CronScheduleView(ctx.object, ctx: ctx)),
      DetailSection(title: 'Status & policy', icon: Icons.tune, child: _CronStatus(ctx.object)),
      DetailSection(
        title: 'Job history',
        icon: Icons.history,
        child: CronJobHistory(
          key: ValueKey(ctx.uid),
          api: ctx.api,
          namespace: ctx.namespace,
          uid: ctx.uid,
          active: {for (final a in asMapList(ctx.status['active'])) '${a['uid'] ?? a['name']}'},
          signature: [ctx.status['lastScheduleTime'], ctx.status['lastSuccessfulTime'], asMapList(ctx.status['active']).map((a) => a['name']).join(',')].join('/'),
        ),
      ),
      DetailSection(
        title: 'Job template',
        icon: Icons.inventory_2_outlined,
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

/// Expression, description, time zone, next runs and the overdue warning.
class CronScheduleView extends StatelessWidget {
  final Json cronJob;
  /// When given (and not read-only), Resume / Run now controls are shown.
  final PanelContext? ctx;
  const CronScheduleView(this.cronJob, {super.key, this.ctx});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = batchNow();
    final spec = asMap(cronJob['spec']);
    final status = asMap(cronJob['status']);
    final expr = '${spec['schedule'] ?? ''}';
    final suspended = spec['suspend'] == true;
    final sched = CronSchedule.tryParse(expr);
    final canAct = ctx != null && !ctx!.app.readOnly;
    final desc = describeCron(expr);
    final zoneName = (spec['timeZone'] as String?) ?? sched?.timeZone;
    final zone = resolveZone(zoneName);
    final z = zone ?? ZoneRules.utc;
    final runs = sched?.nextRuns(now, count: 5, zone: z) ?? const <DateTime>[];
    final overdue = (sched == null || suspended)
        ? null
        : overdueRun(sched, z, lastSchedule: parseTime(status['lastScheduleTime']), created: parseTime(dig(cronJob, ['metadata', 'creationTimestamp'])), now: now);

    String zoneLabel;
    if (zoneName == null) {
      zoneLabel = 'UTC (no spec.timeZone; controller default)';
    } else if (zone == null) {
      zoneLabel = '$zoneName (unknown here; showing UTC)';
    } else {
      final abbr = z.abbreviationAt(now.toUtc());
      final off = z.offsetAt(now.toUtc());
      final sign = off.isNegative ? '-' : '+';
      final h = off.abs().inHours, m = off.abs().inMinutes % 60;
      zoneLabel = '$zoneName ($abbr, UTC$sign${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')})';
    }

    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      if (suspended)
        Callout(
          severity: Severity.warn,
          icon: Icons.pause_circle_outline,
          title: 'Suspended: no new jobs will be scheduled',
          body: 'spec.suspend is true. Jobs already running are not affected.',
          action: canAct
              ? ActionButton(ctx!,
                  action: 'unsuspend',
                  label: 'Resume',
                  icon: Icons.play_arrow,
                  title: 'Resume CronJob ${ctx!.name}?',
                  message: 'Sets spec.suspend=false. Runs resume from the next scheduled time; missed runs within startingDeadlineSeconds may start immediately.')
              : null,
        ),
      if (overdue != null)
        Callout(
          severity: Severity.warn,
          title: 'Missed schedule: a run was due ${formatRelative(overdue, now: now)}',
          body: 'Expected at ${formatWall(z.toWall(overdue))} ${z.abbreviationAt(overdue)}, but lastScheduleTime is '
              '${status['lastScheduleTime'] != null ? formatRelative(parseTime(status['lastScheduleTime'])!, now: now) : 'unset'}. '
              'Check the controller, startingDeadlineSeconds and concurrencyPolicy.',
        ),
      Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Chipish(text: expr.isEmpty ? '(none)' : expr, copyValue: expr),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            desc != null ? '${desc[0].toUpperCase()}${desc.substring(1)}' : (sched == null ? 'Unrecognised schedule' : expr),
            style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, color: suspended ? theme.hintColor : null),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      Row(children: [
        Icon(Icons.public, size: 13, color: theme.hintColor),
        const SizedBox(width: 4),
        Expanded(child: hint(context, 'Time zone: $zoneLabel')),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        Expanded(child: Text(suspended ? 'Next runs (if resumed)' : 'Next runs', style: theme.textTheme.labelMedium?.copyWith(color: theme.hintColor))),
        if (canAct) RunNowButton(ctx!),
      ]),
      const SizedBox(height: 4),
      if (sched == null)
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
                  child: Icon(i == 0 ? Icons.arrow_right : Icons.circle, size: i == 0 ? 16 : 5, color: i == 0 ? theme.colorScheme.primary : theme.hintColor),
                ),
                mono(context, '${formatWall(z.toWall(r))} ${z.abbreviationAt(r)}', color: i == 0 ? null : theme.colorScheme.onSurfaceVariant),
                const SizedBox(width: 10),
                Text(formatRelative(r, now: now),
                    style: theme.textTheme.bodySmall?.copyWith(color: i == 0 ? theme.colorScheme.primary : theme.hintColor, fontWeight: i == 0 ? FontWeight.w600 : null)),
              ]),
            ),
          ),
    ]);
  }
}

class _CronStatus extends StatelessWidget {
  final Json cj;
  const _CronStatus(this.cj);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final now = batchNow();
    final spec = asMap(cj['spec']);
    final status = asMap(cj['status']);
    final ns = dig<String>(cj, ['metadata', 'namespace']);
    final active = asMapList(status['active']);
    final lastSched = parseTime(status['lastScheduleTime']);
    final lastOk = parseTime(status['lastSuccessfulTime']);
    final suspended = spec['suspend'] == true;
    final policy = '${spec['concurrencyPolicy'] ?? 'Allow'}';
    final policyHelp = switch (policy) {
      'Forbid' => 'skip a run while one is active',
      'Replace' => 'replace the active run',
      _ => 'runs may overlap',
    };

    Widget timeRow(DateTime t, {Severity? sev}) => Wrap(spacing: 6, children: [
          Text(formatLocal(t), style: theme.textTheme.bodySmall?.copyWith(color: sev == null ? null : severityColor(context, sev))),
          hint(context, '(${formatRelative(t, now: now)})'),
        ]);

    // Last success older than last schedule => the latest run failed or is still running.
    Severity? okSev;
    if (lastOk != null && lastSched != null && lastOk.isBefore(lastSched) && active.isEmpty) okSev = Severity.warn;

    return KeyValueTable([
      ('Suspend', suspended ? const Align(alignment: Alignment.centerLeft, child: StatusBadge('Suspended', severity: Severity.warn, dense: true)) : 'false'),
      (
        'Active jobs',
        active.isEmpty
            ? hint(context, 'none')
            : Wrap(spacing: 10, runSpacing: 2, children: [
                for (final a in active)
                  ResourceLink(ObjectRef(group: 'batch', kind: 'Job', name: '${a['name']}', namespace: a['namespace'] as String? ?? ns), label: '${a['name']}'),
              ]),
      ),
      ('Last schedule', lastSched == null ? hint(context, 'never') : timeRow(lastSched)),
      ('Last successful', lastOk == null ? hint(context, lastSched == null ? 'never' : 'never succeeded') : timeRow(lastOk, sev: okSev)),
      ('Concurrency', Text.rich(TextSpan(style: theme.textTheme.bodySmall, children: [
        TextSpan(text: policy, style: const TextStyle(fontWeight: FontWeight.w600)),
        TextSpan(text: ' · $policyHelp', style: TextStyle(color: theme.hintColor)),
      ]))),
      ('Starting deadline', spec['startingDeadlineSeconds'] is num ? formatSeconds((spec['startingDeadlineSeconds'] as num).toInt()) : hint(context, 'none')),
      ('History limits', '${spec['successfulJobsHistoryLimit'] ?? 3} successful · ${spec['failedJobsHistoryLimit'] ?? 1} failed'),
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

/// Bumped after an in-panel action creates a Job, so history refetches.
final ValueNotifier<int> cronJobHistoryRefresh = ValueNotifier(0);

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
    if (res != null) cronJobHistoryRefresh.value++;
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

class CronJobHistory extends StatefulWidget {
  final ApiClient api;
  final String? namespace;
  final String uid;
  final Set<String> active;
  final String signature;
  const CronJobHistory({super.key, required this.api, required this.namespace, required this.uid, required this.active, required this.signature});

  @override
  State<CronJobHistory> createState() => _CronJobHistoryState();
}

class _CronJobHistoryState extends State<CronJobHistory> {
  late Future<List<Json>> _future;

  @override
  void initState() {
    super.initState();
    _future = fetchOwnedJobs(widget.api, widget.namespace, widget.uid);
    cronJobHistoryRefresh.addListener(_refresh);
  }

  void _refresh() {
    if (!mounted) return;
    setState(() {
      _future = fetchOwnedJobs(widget.api, widget.namespace, widget.uid);
    });
  }

  @override
  void dispose() {
    cronJobHistoryRefresh.removeListener(_refresh);
    super.dispose();
  }

  @override
  void didUpdateWidget(CronJobHistory old) {
    super.didUpdateWidget(old);
    if (old.uid != widget.uid || old.signature != widget.signature) {
      _future = fetchOwnedJobs(widget.api, widget.namespace, widget.uid);
    }
  }

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(
        future: _future,
        builder: (context, jobs) {
          if (jobs.isEmpty) return const InlineMessage('No jobs found. Older runs are pruned by the history limits.');
          final states = [for (final j in jobs) deriveJobState(j)];
          final ok = states.where((s) => s.label == 'Complete').length;
          final bad = states.where((s) => s.label == 'Failed').length;
          final theme = Theme.of(context);
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            Text.rich(TextSpan(style: theme.textTheme.bodySmall, children: [
              TextSpan(text: '${jobs.length} job${jobs.length == 1 ? '' : 's'} retained · '),
              TextSpan(text: '$ok complete', style: TextStyle(color: severityColor(context, Severity.ok))),
              const TextSpan(text: ' · '),
              TextSpan(text: '$bad failed', style: TextStyle(color: severityColor(context, bad > 0 ? Severity.error : Severity.neutral))),
            ])),
            const SizedBox(height: 6),
            for (final (i, j) in jobs.indexed) _HistoryRow(j, states[i], active: widget.active.contains(dig(j, ['metadata', 'uid'])) || widget.active.contains(dig(j, ['metadata', 'name']))),
          ]);
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
    final c = severityColor(context, st.severity);
    final small = theme.textTheme.bodySmall;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 5, 8, 5),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainer.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(6),
        border: Border(left: BorderSide(color: c, width: 3)),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Row(children: [
          SizedBox(width: 84, child: Align(alignment: Alignment.centerLeft, child: StatusBadge(st.label, severity: st.severity, dense: true))),
          Expanded(child: ResourceLink(ObjectRef(group: 'batch', kind: 'Job', name: name, namespace: ns), label: name)),
          if (active) ...[const StatusBadge('active', severity: Severity.info, dense: true), const SizedBox(width: 8)],
          SizedBox(width: 44, child: Text(jobCompletions(job), textAlign: TextAlign.right, style: monoStyle(context, size: 11))),
          SizedBox(
            width: 64,
            child: Row(mainAxisAlignment: MainAxisAlignment.end, children: [
              Icon(Icons.timer_outlined, size: 11, color: theme.hintColor),
              const SizedBox(width: 2),
              Text(dur != null ? formatDuration(dur) : '–', style: small),
            ]),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 60,
            child: Align(alignment: Alignment.centerRight, child: AgeText(dig(job, ['metadata', 'creationTimestamp']), suffix: ' ago')),
          ),
        ]),
        if (st.label == 'Failed' && (st.reason != null || st.message != null))
          Padding(
            padding: const EdgeInsets.only(left: 84, top: 2),
            child: Text('${st.reason ?? ''}${st.message != null ? ': ${st.message}' : ''}',
                maxLines: 2, overflow: TextOverflow.ellipsis, style: small?.copyWith(color: c)),
          ),
      ]),
    );
  }
}
