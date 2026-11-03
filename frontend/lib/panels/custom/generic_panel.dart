import 'package:flutter/material.dart';

import '../../actions/actions.dart';
import '../../api/models.dart';
import '../../ui/widgets/common.dart';
import '../../util/k8s.dart';
import '../panel.dart';
import 'crd_schema.dart';
import 'health.dart';
import 'humanize.dart';
import 'refs.dart';
import 'smart_view.dart';

const _sectionIcons = <String, IconData>{
  'data': Icons.data_object,
  'binaryData': Icons.data_object,
  'stringData': Icons.data_object,
  'rules': Icons.rule,
  'webhooks': Icons.webhook,
  'subjects': Icons.people_outline,
  'roleRef': Icons.link,
  'parameters': Icons.tune,
};

/// Fallback for custom resources and built-ins without a dedicated panel:
/// health summary, conditions, then schema-aware smart views of spec,
/// status and every other top-level field.
class GenericPanel extends ResourcePanel {
  const GenericPanel();

  @override
  Set<String> get kinds => const {};

  @override
  List<Widget> buildSections(BuildContext context, PanelContext ctx) {
    final obj = ctx.object;
    final refs = RefResolver(app: ctx.app, namespace: ctx.namespace);
    final apiVersion = '${obj['apiVersion'] ?? ''}';
    final version = apiVersion.contains('/') ? apiVersion.split('/').last : (apiVersion.isEmpty ? ctx.type.version : apiVersion);
    final conds = asMapList(ctx.status['conditions']);

    Widget smart(String key, dynamic value) => CrdSchemaScope(
          key: ValueKey('${ctx.uid}/$key'),
          api: ctx.api,
          type: ctx.type,
          version: version,
          builder: (context, schema, versionEntry) => SmartObjectView(
            value,
            refs: refs,
            schema: key.isEmpty ? schema : schemaChild(schema, key),
            path: key,
            trailing: key == 'spec' && canScale(ctx, versionEntry) ? {'replicas': ScaleControl(ctx)} : const {},
          ),
        );

    // Top-level fields other than the standard envelope.
    final scalars = <String, dynamic>{};
    final containers = <String, dynamic>{};
    for (final e in obj.entries) {
      if (const {'apiVersion', 'kind', 'metadata', 'spec', 'status'}.contains(e.key)) continue;
      (e.value is Map || e.value is List ? containers : scalars)[e.key] = e.value;
    }

    final statusRest = {for (final e in ctx.status.entries) if (e.key != 'conditions') e.key: e.value};
    final crdLink = ctx.type.custom
        ? ResourceLink(
            ObjectRef(group: 'apiextensions.k8s.io', kind: 'CustomResourceDefinition', name: '${ctx.type.resource}.${ctx.type.group}'),
            label: 'CRD',
          )
        : null;

    final sections = <Widget>[
      if (HealthSummary.hasContent(obj))
        DetailSection(title: 'Health', icon: Icons.monitor_heart_outlined, trailing: crdLink, child: HealthSummary(obj)),
      if (conds.isNotEmpty) DetailSection(title: 'Conditions', icon: Icons.checklist, child: ConditionsTable(conds)),
      if (ctx.spec.isNotEmpty || obj['spec'] is Map)
        DetailSection(
          title: 'Spec',
          icon: Icons.tune,
          trailing: HealthSummary.hasContent(obj) ? null : crdLink,
          child: smart('spec', ctx.spec),
        ),
      if (scalars.isNotEmpty) DetailSection(title: 'Properties', icon: Icons.list_alt, child: smart('', scalars)),
      for (final e in containers.entries)
        DetailSection(
          title: humanize(e.key),
          icon: _sectionIcons[e.key] ?? Icons.data_object,
          trailing: _count(context, e.value),
          child: smart(e.key, e.value),
        ),
      if (statusRest.isNotEmpty)
        DetailSection(title: 'Status', icon: Icons.insights_outlined, child: smart('status', statusRest)),
    ];
    if (sections.isEmpty) {
      sections.add(const DetailSection(
        title: 'Details',
        icon: Icons.info_outline,
        child: InlineMessage('This object has no spec, status or data beyond its metadata.'),
      ));
    }
    return sections;
  }

  /// A CR is scalable here when it has `spec.replicas`, its CRD version
  /// declares a scale subresource, and the app isn't read-only.
  static bool canScale(PanelContext ctx, Json? versionEntry) =>
      !ctx.app.readOnly && ctx.type.custom && ctx.spec['replicas'] is num && dig(versionEntry, ['subresources', 'scale']) is Map;

  static Widget? _count(BuildContext context, dynamic v) {
    final n = v is List ? v.length : (v is Map ? v.length : null);
    if (n == null) return null;
    return Text('$n', style: Theme.of(context).textTheme.labelSmall?.copyWith(color: Theme.of(context).hintColor));
  }
}
