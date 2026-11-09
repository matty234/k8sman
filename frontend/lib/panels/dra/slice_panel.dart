import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'dra_common.dart';
import '../../ui/widgets/atoms.dart';

/// ResourceSlice: a driver's devices in one pool, on one node or several.
class ResourceSlicePanel extends ResourcePanel {
  const ResourceSlicePanel();

  @override
  Set<String> get kinds => {'$draGroup/ResourceSlice'};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final spec = ctx.spec;
    final pool = asMap(spec['pool']);
    final node = spec['nodeName'] as String?;
    final devices = asMapList(spec['devices']);
    final selector = asMap(spec['nodeSelector']);
    return [
      DetailSection(
        title: 'Slice',
        icon: Icons.developer_board,
        child: KeyValueTable([
          ('Node', node == null ? null : ResourceLink(draNodeRef(node), label: node)),
          ('Scope', node != null ? null : (spec['allNodes'] == true ? 'all nodes' : (selector.isNotEmpty ? 'nodes matching a selector' : (spec['perDeviceNodeSelection'] == true ? 'per device' : null)))),
          ('Node selector', selector.isEmpty ? null : MonoText(_selectorText(selector), size: 11)),
          ('Driver', MonoText('${spec['driver'] ?? ''}', size: 11)),
          ('Pool', MonoText('${pool['name'] ?? ''}', size: 11)),
          ('Generation', pool['generation'] == null ? null : '${pool['generation']}'),
          ('Slices in pool', pool['resourceSliceCount'] == null ? null : '${pool['resourceSliceCount']}'),
        ], keyWidth: 110),
      ),
      DetailSection(
        title: 'Devices',
        icon: Icons.memory,
        trailing: HintText('${devices.length}'),
        child: devices.isEmpty
            ? const HintText('No devices')
            : Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (final d in devices) _Device(d)]),
      ),
    ];
  }
}

String _selectorText(Json s) => [
      for (final t in asMapList(s['nodeSelectorTerms']))
        [
          for (final e in [...asMapList(t['matchFields']), ...asMapList(t['matchExpressions'])])
            '${e['key']} ${e['operator']}${(e['values'] as List?)?.isNotEmpty == true ? ' (${(e['values'] as List).join(', ')})' : ''}',
        ].join(' and '),
    ].join('\nor ');

/// One device: its name, then attributes and capacity as chips, taints in amber.
class _Device extends StatelessWidget {
  final Json device;
  const _Device(this.device);

  @override
  Widget build(BuildContext context) {
    // v1beta1 nests everything under `basic`.
    final d = device['basic'] is Map ? asMap(device['basic']) : device;
    final attrs = asMap(d['attributes']);
    final capacity = asMap(d['capacity']);
    final taints = asMapList(d['taints']);
    final keys = attrs.keys.toList()..sort();
    final caps = capacity.keys.toList()..sort();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        InlineWrap([
          MonoText('${device['name'] ?? ''}', size: 11.5),
          for (final t in taints)
            Chipish(text: '${t['key']}${t['value'] != null && '${t['value']}'.isNotEmpty ? '=${t['value']}' : ''}:${t['effect']}', color: Colors.orange),
        ]),
        if (keys.isNotEmpty || caps.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Wrap(spacing: 4, runSpacing: 4, children: [
              for (final k in keys) Chipish(text: '${_short(k)}=${attributeText(attrs[k])}', copyValue: '$k=${attributeText(attrs[k])}'),
              for (final k in caps)
                Chipish(text: '${_short(k)}: ${dig<dynamic>(capacity[k], ['value']) ?? capacity[k]}', color: Theme.of(context).colorScheme.primary),
            ]),
          ),
      ]),
    );
  }

  /// Drops a domain prefix that is the driver's own (`gpu.example.com/model`
  /// reads as `model`); the full name stays in the tooltip-less copy value.
  static String _short(String k) => k.contains('/') ? k.substring(k.lastIndexOf('/') + 1) : k;
}
