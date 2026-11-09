/// The workload inspectors' secondary sections, collapsed behind a one-line
/// summary (as on the pod inspector) and remembered per session.
library;

import 'package:flutter/material.dart';

import '../../../api/models.dart';
import '../../../ui/theme.dart';
import '../../../ui/widgets/common.dart';
import '../../../util/k8s.dart';
import '../../../util/text.dart';
import '../../../ui/inspector/inspector.dart';
import 'pod_template.dart';
import 'status_header.dart';
import 'util.dart';

/// A workload section, collapsed by default; [id] is remembered per session
/// (prefixed, so it doesn't share state with the pod inspector's).
Widget workloadSection(String id, String title, String summary, Widget child, {Color? summaryColor, bool expanded = false}) => InspectorSection(
      key: ValueKey('workload-section-$id'),
      id: 'workload-$id',
      title: title,
      initiallyExpanded: expanded,
      trailing: summary.isEmpty ? null : SectionSummary(summary, color: summaryColor),
      child: child,
    );

/// "2 containers · nginx:1.27" (the first main container's image, short).
String templateSummary(Json template) {
  final spec = asMap(template['spec']);
  final containers = asMapList(spec['containers']);
  final inits = asMapList(spec['initContainers']);
  final image = containers.isEmpty ? null : shortImageRef('${containers.first['image'] ?? ''}');
  return [
    plural(containers.length, 'container'),
    if (inits.isNotEmpty) '${inits.length} init',
    ?image,
  ].join(' · ');
}

/// The image without its registry ("nginx:1.27-alpine").
String shortImageRef(String image) {
  final at = image.indexOf('@');
  final ref = at < 0 ? image : '${image.substring(0, at)}@…';
  final parts = ref.split('/');
  return parts.length > 1 && (parts.first.contains('.') || parts.first.contains(':')) ? parts.sublist(1).join('/') : ref;
}

/// "node selector · 2 tolerations · anti-affinity", or [none].
String schedulingSummary(Json podSpec, {String none = 'none'}) {
  final aff = asMap(podSpec['affinity']);
  final tols = asMapList(podSpec['tolerations']);
  final parts = [
    if (asMap(podSpec['nodeSelector']).isNotEmpty) 'node selector',
    if (aff['nodeAffinity'] != null) 'node affinity',
    if (aff['podAffinity'] != null) 'pod affinity',
    if (aff['podAntiAffinity'] != null) 'anti-affinity',
    if (asMapList(podSpec['topologySpreadConstraints']).isNotEmpty) 'spread',
    if (tols.isNotEmpty) plural(tols.length, 'toleration'),
  ];
  return parts.isEmpty ? none : parts.join(' · ');
}

/// The pod template's scheduling: node selector, tolerations, affinity,
/// spread constraints.
Widget schedulingSection(Json podSpec, {String emptyText = 'No node selector, tolerations or affinity', String none = 'none'}) {
  final entries = [
    ...PodTemplateSummary.schedulingEntries(podSpec),
    if (asMapList(podSpec['topologySpreadConstraints']).isNotEmpty)
      (
        'Spread',
        Text([
          for (final t in asMapList(podSpec['topologySpreadConstraints'])) '${t['topologyKey']} · max skew ${t['maxSkew']} · ${t['whenUnsatisfiable'] ?? 'DoNotSchedule'}',
        ].join('\n')),
      ),
  ];
  return workloadSection(
    'scheduling',
    'Scheduling',
    schedulingSummary(podSpec, none: none),
    entries.isEmpty ? InlineMessage(emptyText) : KeyValueTable(entries, keyWidth: 110),
  );
}

/// Conditions: "all 2 true", or the false ones in amber.
Widget conditionsSection(BuildContext context, Json status) {
  final conditions = asMapList(status['conditions']);
  final wrong = [for (final c in conditions) if (conditionIsBad(c)) '${c['type']}'];
  final summary = conditions.isEmpty
      ? 'none'
      : wrong.isEmpty
      ? (conditions.length == 1 ? 'true' : 'all ${conditions.length} true')
      : wrong.map((t) => badWhenTrue.contains(t) ? t : '$t false').join(', ');
  return workloadSection(
    'conditions',
    'Conditions',
    summary,
    ConditionsTable(status['conditions'] as List?),
    summaryColor: wrong.isEmpty ? null : severityColor(context, Severity.warn),
  );
}

/// "app=web, tier=frontend" (and expressions).
String selectorSummary(dynamic selector) {
  final s = selectorToString(selector);
  return s.isEmpty ? 'everything' : s.replaceAll(',', ', ');
}

/// The label selector, with any [extra] rows (e.g. min ready seconds).
Widget selectorSection(dynamic selector, {List<(String, Object?)> extra = const []}) => workloadSection(
      'selector',
      'Selector',
      selectorSummary(selector),
      extra.isEmpty ? SelectorChips(selector) : KeyValueTable([('Selector', SelectorChips(selector)), ...extra], keyWidth: 110),
    );

/// The pod template (containers, service account, volumes, config refs).
Widget podTemplateSection(Json template, String? namespace) => workloadSection(
      'template',
      'Pod template',
      templateSummary(template),
      PodTemplateSummary(template: template, namespace: namespace, showScheduling: false),
    );
