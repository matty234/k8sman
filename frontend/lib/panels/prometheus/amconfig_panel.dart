import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/atoms.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'alertmanager_widgets.dart';
import 'selected_by.dart';

/// AlertmanagerConfig: which Alertmanagers pick it up and the alerts it
/// applies to, its route as a tree, receivers by kind of notifier (and the
/// Secrets they read, never values), inhibit rules and time intervals.
class AlertmanagerConfigPanel extends ResourcePanel {
  const AlertmanagerConfigPanel();

  @override
  Set<String> get kinds => {'monitoring.coreos.com/AlertmanagerConfig'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final route = asMap(spec['route']);
    final receivers = asMapList(spec['receivers']);
    final inhibit = asMapList(spec['inhibitRules']);
    final intervals = asMapList(spec['muteTimeIntervals']);
    return [
      CoreSection('applies', DetailSection(
        title: 'Applies to',
        icon: Icons.filter_alt_outlined,
        child: SelectedByView(key: ValueKey('amcfg-sel-${ctx.uid}'), ctx: ctx),
      )),
      CoreSection('route', DetailSection(
        title: 'Route',
        icon: Icons.call_split,
        child: route.isEmpty ? const HintText('No route: the config only defines receivers.') : AMRouteTree(amRouteFromSpec(route), rootLabel: 'top route'),
      )),
      CoreSection('receivers', DetailSection(
        title: 'Receivers',
        icon: Icons.send_outlined,
        trailing: HintText('${receivers.length}'),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          AMReceiverList(amReceiversFromSpec(receivers)),
          for (final r in receivers)
            if (secretRefs(r).isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Wrap(spacing: 6, runSpacing: 2, children: [
                  HintText('${r['name']} reads'),
                  for (final s in secretRefs(r))
                    ResourceLink(ObjectRef(kind: 'Secret', namespace: ctx.namespace, name: s.split('/').first), label: 'Secret $s'),
                ]),
              ),
        ]),
      )),
      if (inhibit.isNotEmpty) CoreSection('inhibit', DetailSection(title: 'Inhibit rules', icon: Icons.block, child: AMInhibitList(amInhibitFromSpec(inhibit)))),
      if (intervals.isNotEmpty)
        CoreSection('time-intervals', DetailSection(title: 'Time intervals', icon: Icons.schedule, child: AMTimeIntervalList(amIntervalsFromSpec(intervals)))),
    ];
  }
}
