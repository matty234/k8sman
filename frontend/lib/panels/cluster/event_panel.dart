import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/detail/detail_sidebar.dart' show EventList;
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../network/inspector_kit.dart';
import '../panel.dart';

/// Normalised view of a core/v1 or events.k8s.io/v1 Event.
class EventView {
  final String type;
  final String reason;
  final String message;
  final int count;
  final dynamic firstSeen;
  final dynamic lastSeen;
  final dynamic eventTime;
  final Json regarding;
  final Json related;
  final String? fieldPath;
  final String? sourceComponent;
  final String? sourceHost;
  final String? reportingController;
  final String? reportingInstance;
  final String? action;
  final Json series;

  const EventView({
    required this.type,
    required this.reason,
    required this.message,
    required this.count,
    this.firstSeen,
    this.lastSeen,
    this.eventTime,
    required this.regarding,
    required this.related,
    this.fieldPath,
    this.sourceComponent,
    this.sourceHost,
    this.reportingController,
    this.reportingInstance,
    this.action,
    required this.series,
  });

  static String? _s(dynamic v) => v is String && v.isNotEmpty ? v : null;

  factory EventView.from(Json e) {
    final isNew = '${e['apiVersion']}'.startsWith('events.k8s.io/');
    final series = asMap(e['series']);
    final regarding = asMap(isNew ? e['regarding'] : e['involvedObject']);
    final source = asMap(isNew ? e['deprecatedSource'] : e['source']);
    final created = dig(e, ['metadata', 'creationTimestamp']);
    final baseCount = ((isNew ? e['deprecatedCount'] : e['count']) as num?)?.toInt() ?? 1;
    final first = (isNew ? e['deprecatedFirstTimestamp'] : e['firstTimestamp']) ?? e['eventTime'] ?? created;
    final last = series['lastObservedTime'] ?? (isNew ? e['deprecatedLastTimestamp'] : e['lastTimestamp']) ?? e['eventTime'] ?? created;
    return EventView(
      type: _s(e['type']) ?? 'Normal',
      reason: _s(e['reason']) ?? '',
      message: _s(isNew ? e['note'] : e['message']) ?? '',
      count: (series['count'] as num?)?.toInt() ?? baseCount,
      firstSeen: first,
      lastSeen: last,
      eventTime: e['eventTime'],
      regarding: regarding,
      related: asMap(e['related']),
      fieldPath: _s(regarding['fieldPath']),
      sourceComponent: _s(source['component']),
      sourceHost: _s(source['host']),
      reportingController: _s(isNew ? e['reportingController'] : e['reportingComponent']),
      reportingInstance: _s(e['reportingInstance']),
      action: _s(e['action']),
      series: series,
    );
  }
}

class EventPanel extends ResourcePanel {
  const EventPanel();

  @override
  Set<String> get kinds => {'/Event', 'events.k8s.io/Event'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final ev = EventView.from(ctx.object);
    final ns = ctx.namespace;
    final regardingUid = ev.regarding['uid'] as String?;
    return [
      _EventHeader(ev, namespace: ns),
      if (ev.regarding.isNotEmpty)
        PodSection(
          id: 'event-others',
          title: 'Other events for ${ev.regarding['kind'] ?? 'object'}/${ev.regarding['name'] ?? ''}',
          initiallyExpanded: ev.type == 'Warning',
          child: _SiblingEvents(
            key: ValueKey(ctx.uid),
            api: ctx.api,
            namespace: ev.regarding['namespace'] as String? ?? ns,
            uid: regardingUid,
            kind: ev.regarding['kind'] as String?,
            name: ev.regarding['name'] as String?,
            selfUid: ctx.uid,
          ),
        ),
    ];
  }
}

/// The event as a status header: type and reason, how often and when,
/// the involved object, then the message and the remaining facts.
class _EventHeader extends StatelessWidget {
  final EventView ev;
  final String? namespace;
  const _EventHeader(this.ev, {this.namespace});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warn = ev.type == 'Warning';
    final bar = warn ? severityColor(context, Severity.warn) : AppColors.of(context).separator;
    ObjectRef ref(Json j) => ObjectRef.fromOwnerRef(j, namespace: namespace);
    final source = [ev.sourceComponent, if (ev.sourceHost != null) 'on ${ev.sourceHost}'].whereType<String>().join(' ');
    final small = theme.textTheme.bodySmall;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InspectorHeader(
        mark: warn ? Severity.warn : Severity.neutral,
        headline: ev.reason.isEmpty ? '(no reason)' : ev.reason,
        detail: [ev.type, if (ev.count > 1) '×${ev.count}'].join(' · '),
        figures: [
          HeaderFigure('${ev.count}', ev.count == 1 ? 'time' : 'times', severity: warn && ev.count > 1 ? Severity.warn : Severity.neutral),
          if (parseTime(ev.lastSeen) != null) HeaderFigure.age(ev.lastSeen, 'last seen'),
          if (parseTime(ev.firstSeen) != null) HeaderFigure.age(ev.firstSeen, 'first seen'),
        ],
        facts: KeyValueTable(keyWidth: 72, [
          ('Object', ev.regarding.isEmpty ? null : Align(alignment: Alignment.centerLeft, child: ResourceLink(ref(ev.regarding)))),
          ('Field', ev.fieldPath),
        ]),
      ),
      // The message, marked like an insight: amber for warnings.
      Container(
        margin: const EdgeInsets.only(top: 4, bottom: 12),
        padding: const EdgeInsets.only(left: 10),
        decoration: BoxDecoration(border: Border(left: BorderSide(color: bar, width: 2.5))),
        child: Text(ev.message.isEmpty ? '(no message)' : ev.message, style: theme.textTheme.bodyMedium?.copyWith(height: 1.35)),
      ),
      KeyValueTable([
        ('Related', ev.related.isEmpty ? null : Align(alignment: Alignment.centerLeft, child: ResourceLink(ref(ev.related)))),
        ('Count', ev.count > 1 ? '${ev.count}' : null),
        ('Series',
            ev.series.isEmpty
                ? null
                : Wrap(children: [
                    Text('${ev.series['count'] ?? '?'} occurrences, last observed ', style: small),
                    AgeText(ev.series['lastObservedTime'], suffix: ' ago', style: small),
                  ])),
        ('Action', ev.action),
        ('Source', source.isEmpty ? null : source),
        ('Reporter', ev.reportingController),
        ('Instance', ev.reportingInstance),
      ], keyWidth: 72),
    ]);
  }
}

class _SiblingEvents extends StatefulWidget {
  final ApiClient api;
  final String? namespace;
  final String? uid;
  final String? kind;
  final String? name;
  final String selfUid;
  const _SiblingEvents({super.key, required this.api, this.namespace, this.uid, this.kind, this.name, required this.selfUid});

  @override
  State<_SiblingEvents> createState() => _SiblingEventsState();
}

class _SiblingEventsState extends State<_SiblingEvents> {
  late Future<List<Json>> _future;

  @override
  void initState() {
    super.initState();
    final f = widget.uid != null
        ? widget.api.events(namespace: widget.namespace, uid: widget.uid)
        : widget.api.events(namespace: widget.namespace, kind: widget.kind, name: widget.name);
    _future = f.then((all) => all.where((e) => dig(e, ['metadata', 'uid']) != widget.selfUid).take(10).toList());
  }

  @override
  Widget build(BuildContext context) => AsyncSection<List<Json>>(future: _future, builder: (context, events) => EventList(events));
}
