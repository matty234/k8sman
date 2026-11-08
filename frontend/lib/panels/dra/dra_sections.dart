/// DRA sections of core panels: a Pod's resource claims and a Node's
/// devices. Both are empty (and ask for nothing) unless the pod uses claims
/// or the cluster serves resource.k8s.io.
library;

import 'package:flutter/material.dart';

import '../../api/client.dart';
import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import '../pod/pod_widgets.dart';
import 'dra_common.dart';

/// "Resource claims" of a pod: each `spec.resourceClaims` entry with the
/// ResourceClaim behind it and the containers that use it.
Widget draPodSection(PanelContext ctx) {
  final entries = asMapList(ctx.spec['resourceClaims']);
  if (entries.isEmpty) return const SizedBox.shrink();
  final statuses = asMapList(ctx.status['resourceClaimStatuses']);
  final containers = [
    for (final key in const ['initContainers', 'containers', 'ephemeralContainers']) ...asMapList(ctx.spec[key]),
  ];
  return DetailSection(
    title: 'Resource claims',
    icon: Icons.memory,
    trailing: Hint('${entries.length}'),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final e in entries)
        Padding(
          padding: const EdgeInsets.only(bottom: 6),
          child: _PodClaim(
            name: '${e['name']}',
            // Template-generated claims are named in the pod's status.
            claim: statuses.where((s) => s['name'] == e['name']).map((s) => s['resourceClaimName'] as String?).firstOrNull ?? e['resourceClaimName'] as String?,
            template: e['resourceClaimTemplateName'] as String?,
            namespace: ctx.namespace,
            users: [
              for (final c in containers)
                if (asMapList(dig(c, ['resources', 'claims'])).any((u) => u['name'] == e['name'])) '${c['name']}',
            ],
          ),
        ),
    ]),
  );
}

class _PodClaim extends StatelessWidget {
  final String name;
  final String? claim;
  final String? template;
  final String? namespace;
  final List<String> users;
  const _PodClaim({required this.name, this.claim, this.template, this.namespace, required this.users});

  @override
  Widget build(BuildContext context) => KeyValueTable([
        (name, InlineWrap([
          if (claim != null) ResourceLink(resourceClaimRef(claim!, namespace), label: claim) else const Hint('claim not created yet'),
          if (template != null) Hint('from template $template'),
        ])),
        ('  used by', users.isEmpty ? null : InlineWrap([for (final u in users) Chipish(text: u)])),
      ], keyWidth: 110);
}

/// "DRA devices" of a node: its ResourceSlices' devices per driver.
Widget draNodeSection(PanelContext ctx) {
  if (ctx.app.typeFor(draGroup, 'ResourceSlice') == null) return const SizedBox.shrink();
  return _NodeDevices(key: ValueKey('dra-${ctx.uid}'), api: ctx.api, nodeName: ctx.name);
}

class _NodeDevices extends StatefulWidget {
  final ApiClient api;
  final String nodeName;
  const _NodeDevices({super.key, required this.api, required this.nodeName});

  @override
  State<_NodeDevices> createState() => _NodeDevicesState();
}

class _NodeDevicesState extends State<_NodeDevices> {
  late final Future<List<Json>> _future = widget.api.items(resourceSliceRef, fieldSelector: 'spec.nodeName=${widget.nodeName}');

  @override
  Widget build(BuildContext context) => FutureBuilder<List<Json>>(
        future: _future,
        builder: (context, snap) {
          if (snap.hasError || (snap.hasData && snap.data!.isEmpty)) return const SizedBox.shrink();
          if (!snap.hasData) return const SizedBox.shrink();
          final perDriver = <String, int>{};
          for (final s in snap.data!) {
            final d = '${dig(s, ['spec', 'driver'])}';
            perDriver[d] = (perDriver[d] ?? 0) + asMapList(dig(s, ['spec', 'devices'])).length;
          }
          final drivers = perDriver.keys.toList()..sort();
          return DetailSection(
            title: 'DRA devices',
            icon: Icons.memory,
            trailing: Hint('${snap.data!.length} slice${snap.data!.length == 1 ? '' : 's'}'),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              for (final d in drivers)
                Padding(
                  padding: const EdgeInsets.only(bottom: 3),
                  child: InlineWrap([MonoValue(d, size: 11), Hint('${perDriver[d]} device${perDriver[d] == 1 ? '' : 's'}')]),
                ),
              for (final s in snap.data!)
                ResourceLink(ObjectRef(group: draGroup, kind: 'ResourceSlice', name: '${dig(s, ['metadata', 'name'])}'), label: '${dig(s, ['metadata', 'name'])}'),
            ]),
          );
        },
      );
}
