/// Alertmanager routing, receivers, inhibit rules and time intervals, drawn
/// the same way for the live config (`/api/prom/alertmanager`) and for an
/// AlertmanagerConfig's spec. Receivers show their kinds of notifier only:
/// never URLs, keys or other settings.
library;

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../prometheus/prom_api.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/atoms.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import 'selected_by.dart' show amcfgRef;

/// The routing tree, one indented row per route.
class AMRouteTree extends StatelessWidget {
  final AMRoute route;

  /// Shown on the root row (e.g. "root" or "top route").
  final String rootLabel;
  const AMRouteTree(this.route, {super.key, this.rootLabel = 'root'});

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    var count = 0;
    void walk(AMRoute r, int depth) {
      if (count++ > 400) return;
      rows.add(_RouteRow(route: r, depth: depth, label: depth == 0 ? rootLabel : null));
      for (final c in r.routes) {
        walk(c, depth + 1);
      }
    }

    walk(route, 0);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows);
  }
}

class _RouteRow extends StatelessWidget {
  final AMRoute route;
  final int depth;
  final String? label;
  const _RouteRow({required this.route, required this.depth, this.label});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = route;
    final timing = [
      if (r.groupWait != null) 'wait ${r.groupWait}',
      if (r.groupInterval != null) 'interval ${r.groupInterval}',
      if (r.repeatInterval != null) 'repeat ${r.repeatInterval}',
    ];
    return Padding(
      padding: EdgeInsets.only(left: 14.0 * depth.clamp(0, 8), top: 4, bottom: 2),
      child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(depth == 0 ? Icons.call_split : Icons.subdirectory_arrow_right, size: 13, color: theme.hintColor),
        ),
        const SizedBox(width: 5),
        Expanded(
          child: Wrap(spacing: 6, runSpacing: 3, crossAxisAlignment: WrapCrossAlignment.center, children: [
            if (label != null) HintText(label!),
            if (r.matchers.isEmpty && depth > 0) const HintText('every alert'),
            for (final m in r.matchers) Chipish(text: m),
            Icon(Icons.arrow_forward, size: 12, color: theme.hintColor),
            Text(_receiverName(r.receiver), style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
            if (r.source != null) ResourceLink(amcfgRef(r.source!), label: 'from ${r.source!.namespace}/${r.source!.name}'),
            if (r.continues) const HintText('continue'),
            if (r.groupBy.isNotEmpty) HintText('group by ${r.groupBy.join(', ')}'),
            if (timing.isNotEmpty) HintText(timing.join(' · ')),
            if (r.muteTimeIntervals.isNotEmpty) HintText('muted ${r.muteTimeIntervals.join(', ')}'),
            if (r.activeTimeIntervals.isNotEmpty) HintText('active ${r.activeTimeIntervals.join(', ')}'),
          ]),
        ),
      ]),
    );
  }
}

/// `ns/config/receiver` (operator-generated) reads as just the receiver.
String _receiverName(String r) {
  final parts = r.split('/');
  return parts.length == 3 ? parts.last : (r.isEmpty ? '(inherited)' : r);
}

/// Receivers and their kinds of notifier.
class AMReceiverList extends StatelessWidget {
  final List<AMReceiver> receivers;

  /// Alert counts per receiver name (live alerts), when known.
  final Map<String, int> alertCounts;
  const AMReceiverList(this.receivers, {super.key, this.alertCounts = const {}});

  @override
  Widget build(BuildContext context) {
    if (receivers.isEmpty) return const HintText('No receivers');
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final r in receivers)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Wrap(spacing: 8, runSpacing: 2, crossAxisAlignment: WrapCrossAlignment.center, children: [
            Text(_receiverName(r.name), style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
            if (r.integrations.isEmpty) const HintText('no notifiers (drops alerts)'),
            for (final (type, n) in r.integrations) Chipish(text: n > 1 ? '$type ×$n' : type),
            if (r.source != null) ResourceLink(amcfgRef(r.source!), label: 'from ${r.source!.namespace}/${r.source!.name}'),
            if ((alertCounts[r.name] ?? 0) > 0) HintText('${alertCounts[r.name]} active alert${alertCounts[r.name] == 1 ? '' : 's'}'),
          ]),
        ),
    ]);
  }
}

class AMInhibitList extends StatelessWidget {
  final List<AMInhibitRule> rules;
  const AMInhibitList(this.rules, {super.key});

  @override
  Widget build(BuildContext context) {
    if (rules.isEmpty) return const HintText('None');
    final sep = AppColors.of(context).separator;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final (i, r) in rules.indexed) ...[
        if (i > 0) Divider(height: 10, color: sep),
        KeyValueTable([
          ('While firing', _chips(r.source)),
          ('Mute', _chips(r.target)),
          if (r.equal.isNotEmpty) ('With equal', r.equal.join(', ')),
        ], keyWidth: 90),
      ],
    ]);
  }

  static Widget _chips(List<String> l) =>
      l.isEmpty ? const HintText('every alert') : Wrap(spacing: 4, runSpacing: 3, children: [for (final m in l) Chipish(text: m)]);
}

class AMTimeIntervalList extends StatelessWidget {
  final List<AMTimeInterval> intervals;
  const AMTimeIntervalList(this.intervals, {super.key});

  @override
  Widget build(BuildContext context) {
    if (intervals.isEmpty) return const HintText('None');
    return KeyValueTable([for (final t in intervals) (t.name, t.summary.isEmpty ? 'always' : t.summary.join('; '))], keyWidth: 120);
  }
}

// ---------------------------------------------------------------------------
// AlertmanagerConfig spec → the same models
// ---------------------------------------------------------------------------

/// A CR matcher (`{name, value, matchType}` or the older `{name, value, regex}`) as text.
String crMatcher(Json m) {
  final op = m['matchType'] ?? (m['regex'] == true ? '=~' : '=');
  return '${m['name']}$op"${m['value'] ?? ''}"';
}

AMRoute amRouteFromSpec(Json r) => AMRoute(
      receiver: '${r['receiver'] ?? ''}',
      matchers: [for (final m in asMapList(r['matchers'])) crMatcher(m)],
      groupBy: [for (final g in (r['groupBy'] as List? ?? const [])) '$g'],
      continues: r['continue'] == true,
      groupWait: r['groupWait'] as String?,
      groupInterval: r['groupInterval'] as String?,
      repeatInterval: r['repeatInterval'] as String?,
      muteTimeIntervals: [for (final g in (r['muteTimeIntervals'] as List? ?? const [])) '$g'],
      activeTimeIntervals: [for (final g in (r['activeTimeIntervals'] as List? ?? const [])) '$g'],
      // Child routes are free-form JSON in the CRD.
      routes: [for (final c in asMapList(r['routes'])) amRouteFromSpec(c)],
    );

/// Receivers from a spec: notifier kinds (`slackConfigs` → slack) only.
List<AMReceiver> amReceiversFromSpec(List<Json> receivers) => [
      for (final r in receivers)
        AMReceiver(
          name: '${r['name'] ?? ''}',
          integrations: [
            for (final e in r.entries)
              if (e.key.endsWith('Configs') && e.value is List && (e.value as List).isNotEmpty) (e.key.substring(0, e.key.length - 7), (e.value as List).length),
          ],
        ),
    ];

/// Secrets a receiver reads its credentials from (`{name, key}` references
/// anywhere below it), as `name/key`. Only the references, never values.
List<String> secretRefs(dynamic v) {
  final out = <String>{};
  void walk(dynamic x) {
    if (x is Map) {
      final keys = x.keys.toSet();
      if (keys.contains('name') && keys.contains('key') && x['name'] is String && x['key'] is String && keys.difference({'name', 'key', 'optional'}).isEmpty) {
        out.add('${x['name']}/${x['key']}');
        return;
      }
      x.values.forEach(walk);
    } else if (x is List) {
      x.forEach(walk);
    }
  }

  walk(v);
  return out.toList()..sort();
}

List<AMInhibitRule> amInhibitFromSpec(List<Json> rules) => [
      for (final r in rules)
        (
          source: [for (final m in asMapList(r['sourceMatch'])) crMatcher(m)],
          target: [for (final m in asMapList(r['targetMatch'])) crMatcher(m)],
          equal: [for (final e in (r['equal'] as List? ?? const [])) '$e'],
        ),
    ];

List<AMTimeInterval> amIntervalsFromSpec(List<Json> intervals) => [
      for (final t in intervals)
        (
          name: '${t['name'] ?? ''}',
          ranges: asMapList(t['timeIntervals']).length,
          summary: [
            for (final ti in asMapList(t['timeIntervals']))
              [
                for (final w in (ti['weekdays'] as List? ?? const [])) '$w',
                for (final d in (ti['daysOfMonth'] as List? ?? const [])) d is Map ? '${d['start']}-${d['end']}' : '$d',
                for (final m in (ti['months'] as List? ?? const [])) '$m',
                for (final tm in asMapList(ti['times'])) '${tm['startTime']}–${tm['endTime']}',
              ].join(' '),
          ],
        ),
    ];
