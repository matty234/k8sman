/// Shared pieces of the Dynamic Resource Allocation panels (resource.k8s.io):
/// version-tolerant readers (v1 and v1beta1/v1beta2 differ in where a
/// request keeps its fields) and the request list used by claims and
/// templates.
library;

import 'package:flutter/material.dart';

import '../../api/models.dart';
import '../../ui/theme.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../pod/pod_widgets.dart';

const draGroup = 'resource.k8s.io';

const resourceSliceRef = ResourceRef(group: draGroup, resource: 'resourceslices');

ObjectRef deviceClassRef(String name) => ObjectRef(group: draGroup, kind: 'DeviceClass', name: name);
ObjectRef resourceClaimRef(String name, String? ns) => ObjectRef(group: draGroup, kind: 'ResourceClaim', name: name, namespace: ns);
ObjectRef resourceClaimTemplateRef(String name, String? ns) => ObjectRef(group: draGroup, kind: 'ResourceClaimTemplate', name: name, namespace: ns);
ObjectRef draNodeRef(String name) => ObjectRef(kind: 'Node', name: name);

/// One device request of a claim, whichever API version wrote it.
class DraRequest {
  final String name;
  final String? deviceClass;

  /// "ExactCount" (default) or "All".
  final String mode;
  final int count;
  final List<String> selectors;
  final bool adminAccess;
  final int tolerations;

  /// `firstAvailable` sub-requests, in preference order.
  final List<DraRequest> alternatives;
  const DraRequest({
    required this.name,
    this.deviceClass,
    this.mode = 'ExactCount',
    this.count = 1,
    this.selectors = const [],
    this.adminAccess = false,
    this.tolerations = 0,
    this.alternatives = const [],
  });

  /// v1 nests the fields under `exactly`; v1beta1/v1beta2 keep them flat.
  factory DraRequest.fromJson(Json r) {
    final src = r['exactly'] is Map ? asMap(r['exactly']) : r;
    return DraRequest(
      name: '${r['name'] ?? ''}',
      deviceClass: src['deviceClassName'] as String?,
      mode: src['allocationMode'] as String? ?? 'ExactCount',
      count: (src['count'] as num?)?.toInt() ?? 1,
      selectors: celSelectors(src['selectors']),
      adminAccess: src['adminAccess'] == true,
      tolerations: asMapList(src['tolerations']).length,
      alternatives: [for (final a in asMapList(r['firstAvailable'])) DraRequest.fromJson(a)],
    );
  }
}

/// The requests of a claim spec's `devices` (`spec.devices` of a claim,
/// `spec.spec.devices` of a template).
List<DraRequest> draRequests(Json devices) => [for (final r in asMapList(devices['requests'])) DraRequest.fromJson(r)];

/// CEL expressions of a `selectors` list (DeviceClass, request).
List<String> celSelectors(dynamic selectors) => [
      for (final s in asMapList(selectors))
        if (dig<String>(s, ['cel', 'expression']) case final e? when e.isNotEmpty) e,
    ];

/// Nodes a claim's allocation is pinned to, from its node selector.
List<String> allocationNodes(Json allocation) {
  final out = <String>{};
  for (final term in asMapList(dig(allocation, ['nodeSelector', 'nodeSelectorTerms']))) {
    for (final e in [...asMapList(term['matchFields']), ...asMapList(term['matchExpressions'])]) {
      if (e['operator'] == 'In') out.addAll([for (final v in (e['values'] as List? ?? const [])) '$v']);
    }
  }
  return out.toList()..sort();
}

/// A mono block for one CEL expression.
class CelBlock extends StatelessWidget {
  final String expression;
  const CelBlock(this.expression, {super.key});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(color: chipFill(context), borderRadius: BorderRadius.circular(4)),
        child: SelectableText(expression, style: monoStyle(context, size: 11)),
      );
}

/// The requests of a claim or template: name, class (link), count or "all",
/// admin access and CEL selectors.
class DraRequestList extends StatelessWidget {
  final List<DraRequest> requests;
  const DraRequestList(this.requests, {super.key});

  @override
  Widget build(BuildContext context) {
    if (requests.isEmpty) return const Hint('No device requests');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      for (final r in requests)
        Padding(padding: const EdgeInsets.only(bottom: 8), child: _Request(r)),
    ]);
  }
}

class _Request extends StatelessWidget {
  final DraRequest r;
  const _Request(this.r);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      InlineWrap([
        Text(r.name, style: theme.textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w600)),
        if (r.deviceClass != null) ResourceLink(deviceClassRef(r.deviceClass!), label: r.deviceClass),
        if (r.alternatives.isEmpty) Chipish(text: r.mode == 'All' ? 'all matching devices' : '× ${r.count}'),
        if (r.adminAccess) const Chipish(text: 'admin access', color: Colors.orange),
        if (r.tolerations > 0) Hint('${r.tolerations} toleration${r.tolerations == 1 ? '' : 's'}'),
        if (r.alternatives.isNotEmpty) const Hint('first available of:'),
      ]),
      for (final s in r.selectors) Padding(padding: const EdgeInsets.only(top: 3), child: CelBlock(s)),
      if (r.alternatives.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 12, top: 4),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            for (final a in r.alternatives) Padding(padding: const EdgeInsets.only(bottom: 6), child: _Request(a)),
          ]),
        ),
    ]);
  }
}

/// `key=value` text of a device attribute (`{string: x}`, `{int: 3}`, …).
String attributeText(dynamic v) {
  if (v is Map) {
    for (final k in const ['string', 'int', 'bool', 'version']) {
      if (v[k] != null) return '${v[k]}';
    }
  }
  return '$v';
}
