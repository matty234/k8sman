import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/detail/detail_sidebar.dart' show EventList;
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
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
      DetailSection(title: 'Event', icon: Icons.notifications_outlined, child: _EventBody(ev, namespace: ns)),
      if (ev.regarding.isNotEmpty)
        DetailSection(
          title: 'Other events for ${ev.regarding['kind'] ?? 'object'}/${ev.regarding['name'] ?? ''}',
          icon: Icons.history,
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

class _EventBody extends StatelessWidget {
  final EventView ev;
  final String? namespace;
  const _EventBody(this.ev, {this.namespace});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final warn = ev.type == 'Warning';
    final c = warn ? severityColor(context, Severity.warn) : theme.colorScheme.outlineVariant;
    ObjectRef ref(Json j) => ObjectRef.fromOwnerRef(j, namespace: namespace);
    final source = [ev.sourceComponent, if (ev.sourceHost != null) 'on ${ev.sourceHost}'].whereType<String>().join(' ');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        StatusBadge(ev.type, severity: warn ? Severity.warn : Severity.ok),
        const SizedBox(width: 8),
        Expanded(
          child: Text(ev.reason.isEmpty ? '(no reason)' : ev.reason,
              overflow: TextOverflow.ellipsis, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
        ),
        if (ev.count > 1)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(8)),
            child: Text('×${ev.count}', style: monoStyle(context, size: 11)),
          ),
      ]),
      const SizedBox(height: 8),
      Container(
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
        decoration: BoxDecoration(
          color: (warn ? c : theme.colorScheme.surfaceContainerHighest).withValues(alpha: warn ? 0.10 : 0.5),
          border: Border(left: BorderSide(color: c, width: 3)),
          borderRadius: BorderRadius.circular(4),
        ),
        child: SelectableText(ev.message.isEmpty ? '(no message)' : ev.message, style: theme.textTheme.bodyMedium),
      ),
      const SizedBox(height: 8),
      KeyValueTable([
        ('Object', ev.regarding.isEmpty ? null : Align(alignment: Alignment.centerLeft, child: ResourceLink(ref(ev.regarding)))),
        ('Field', ev.fieldPath),
        ('Related', ev.related.isEmpty ? null : Align(alignment: Alignment.centerLeft, child: ResourceLink(ref(ev.related)))),
        ('Last seen', parseTime(ev.lastSeen) == null ? null : AgeText(ev.lastSeen, suffix: ' ago', style: theme.textTheme.bodySmall)),
        ('First seen', parseTime(ev.firstSeen) == null ? null : AgeText(ev.firstSeen, suffix: ' ago', style: theme.textTheme.bodySmall)),
        ('Count', ev.count > 1 ? '${ev.count}' : null),
        ('Series',
            ev.series.isEmpty
                ? null
                : Row(children: [
                    Text('${ev.series['count'] ?? '?'} occurrences, last observed ', style: theme.textTheme.bodySmall),
                    AgeText(ev.series['lastObservedTime'], suffix: ' ago'),
                  ])),
        ('Action', ev.action),
        ('Source', source.isEmpty ? null : source),
        ('Reporter', ev.reportingController),
        ('Instance', ev.reportingInstance),
      ], keyWidth: 90),
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
