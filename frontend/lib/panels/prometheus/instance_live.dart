/// Live sections of the Prometheus and Alertmanager custom resource panels:
/// what the CR selects (counted and linked), a Prometheus' target health by
/// scrape pool, and an Alertmanager's running routing tree, receivers,
/// inhibit rules, alerts by receiver and silences (view only).
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../prometheus/prom_api.dart';
import '../../ui/inspector/inspector.dart' show SharedFetchBuilder;
import '../../ui/theme.dart';
import '../../ui/widgets/atoms.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'alertmanager_widgets.dart';
import 'common.dart';

String _fk(PanelContext ctx, String what) => 'prom-cr-$what|${identityHashCode(ctx.api)}|${ctx.app.currentContext}|${ctx.namespace}/${ctx.name}';

Future<Selection> _selection(PanelContext ctx) =>
    PromApi.of(ctx.api).selection(kind: ctx.type.kind, namespace: ctx.namespace ?? '', name: ctx.name);

/// "Not found by k8sman" rather than a scary error when the instance isn't discovered.
Widget _liveError(Object e, String what) {
  if (e is ApiException && e.status == 404) return HintText('$what isn\'t available: k8sman didn\'t find this instance reachable.');
  return ErrorNotice(e, title: '$what unavailable', severity: Severity.warn);
}

/// How many monitors, rules (or AlertmanagerConfigs) the CR selects, linked.
class SelectionCounts extends StatelessWidget {
  final PanelContext ctx;
  const SelectionCounts({super.key, required this.ctx});

  static const _plural = {
    'ServiceMonitor': 'ServiceMonitors',
    'PodMonitor': 'PodMonitors',
    'Probe': 'Probes',
    'ScrapeConfig': 'ScrapeConfigs',
    'PrometheusRule': 'PrometheusRules',
    'AlertmanagerConfig': 'AlertmanagerConfigs',
  };

  @override
  Widget build(BuildContext context) => SharedFetchBuilder<Selection>(
        fetchKey: _fk(ctx, 'selection'),
        fetch: () => _selection(ctx),
        builder: (context, snap) {
          final s = snap.data;
          if (s == null) return snap.hasError ? const SizedBox.shrink() : const HintText('Counting what it selects…');
          return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final k in s.kinds)
              if (k.total > 0 || k.error != null) _KindRow(k, label: _plural[k.kind] ?? k.kind),
          ]);
        },
      );
}

class _KindRow extends StatefulWidget {
  final SelectedKind kind;
  final String label;
  const _KindRow(this.kind, {required this.label});

  @override
  State<_KindRow> createState() => _KindRowState();
}

class _KindRowState extends State<_KindRow> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final k = widget.kind;
    final theme = Theme.of(context);
    final shown = _open ? k.selected : const <ObjectRef>[];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        InkWell(
          onTap: k.selected.isEmpty ? null : () => setState(() => _open = !_open),
          child: Row(children: [
            Icon(_open ? Icons.expand_more : Icons.chevron_right, size: 14, color: k.selected.isEmpty ? Colors.transparent : theme.hintColor),
            const SizedBox(width: 2),
            Text('${k.count} of ${k.total} ${widget.label} selected',
                style: theme.textTheme.bodySmall?.copyWith(color: k.count < k.total ? severityColor(context, Severity.warn) : null)),
            if (k.error != null) ...[const SizedBox(width: 6), Flexible(child: HintText(k.error!))],
          ]),
        ),
        if (shown.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 16, top: 2),
            child: Wrap(spacing: 10, runSpacing: 3, children: [
              for (final r in shown.take(60)) ResourceLink(r, label: '${r.namespace}/${r.name}'),
              if (shown.length > 60 || k.count > shown.length) HintText('+${k.count - shown.take(60).length} more'),
            ]),
          ),
      ]),
    );
  }
}

/// A Prometheus' active targets by health, worst scrape pools first.
class PromTargetHealth extends StatelessWidget {
  final PanelContext ctx;
  const PromTargetHealth({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) => SharedFetchBuilder<Selection>(
        fetchKey: _fk(ctx, 'selection'),
        fetch: () => _selection(ctx),
        builder: (context, snap) {
          final s = snap.data;
          if (s != null && !s.hasTargets) return const SizedBox.shrink();
          final pools = s?.pools ?? const <TargetPool>[];
          final bad = [for (final p in pools) if (p.down > 0 || p.unknown > 0) p];
          return DetailSection(
            title: 'Targets',
            icon: Icons.track_changes,
            trailing: s == null ? null : UpDownCounts(up: s.up, down: s.down, unknown: s.unknown),
            child: s == null
                ? (snap.hasError ? _liveError(snap.error!, 'Target health') : const HintText('Loading…'))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    HintText('${pools.length} scrape pools${bad.isEmpty ? ', all healthy' : ', ${bad.length} with failing targets'}'),
                    for (final p in [...bad, ...pools.where((p) => !bad.contains(p))].take(bad.isEmpty ? 8 : bad.length.clamp(8, 40)))
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Row(children: [
                          Expanded(
                            child: p.monitor != null
                                ? ResourceLink(p.monitor!.ref, label: '${p.monitor!.kind} ${p.monitor!.namespace}/${p.monitor!.name}${p.monitor!.endpoint > 0 ? ' #${p.monitor!.endpoint}' : ''}')
                                : HintText(p.scrapePool, mono: true),
                          ),
                          UpDownCounts(up: p.up, down: p.down, unknown: p.unknown),
                        ]),
                      ),
                  ]),
          );
        },
      );
}

extension on TargetPool {
  MonitorRef? get monitor {
    final parts = scrapePool.split('/');
    const kinds = {'serviceMonitor': 'ServiceMonitor', 'podMonitor': 'PodMonitor', 'probe': 'Probe', 'scrapeConfig': 'ScrapeConfig'};
    if (parts.length < 3 || kinds[parts[0]] == null) return null;
    return MonitorRef(kind: kinds[parts[0]]!, namespace: parts[1], name: parts[2], endpoint: endpoint ?? 0);
  }
}

// ---------------------------------------------------------------------------
// Alertmanager
// ---------------------------------------------------------------------------

String _amID(PanelContext ctx) => '${ctx.namespace}/${ctx.name}';

/// The running config: routing tree, receivers, inhibit rules and time
/// intervals, plus the YAML with secrets redacted by the backend.
class AMRouting extends StatelessWidget {
  final PanelContext ctx;
  const AMRouting({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) => SharedFetchBuilder<AMStatus>(
        fetchKey: _fk(ctx, 'am-status'),
        fetch: () => PromApi.of(ctx.api).alertmanagerStatus(instance: _amID(ctx)),
        builder: (context, snap) {
          final s = snap.data;
          return DetailSection(
            title: 'Routing (running config)',
            icon: Icons.call_split,
            trailing: s == null ? null : HintText([if (s.version.isNotEmpty) s.version, if (s.clusterStatus.isNotEmpty) 'cluster ${s.clusterStatus}', if (s.peers > 1) '${s.peers} peers'].join(' · ')),
            child: s == null
                ? (snap.hasError ? _liveError(snap.error!, 'The running config') : const HintText('Loading…'))
                : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (s.route != null) AMRouteTree(s.route!) else const HintText('No route'),
                    const SizedBox(height: 10),
                    _Sub('Receivers', AMReceiverList(s.receivers)),
                    if (s.inhibitRules.isNotEmpty) _Sub('Inhibit rules', AMInhibitList(s.inhibitRules)),
                    if (s.timeIntervals.isNotEmpty) _Sub('Time intervals', AMTimeIntervalList(s.timeIntervals)),
                    if (s.config.isNotEmpty) _ConfigText(s.config),
                  ]),
          );
        },
      );
}

class _Sub extends StatelessWidget {
  final String title;
  final Widget child;
  const _Sub(this.title, this.child);

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Text(title, style: Theme.of(context).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          child,
        ]),
      );
}

class _ConfigText extends StatefulWidget {
  final String text;
  const _ConfigText(this.text);

  @override
  State<_ConfigText> createState() => _ConfigTextState();
}

class _ConfigTextState extends State<_ConfigText> {
  bool _open = false;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => setState(() => _open = !_open),
              icon: Icon(_open ? Icons.expand_less : Icons.expand_more, size: 15),
              label: Text(_open ? 'Hide config' : 'Show config (secrets redacted)'),
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact, padding: const EdgeInsets.symmetric(horizontal: 4)),
            ),
          ),
          if (_open)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(border: Border.all(color: AppColors.of(context).separator), borderRadius: BorderRadius.circular(4)),
              child: SelectableText(widget.text, style: monoStyle(context, size: 11)),
            ),
        ]),
      );
}

/// Active alerts grouped by the receiver they go to.
class AMAlertsByReceiver extends StatelessWidget {
  final PanelContext ctx;
  const AMAlertsByReceiver({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) => SharedFetchBuilder<AlertsData>(
        fetchKey: _fk(ctx, 'am-alerts'),
        fetch: () => PromApi.of(ctx.api).alerts(instance: _amID(ctx)),
        builder: (context, snap) {
          final d = snap.data;
          final byReceiver = <String, List<PromAlert>>{};
          for (final g in d?.groups ?? const <AlertGroup>[]) {
            for (final a in g.alerts) {
              if (a.source != 'alertmanager') continue;
              for (final r in a.receivers.isEmpty ? const ['(none)'] : a.receivers) {
                byReceiver.putIfAbsent(r, () => []).add(a);
              }
            }
          }
          final theme = Theme.of(context);
          final err = d?.errors['alertmanager'];
          return DetailSection(
            title: 'Alerts by receiver',
            icon: Icons.notifications_active_outlined,
            child: d == null
                ? (snap.hasError ? _liveError(snap.error!, 'Alerts') : const HintText('Loading…'))
                : err != null
                    ? HintText(err)
                    : byReceiver.isEmpty
                        ? const HintText('No active alerts.')
                        : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            for (final e in (byReceiver.entries.toList()..sort((a, b) => b.value.length.compareTo(a.value.length))))
                              Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                                  Text('${e.key.split('/').last} · ${e.value.length}', style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
                                  Wrap(spacing: 6, runSpacing: 3, children: [
                                    for (final (name, n) in _countByName(e.value).take(12))
                                      Chipish(text: n > 1 ? '$name ×$n' : name, color: severityColor(context, e.value.firstWhere((a) => a.alertname == name).severity.badge)),
                                  ]),
                                ]),
                              ),
                          ]),
          );
        },
      );

  static List<(String, int)> _countByName(List<PromAlert> l) {
    final m = <String, int>{};
    for (final a in l) {
      m[a.alertname] = (m[a.alertname] ?? 0) + 1;
    }
    return [for (final e in m.entries) (e.key, e.value)]..sort((a, b) => b.$2.compareTo(a.$2));
  }
}

/// Active and pending silences, view only (silences are managed on the Alerts page).
class AMSilences extends StatelessWidget {
  final PanelContext ctx;
  const AMSilences({super.key, required this.ctx});

  @override
  Widget build(BuildContext context) => SharedFetchBuilder<List<Silence>>(
        fetchKey: _fk(ctx, 'am-silences'),
        fetch: () => PromApi.of(ctx.api).silences(instance: _amID(ctx)),
        builder: (context, snap) {
          final all = snap.data;
          final live = [for (final s in all ?? const <Silence>[]) if (s.active || s.pending) s];
          final theme = Theme.of(context);
          return DetailSection(
            title: 'Silences',
            icon: Icons.notifications_off_outlined,
            trailing: all == null ? null : HintText('${live.length} active'),
            child: all == null
                ? (snap.hasError ? _liveError(snap.error!, 'Silences') : const HintText('Loading…'))
                : live.isEmpty
                    ? const HintText('No active silences.')
                    : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        for (final s in live.take(50))
                          Padding(
                            padding: const EdgeInsets.only(top: 5),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              Wrap(spacing: 4, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center, children: [
                                if (s.pending) const StatusBadge('Pending', dense: true, severity: Severity.neutral),
                                for (final m in s.matchers) Chipish(text: m.toString()),
                              ]),
                              Wrap(spacing: 8, children: [
                                if (s.remaining(DateTime.now()) != null) HintText('ends in ${formatDuration(s.remaining(DateTime.now())!)}'),
                                if (s.createdBy.isNotEmpty) HintText('by ${s.createdBy}'),
                                if (s.comment.isNotEmpty) Text(s.comment, style: theme.textTheme.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
                              ]),
                            ]),
                          ),
                        if (live.length > 50) HintText('+${live.length - 50} more'),
                      ]),
          );
        },
      );
}
